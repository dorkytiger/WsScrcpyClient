import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ws_scrcpy_client/core/control/command_control_message.dart';
import 'package:ws_scrcpy_client/core/control/key_code_control_message.dart';
import 'package:ws_scrcpy_client/core/control/touch_control_message.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/keyboard_mapping.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/touch_pointer_tracker.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';
import 'package:ws_scrcpy_client/feature/stream/application/service/stream_session_service.dart';
import 'package:ws_scrcpy_client/feature/stream/data/model/bo/stream_session_snapshot.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/native_video_decoder.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/stream_connection_status.dart';

/// 投流页视图模型：会话三态 + 原生解码（M2 路线 A：Android / Windows）。
///
/// 职责边界：会话生命周期与解码器编排在这里触发，具体协议/解码实现都在 service 与
/// [NativeVideoDecoder] 里；这里只维护"给 UI 看的状态"。
class PlayerViewModel extends ChangeNotifier {
  PlayerViewModel(this._sessionService, {NativeVideoDecoder? decoder})
    : _decoder = decoder ?? NativeVideoDecoder();

  /// 日志面板最多保留的条数（避免长时间运行内存增长）。
  static const int maxLogLines = 200;

  /// 输入诊断：同参数事件在这个窗口内再次出现，就当作"疑似重复"报出来。
  ///
  /// 取 30ms：真人不可能在 30ms 内对同一像素点做两次同样的按下/抬起，而程序性重复
  /// （一次点击被处理两遍、cancel 被当成 up 又补一个 up）通常就落在几毫秒内。
  static const int kInputDuplicateWindowMs = 30;

  final StreamSessionService _sessionService;
  final NativeVideoDecoder _decoder;

  /// 输入链路诊断（用户报告的"点一次触发两次 / 总差上一次"靠这几条定性）。
  final AppLogger _inputLogger = AppLogger('Input');

  /// 触摸指针状态机：保证每个 DOWN 都有配对的 UP（黑边上丢掉 UP 会把设备端卡住，
  /// 见 [TouchPointerTracker] 的注释）。
  final TouchPointerTracker _touchTracker = TouchPointerTracker();

  int _inputSequence = 0; // 真正发出的事件序号（用来核对设备收到的顺序）
  int _inputDownCount = 0;
  int _inputMoveCount = 0;
  int _inputUpCount = 0;
  int _inputDuplicateCount = 0;
  int _inputRejectedCount = 0; // 落在黑边上被丢弃的
  DateTime? _inputWindowStart;
  String? _lastInputKey;
  DateTime? _lastInputAt;

  final List<String> _logs = <String>[];
  StreamSubscription<StreamSessionSnapshot>? _snapshotSubscription;
  StreamSubscription<String>? _logSubscription;
  StreamSubscription<Uint8List>? _frameSubscription;
  StreamSubscription<VideoSize>? _videoSizeSubscription;
  AsyncState<StreamSessionSnapshot> _state = const AsyncLoading();
  StreamTarget? _target;
  String? _authorization;
  GlobalException? _lastError;
  GlobalException? _decoderError;
  int? _textureId;
  VideoSize? _videoSize;
  bool _decoderCreating = false;
  bool _decoderUnavailable = false;
  bool _disposed = false;

  /// 会返回给 UI 的三态。
  AsyncState<StreamSessionSnapshot> get state => _state;

  /// 日志（最新的在前）。
  List<String> get logs => List<String>.unmodifiable(_logs.reversed);

  /// 当前快照（未连接时为 idle）。
  StreamSessionSnapshot get snapshot =>
      _state is AsyncSuccess<StreamSessionSnapshot>
      ? (_state as AsyncSuccess<StreamSessionSnapshot>).data
      : const StreamSessionSnapshot.idle();

  /// 原生解码纹理 id；为 null 表示还没就绪（或当前平台不支持）。
  int? get textureId => _textureId;

  /// 解码器回调的真实画面尺寸。
  VideoSize? get videoSize => _videoSize;

  /// 解码器错误（有值时 UI 应显示可读文案 + 重试入口）。
  GlobalException? get decoderError => _decoderError;

  /// 当前平台是否支持原生解码（M2 路线 A）。
  ///
  /// - Android：`MediaCodec` → `SurfaceProducer`；
  /// - Windows：Media Foundation H.264 解码器 MFT；
  /// - iOS / macOS：VideoToolbox（`VTDecompressionSession` → `CVPixelBuffer` → `FlutterTexture`，
  ///   两端共用同一份 `darwin/ScrcpyVideo*.swift`）。
  bool get isNativeDecodingSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// 是否正在等待解码器创建完成。
  bool get isDecoderCreating => _decoderCreating;

  /// 是否在连接建立后自动唤醒被控设备屏幕（默认开，见 `AppDefaults.wakeDeviceOnConnect`）。
  bool get wakeOnConnect => _sessionService.wakeOnConnect;

  /// 切换自动唤醒。打开时会立刻补发一次唤醒键（用户刚点的开关要马上有反馈）。
  void setWakeOnConnect(bool value) {
    _sessionService.wakeOnConnect = value;
    _notify();
  }

  /// 手动唤醒一次被控设备屏幕。
  ///
  /// 用途：投流中途设备又睡了（画面停住），用户可以直接按一下唤醒而不用重连。
  Result<void> wakeDevice() {
    final result = _sessionService.wakeDevice();
    if (result.isError) {
      _logs.add('唤醒设备失败：${result.error!.message}');
      _notify();
    }
    return result;
  }

  /// 建立投流会话。
  Future<void> connect({
    required StreamTarget target,
    String? authorization,
  }) async {
    _target = target;
    _authorization = authorization;
    _lastError = null;
    _decoderError = null;
    _decoderUnavailable = false;
    _state = const AsyncLoading();
    _notify();

    _snapshotSubscription ??= _sessionService.snapshots.listen(_onSnapshot);
    _logSubscription ??= _sessionService.logs.listen(_onLog);

    final result = await _sessionService.start(
      target,
      authorization: authorization,
    );
    if (result.isError) {
      _lastError = result.error;
      if (_sessionService.snapshot.status == StreamConnectionStatus.failed) {
        _state = AsyncFailure<StreamSessionSnapshot>(_lastError!);
        _notify();
      }
    }
  }

  /// 重试（清空自动重连计数后重新连接）。
  Future<void> retry() async {
    final target = _target;
    if (target == null) {
      return;
    }
    await connect(target: target, authorization: _authorization);
  }

  /// 重新创建解码器（解码失败后的重试入口）。
  Future<void> retryDecoder() async {
    await _teardownDecoder();
    _decoderError = null;
    _decoderUnavailable = false;
    _notify();
    final display = snapshot.display;
    if (display != null) {
      await _startDecoder(display.displayInfo.size);
    }
  }

  /// 主动断开。
  Future<void> disconnect() async {
    await _snapshotSubscription?.cancel();
    _snapshotSubscription = null;
    await _logSubscription?.cancel();
    _logSubscription = null;
    await _sessionService.stop();
    _state = const AsyncLoading<StreamSessionSnapshot>();
    _notify();
  }

  /// 快捷栏按键。
  Future<Result<void>> pressNavigationKey(NavigationKey key) async =>
      _sessionService.pressNavigationKey(key);

  /// 视图尺寸变化（横竖屏切换 / 窗口缩放）时把尺寸报给 service。
  ///
  /// 为什么**不**在这里做"已连接"判断：首发视频参数要**一次到位**（带上最终 bounds），
  /// 而这一步往往发生在初始信息头到达之前——必须在连接前就把尺寸记下来，
  /// service 才能"拿到 display 时就带着它发一条"（连发两条会让服务端重建两次编码器 → 黑屏）。
  void applyViewportSize(Size logicalSize, double devicePixelRatio) {
    final result = _sessionService.applyViewportBounds(
      width: (logicalSize.width * devicePixelRatio).round(),
      height: (logicalSize.height * devicePixelRatio).round(),
    );
    if (result.isError) {
      _logs.add('更新画面尺寸失败：${result.error!.message}');
      _notify();
    }
  }

  /// 当前视频画面在控件里的换算关系；没有画面或还没尺寸时返回 null。
  VideoViewport? viewportFor({
    required double viewWidth,
    required double viewHeight,
  }) {
    final size = _videoSize ?? snapshot.display?.displayInfo.size;
    if (size == null || size.width <= 0 || size.height <= 0) {
      return null;
    }
    final viewport = VideoViewport(
      videoWidth: size.width,
      videoHeight: size.height,
      viewWidth: viewWidth,
      viewHeight: viewHeight,
      // 渲染与触摸用同一个模式：改成"铺满"时两边一起变，否则点哪都偏。
      fit: videoFitMode,
    );
    return viewport.isUsable ? viewport : null;
  }

  /// 画面填充方式（默认完整显示）。见 [VideoFitMode]。
  VideoFitMode get videoFitMode => _videoFitMode;
  VideoFitMode _videoFitMode = VideoFitMode.contain;

  /// 切换"完整显示 / 铺满裁切"。
  ///
  /// 只影响**本地渲染与坐标换算**，不改任何编码参数——设备那边该编多少还是多少
  /// （§12.7：绝不向设备要放大）。
  void setVideoFitMode(VideoFitMode mode) {
    if (_videoFitMode == mode) {
      return;
    }
    _videoFitMode = mode;
    _inputLogger.info('画面填充方式切到：${mode.label}（${mode.name}）');
    _notify();
  }

  /// 每秒一条输入统计：把"到底点了多少次、发出多少条、丢了多少、重复了多少"变成数字。
  ///
  /// 为什么需要：用户的现象是"点一下像触发了两次 / 总差上一次"——
  /// 前者会在这里表现为 `疑似重复 > 0`，后者会表现为 `down/up` 数量正常但**坐标对不上**
  /// （所以每条事件都带坐标，且视图层另有一条"控件内坐标 → 视频像素"的日志）。
  void _maybeLogInputStats(DateTime now) {
    final start = _inputWindowStart ??= now;
    final elapsed = now.difference(start);
    if (elapsed.inMilliseconds < 1000) {
      return;
    }
    _inputLogger.info(
      '每秒统计：down $_inputDownCount / move $_inputMoveCount / up $_inputUpCount，'
      '发出 $_inputSequence 条，疑似重复 $_inputDuplicateCount 条，'
      '黑边丢弃 $_inputRejectedCount 条',
    );
    _inputWindowStart = now;
    _inputDownCount = 0;
    _inputMoveCount = 0;
    _inputUpCount = 0;
    _inputDuplicateCount = 0;
    _inputRejectedCount = 0;
  }

  /// 视图层把"落在黑边上、不转发"的事件回报进来（只计数 + 每条都记）。
  void noteInputRejected({
    required TouchAction action,
    required int pointerId,
    required double localX,
    required double localY,
    required String reason,
  }) {
    _inputRejectedCount++;
    // move 会疯狂刷屏：只有 down/up 值得逐条记（黑边上的按下/抬起才是"点了没反应"的原因）。
    if (action == TouchAction.move) {
      return;
    }
    _inputLogger.info(
      '${action.name} id=$pointerId 控件内=(${localX.toStringAsFixed(1)},'
      '${localY.toStringAsFixed(1)}) → 丢弃（$reason）',
    );
  }

  /// 手势 → 触摸消息（M3）。
  ///
  /// 坐标由调用方先用 [viewportFor] 换算成视频像素；落在黑边上时**也要调到这里**
  /// （`point == null`），由 [TouchPointerTracker] 决定是丢弃还是补一条 UP 释放。
  ///
  /// **不要**在视图层对"落在黑边"的事件直接 return —— 那样会把 UP 吃掉，
  /// 设备端会一直认为那根手指按着，之后同一个 pointerId 的点按全失效
  /// （2026-10-02 iOS 实测的"点几下就点不动了"）。
  Result<void>? dispatchTouch({
    required TouchAction action,
    required int pointerId,
    required VideoPoint? point,
    int buttons = 0,
  }) {
    final plan = _touchTracker.handle(
      action: action,
      pointerId: pointerId,
      point: point,
    );
    if (plan.isIgnored) {
      _inputLogger.info(
        '忽略 ${action.name} id=$pointerId：${plan.ignoredReason}',
      );
      return null;
    }
    Result<void>? last;
    for (final step in plan.steps) {
      if (step.action == TouchAction.up && plan.steps.length > 1) {
        // 手指划到黑边上时补的这一条：单独记一条，排查"卡住"时一眼能看到。
        _inputLogger.info('id=$pointerId 划出画面（黑边）→ 补一条 UP 释放，避免设备端手指卡住');
      }
      last = sendTouch(
        action: step.action,
        pointerId: pointerId,
        x: step.point.x,
        y: step.point.y,
        pressure: step.action == TouchAction.up ? 0 : 1,
        // 抬起时按键位归 0（与服务端网页端 `e.buttons` 在 mouseup 时为 0 一致）。
        buttons: step.action == TouchAction.up ? 0 : buttons,
      );
    }
    return last;
  }

  /// 手势 → 触摸消息（M3）的**底层发送**。
  ///
  /// 一般不要直接调它：先过 [dispatchTouch] 的 DOWN/UP 配对状态机。
  Result<void> sendTouch({
    required TouchAction action,
    required int pointerId,
    required int x,
    required int y,
    double pressure = 1,
    int buttons = 0,
  }) {
    final size = _videoSize ?? snapshot.display?.displayInfo.size;
    if (size == null) {
      return failureVoid(const BusinessException(message: '还没有画面尺寸，无法发送触摸'));
    }
    final now = DateTime.now();
    // "点一次触发两次"的签名：同一动作 + 同一指 + **同一坐标**在几十毫秒内又来一次。
    // 只统计 down/up（move 天然会连续重复，判它没有意义）。
    if (action != TouchAction.move) {
      final key = '${action.name}|$pointerId|$x|$y';
      final previousAt = _lastInputAt;
      if (_lastInputKey == key &&
          previousAt != null &&
          now.difference(previousAt).inMilliseconds < kInputDuplicateWindowMs) {
        _inputDuplicateCount++;
        final gap = now.difference(previousAt).inMilliseconds;
        final line =
            '⚠ 疑似重复事件：$key 距上次仅 ${gap}ms（阈值 ${kInputDuplicateWindowMs}ms）'
            '——若设备端"点一次触发两次"，先看这条';
        _inputLogger.warn(line);
        _logs.add(line);
        _notify();
      }
      _lastInputKey = key;
      _lastInputAt = now;
      switch (action) {
        case TouchAction.down:
          _inputDownCount++;
        case TouchAction.up:
          _inputUpCount++;
        case TouchAction.move:
          break;
      }
    } else {
      _inputMoveCount++;
    }
    final sequence = ++_inputSequence;
    final result = _sessionService.sendTouch(
      action: action,
      pointerId: pointerId,
      x: x,
      y: y,
      screenWidth: size.width,
      screenHeight: size.height,
      pressure: pressure,
      buttons: buttons,
    );
    // 每次**真正发出**的事件都留一条（顺序号可用于核对"设备收到的顺序"）：
    // move 太密，只在 verbose 下打，避免把关键行刷掉。
    final line =
        '#$sequence ${action.name} id=$pointerId video=($x,$y) '
        '屏幕=${size.width}x${size.height} 压力=$pressure 按键=$buttons '
        '结果=${result.isSuccess ? '已发' : '失败'}';
    if (action == TouchAction.move) {
      _inputLogger.debug(line);
    } else {
      _inputLogger.info(line);
    }
    _maybeLogInputStats(now);
    if (result.isError) {
      _logs.add('发送触摸失败：${result.error!.message}');
      _notify();
    }
    return result;
  }

  /// 滚轮 → 滚动消息。
  Result<void> sendScroll({
    required int x,
    required int y,
    required int hScroll,
    required int vScroll,
  }) {
    final size = _videoSize ?? snapshot.display?.displayInfo.size;
    if (size == null) {
      return failureVoid(const BusinessException(message: '还没有画面尺寸，无法发送滚动'));
    }
    final result = _sessionService.sendScroll(
      x: x,
      y: y,
      screenWidth: size.width,
      screenHeight: size.height,
      hScroll: hScroll,
      vScroll: vScroll,
    );
    if (result.isError) {
      _logs.add('发送滚动失败：${result.error!.message}');
      _notify();
    }
    return result;
  }

  /// 物理键盘 → 按键消息；不支持的键返回 null（不猜 keycode）。
  Result<void>? handleKeyEvent(KeyEvent event) {
    final keyCode = KeyboardMapping.androidKeyCodeFor(event.logicalKey);
    final action = KeyboardMapping.actionFor(event);
    if (keyCode == null || action == null) {
      return null;
    }
    final result = _sessionService.sendControlMessage(
      KeyCodeControlMessage(
        action: action,
        keycode: keyCode,
        metaState: KeyboardMapping.metaStateFrom(HardwareKeyboard.instance),
      ),
    );
    if (result.isError) {
      _logs.add('发送按键失败：${result.error!.message}');
      _notify();
    }
    return result;
  }

  /// 无载荷命令（旋转屏幕、展开面板等）。
  Future<Result<void>> sendCommand(CommandType command) async =>
      _sessionService.sendCommand(command);

  void _onSnapshot(StreamSessionSnapshot snapshot) {
    if (_disposed) {
      return;
    }
    _state = snapshot.status == StreamConnectionStatus.failed
        ? AsyncFailure<StreamSessionSnapshot>(
            _lastError ?? const RemoteException(message: '投流连接失败，已停止自动重连'),
          )
        : AsyncSuccess<StreamSessionSnapshot>(snapshot);
    _notify();

    // 连接不可用时清空指针状态：设备端要么已经换了会话、要么马上就要重连，
    // 本地留着一堆"还按着"的假状态只会让下一轮点按全被当成重复 DOWN 丢掉。
    // （断线时那根手指的 UP 本来就发不出去，也没必要补。）
    if (!snapshot.status.isUsable && _touchTracker.activePointerCount > 0) {
      _inputLogger.info(
        '连接不可用（${snapshot.status.description}）：清空 '
        '${_touchTracker.activePointerCount} 个未抬起的指针状态',
      );
      _touchTracker.reset();
    }

    // 拿到 displayInfo（含真实分辨率）后就可以起解码器了。
    final display = snapshot.display;
    if (display != null &&
        isNativeDecodingSupported &&
        _textureId == null &&
        !_decoderCreating &&
        !_decoderUnavailable) {
      unawaited(_startDecoder(display.displayInfo.size));
    }
  }

  /// 创建原生解码器并开始接收视频帧。
  Future<void> _startDecoder(VideoSize initialSize) async {
    _decoderCreating = true;
    _notify();
    // 先订阅尺寸变化：创建/喂帧的**回执**里带尺寸，订阅晚一步就会漏掉第一条。
    _videoSizeSubscription ??= _decoder.sizeChanges.listen((VideoSize size) {
      if (_disposed) {
        return;
      }
      _videoSize = size;
      _notify();
    });
    try {
      final result = await _decoder.create();
      if (_disposed) {
        return;
      }
      if (result.isError) {
        _decoderError = result.error;
        _decoderUnavailable = true;
        _logs.add('解码器不可用：${result.error!.message}');
        _notify();
        return;
      }
      _textureId = result.data;
      // 注意顺序：先用解码器已经拿到的尺寸（create 回执通常已经给了占位尺寸），
      // 再退回 displayInfo 里的尺寸；真实尺寸会在后续回执里更新。
      _videoSize = _decoder.lastSize ?? initialSize;
      // 只在这里订阅视频帧：之前的帧由广播流丢弃，避免喂给未就绪的解码器。
      _frameSubscription = _sessionService.videoFrames.listen(_onVideoFrame);
      _logs.add('原生解码器已启动（textureId=$_textureId）');
    } finally {
      _decoderCreating = false;
      _notify();
    }
  }

  void _onVideoFrame(Uint8List frame) {
    if (_disposed) {
      return;
    }
    unawaited(
      _decoder.pushFrame(frame).then((Result<void> result) {
        if (_disposed || result.isSuccess) {
          return;
        }
        // 喂帧失败基本不可恢复（通道异常/解码器已释放）：停掉喂帧并暴露错误。
        _decoderError = result.error;
        _decoderUnavailable = true;
        unawaited(_frameSubscription?.cancel());
        _frameSubscription = null;
        _logs.add('喂帧失败：${result.error?.message}');
        _notify();
      }),
    );
  }

  Future<void> _teardownDecoder() async {
    await _frameSubscription?.cancel();
    _frameSubscription = null;
    await _videoSizeSubscription?.cancel();
    _videoSizeSubscription = null;
    if (_textureId != null) {
      await _decoder.release();
    }
    _textureId = null;
    _videoSize = null;
  }

  void _onLog(String line) {
    if (_disposed) {
      return;
    }
    _logs.add(line);
    if (_logs.length > maxLogLines) {
      _logs.removeRange(0, _logs.length - maxLogLines);
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_snapshotSubscription?.cancel());
    unawaited(_logSubscription?.cancel());
    unawaited(_teardownDecoder());
    unawaited(_decoder.dispose());
    // 只结束本次会话，**不能** dispose 服务：StreamSessionService 是应用级单例，
    // 被多个投流页复用；关掉它的流会让下一次进入投流页收不到任何快照。
    unawaited(_sessionService.stop());
    super.dispose();
  }
}
