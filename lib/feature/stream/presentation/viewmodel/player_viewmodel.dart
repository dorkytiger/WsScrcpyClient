import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ws_scrcpy_client/core/control/command_control_message.dart';
import 'package:ws_scrcpy_client/core/control/key_code_control_message.dart';
import 'package:ws_scrcpy_client/core/control/touch_control_message.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/platform/platform_capabilities.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/keyboard_mapping.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/touch_pointer_tracker.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';
import 'package:ws_scrcpy_client/feature/stream/application/service/stream_session_service.dart';
import 'package:ws_scrcpy_client/feature/stream/data/model/bo/stream_session_snapshot.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/video_decoder_factory.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/stream_connection_status.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/video_bounds_mode.dart';

/// 投流页视图模型：会话三态 + 视频解码编排（原生硬解 / web WebCodecs）。
///
/// 职责边界：会话生命周期与解码器编排在这里触发，具体协议/解码实现都在 service 与
/// [VideoDecoder] 的实现里；这里只维护"给 UI 看的状态"。
class PlayerViewModel extends ChangeNotifier {
  /// [isWeb] 只给测试用（VM 里 `isWebPlatform` 恒为 false，验不了 web 专属分支）。
  PlayerViewModel(this._sessionService, {VideoDecoder? decoder, bool? isWeb})
    : _isWeb = isWeb ?? isWebPlatform {
    // late final + 初始化列表之外赋值：`createVideoDecoder` 需要拿 `_appendLog`（进日志面板），
    // 而初始化列表里不允许碰 this。
    _decoder = decoder ?? createVideoDecoder(onLog: _appendLog);
  }

  /// 日志面板最多保留的条数（避免长时间运行内存增长）。
  static const int maxLogLines = 200;

  /// 输入诊断：同参数事件在这个窗口内再次出现，就当作"疑似重复"报出来。
  ///
  /// 取 30ms：真人不可能在 30ms 内对同一像素点做两次同样的按下/抬起，而程序性重复
  /// （一次点击被处理两遍、cancel 被当成 up 又补一个 up）通常就落在几毫秒内。
  static const int kInputDuplicateWindowMs = 30;

  final StreamSessionService _sessionService;
  late final VideoDecoder _decoder;
  final bool _isWeb;

  /// 输入链路诊断（用户报告的"点一次触发两次 / 总差上一次"靠这几条定性）。
  final AppLogger _inputLogger = AppLogger('Input');

  /// 视口/画面诊断（"拉伸窗口下发过密吗""本地放大了几倍""输入层挂上了吗"）。
  final AppLogger _viewportLogger = AppLogger('Viewport');

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
  StreamSubscription<String>? _decoderErrorSubscription;
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
  bool get isVideoDecodingSupported =>
      isWebPlatform ||
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.macOS));

  /// 是否正在等待解码器创建完成。
  bool get isDecoderCreating => _decoderCreating;

  /// 编码边界策略的默认值：**清晰优先**（桌面与移动一样）。
  ///
  /// 2026-10-07 用户实测（手机横屏）：画面区物理 `2280x1206`，而"省设备算力"把边界封顶在
  /// 设备原生 `1280x720` → 本地放大 **1.68x**（糊）；切到清晰优先后请求 `2144x1200`
  /// （≈ 画面区的物理像素），放大倍率才会回到 ~1.0。
  /// 桌面端同理（"网页端完爆桌面端"就是它按自己的视口尺寸要像素）。
  ///
  /// 风险与退路：AGENTS §12.7 记过"向设备要更多像素 → 帧间隔 53–166ms"，
  /// 所以"更多"面板里保留一键切回 `nativeCap`；日志里的
  /// `帧吞吐/s：收到 +N` 与 `画面诊断…本地放大 x.xx 倍` 就是判据。
  VideoBoundsMode get defaultBoundsMode => VideoBoundsMode.viewport;

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
    // 编码边界策略按平台默认（桌面=清晰优先，移动=省设备算力；见 defaultBoundsMode）。
    // 这时候还没发过首发参数，所以只是记下来，不会额外发消息。
    _sessionService.setBoundsMode(defaultBoundsMode);
    // 新会话：把诊断的"变了才打"缓存清掉，让第一条画面诊断一定打出来。
    _lastRenderDiagnosticsSignature = null;
    _viewportStatsWindowStart = null;
    _viewportLayoutCallsInWindow = 0;
    _viewportSettleTimer?.cancel();
    _viewportSettleTimer = null;
    _pendingViewportSize = null;
    _viewportReportedOnce = false;
    _lastReportedViewportSize = null;
    _viewportSettingsSent = 0;
    _viewportSettingsSentInWindow = 0;
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
  ///
  /// **★ 防抖（2026-10-07 修）**：拖动窗口时 Flutter **每帧**都会调它一次，而每帧尺寸都不同
  /// （实测：0.3 秒的拖动 = 20 个不同尺寸），service 里的"相同尺寸去重"**挡不住**——
  /// 结果是每帧下发一条 `CHANGE_STREAM_PARAMETERS`，服务端每收一条就重建一次编码器；
  /// 重建后不会立刻出 IDR，画面就停住/发黑，用户看到的是"拉伸窗口后没法操控了"
  /// （这个失败模式 AGENTS §6.2 / §12.5 都记过）。
  ///
  /// 规则：
  /// - **本会话第一次**上报立刻生效（首发要带着最终尺寸一次到位，不能等）；
  /// - 之后尺寸变化只在**停稳 [kViewportSettleDelay] 后**合并成一条下发；
  /// - 尺寸没变（纯布局回调）什么都不做，避免拖动结束后还被反复触发。
  void applyViewportSize(Size logicalSize, double devicePixelRatio) {
    _lastViewLogicalSize = logicalSize;
    _lastViewDevicePixelRatio = devicePixelRatio;
    final size = VideoSize(
      (logicalSize.width * devicePixelRatio).round(),
      (logicalSize.height * devicePixelRatio).round(),
    );
    _viewportLayoutCallsInWindow++;

    if (size.width > 0 && size.height > 0) {
      if (!_viewportReportedOnce) {
        _viewportReportedOnce = true;
        _reportViewportSize(size);
      } else if (size != _lastReportedViewportSize &&
          size != _pendingViewportSize) {
        // 尺寸真的在变（多半是在拖窗口）：合并，等停稳再发一条。
        _pendingViewportSize = size;
        _viewportSettleTimer?.cancel();
        _viewportSettleTimer = Timer(kViewportSettleDelay, _flushPendingViewport);
      }
    }
    _maybeLogViewportStats(DateTime.now());
    _maybeLogRenderDiagnostics();
  }

  /// 窗口拖动/旋转的"停稳"宽限期（与网页壳那条约 350ms 的 resize 防抖对齐）。
  static const Duration kViewportSettleDelay = Duration(milliseconds: 350);

  bool _viewportReportedOnce = false;
  VideoSize? _lastReportedViewportSize;
  VideoSize? _pendingViewportSize;
  Timer? _viewportSettleTimer;

  /// 把合并后的尺寸交给 service（真正决定发不发在 service：同尺寸会去重）。
  void _reportViewportSize(VideoSize size) {
    _lastReportedViewportSize = size;
    final result = _sessionService.applyViewportBounds(
      width: size.width,
      height: size.height,
    );
    if (result.isError) {
      _logs.add('更新画面尺寸失败：${result.error!.message}');
      _notify();
    } else if (result.data == true) {
      _viewportSettingsSent++;
    }
  }

  void _flushPendingViewport() {
    _viewportSettleTimer = null;
    final pending = _pendingViewportSize;
    _pendingViewportSize = null;
    if (pending == null || _disposed) {
      return;
    }
    _reportViewportSize(pending);
    _maybeLogRenderDiagnostics();
  }

  /// 最近一次 UI 报上来的画面控件尺寸（逻辑像素）与设备像素比。
  Size? _lastViewLogicalSize;
  double _lastViewDevicePixelRatio = 1;

  /// 诊断计数：真正下发编码参数的次数（累计 / 本窗口），以及本窗口的布局次数。
  int _viewportSettingsSent = 0;
  DateTime? _viewportStatsWindowStart;
  int _viewportLayoutCallsInWindow = 0;
  int _viewportSettingsSentInWindow = 0;

  /// 每秒一条的视口诊断（只在那一秒真的有布局回调时打）。
  ///
  /// 判据：
  /// - `布局 N 次 / 下发 M 条`，N 与 M 都接近每秒帧数 → **窗口拖动风暴**（编码器会被反复重建）；
  /// - `下发 0 条` → 尺寸没变（旋转/缩放结束后的稳定态）；
  /// - 拉伸窗口后画面卡住/点不动时，先看这一秒里 M 是不是几十。
  void _maybeLogViewportStats(DateTime now) {
    _viewportStatsWindowStart ??= now;
    _viewportLayoutCallsInWindow++;
    if (now.difference(_viewportStatsWindowStart!).inMilliseconds < 1000) {
      return;
    }
    final sentInWindow = _viewportSettingsSent - _viewportSettingsSentInWindow;
    final logical = _lastViewLogicalSize;
    final line =
        '视口诊断：本秒控件布局 $_viewportLayoutCallsInWindow 次，'
        '真正下发编码参数 $sentInWindow 条，'
        '控件 ${logical == null ? '未知' : '${logical.width.toStringAsFixed(0)}x'
            '${logical.height.toStringAsFixed(0)} 逻辑'}'
        '@${_lastViewDevicePixelRatio.toStringAsFixed(2)}x，'
        '生效编码边界 ${_boundsText(_sessionService.lastEffectiveBounds)}'
        '${_pendingViewportSize == null ? '' : '，待停稳后下发 '
            '${_pendingViewportSize!.width}x${_pendingViewportSize!.height}'}'
        '${sentInWindow >= 5 ? ' ⚠ 下发过密：服务端每收一条就重建一次编码器' : ''}';
    _appendLog(line);
    _viewportStatsWindowStart = now;
    _viewportLayoutCallsInWindow = 0;
    _viewportSettingsSentInWindow = _viewportSettingsSent;
  }

  static String _boundsText(VideoSize? size) =>
      size == null ? '未知' : '${size.width}x${size.height}';

  /// 画面/输入层的诊断：视频像素、控件物理像素、**本地放大倍率**、坐标换算参数、输入层是否接上。
  ///
  /// 只在"这几个数变了"时打一条，避免刷屏。它同时回答两件事：
  /// - **为什么糊**：`本地放大 x.x 倍` > 1 就说明我们把 1280x720 拉到了更大的物理区域上
  ///   （同一个流，画面区越大越糊），对照 `生效编码边界` 就知道服务端给了多少像素；
  /// - **为什么点不动**：`输入层=断开` 那一行就是"点在画面上不会有任何消息发出去"的直接证据。
  void _maybeLogRenderDiagnostics() {
    final logical = _lastViewLogicalSize;
    final size = _videoSize ?? snapshot.display?.displayInfo.size;
    final viewport = logical == null
        ? null
        : viewportFor(viewWidth: logical.width, viewHeight: logical.height);
    final sizeText = size == null ? '未知' : '${size.width}x${size.height}';
    final fitText = _videoFitMode.name;
    final statusText = snapshot.status.name;
    // 结构签名里**不含控件尺寸**：拖动窗口时控件尺寸每帧都变，含进去会刷屏。
    // 结构（视频尺寸/fit/会话状态/生效边界）一变就立刻打；只有控件尺寸变时按秒限流
    // （每秒一条的"视口诊断"本来就在报尺寸，这里不必重复）。
    final structuralSignature =
        '$sizeText|$fitText|$statusText|'
        '${_sessionService.lastEffectiveBounds}|$_inputLayerAttached';
    final fullSignature =
        '$structuralSignature|${logical?.width}x${logical?.height}|'
        '${_lastViewDevicePixelRatio.toStringAsFixed(2)}';
    final now = DateTime.now();
    final structuralChanged =
        structuralSignature != _lastRenderDiagnosticsStructure;
    if (!structuralChanged &&
        (fullSignature == _lastRenderDiagnosticsSignature ||
            (now.difference(_lastRenderDiagnosticsAt).inMilliseconds < 1000))) {
      return;
    }
    _lastRenderDiagnosticsStructure = structuralSignature;
    _lastRenderDiagnosticsSignature = fullSignature;
    _lastRenderDiagnosticsAt = now;

    final buffer = StringBuffer('画面诊断：视频 $sizeText');
    buffer.write('，fit=$fitText，会话状态=$statusText');
    buffer.write('，生效编码边界 ${_boundsText(_sessionService.lastEffectiveBounds)}');
    if (logical != null && viewport != null) {
      final physicalWidth = logical.width * _lastViewDevicePixelRatio;
      final physicalHeight = logical.height * _lastViewDevicePixelRatio;
      final physicalScale = viewport.scale * _lastViewDevicePixelRatio;
      buffer.write(
        '，控件 ${logical.width.toStringAsFixed(0)}x${logical.height.toStringAsFixed(0)} 逻辑'
        '= ${physicalWidth.toStringAsFixed(0)}x${physicalHeight.toStringAsFixed(0)} 物理',
      );
      buffer.write(
        '，绘制 ${viewport.displayWidth.toStringAsFixed(0)}x'
        '${viewport.displayHeight.toStringAsFixed(0)} 逻辑'
        '（偏移 ${viewport.offsetX.toStringAsFixed(1)},'
        '${viewport.offsetY.toStringAsFixed(1)}）',
      );
      buffer.write(
        '，**本地放大 ${physicalScale.toStringAsFixed(2)}x**'
        '${physicalScale > 1.02 ? '（>1 就是被本地拉大，越大约糊）' : '（≤1 不会被拉糊）'}',
      );
    } else if (logical == null) {
      buffer.write('，控件尺寸尚未上报');
    } else {
      buffer.write('，视口不可用（视频尺寸未知）');
    }
    buffer.write(
      '，输入层=${_inputLayerAttached ? '接上' : '断开（点画面不会有任何反应）'}',
    );
    _appendLog(buffer.toString());
  }

  String? _lastRenderDiagnosticsSignature;
  String? _lastRenderDiagnosticsStructure;
  DateTime _lastRenderDiagnosticsAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 画面控件此刻能不能收输入（与 `_VideoStage` 里的判断同构：有视口 + 会话可用）。
  bool get _inputLayerAttached =>
      snapshot.status.isUsable &&
      _lastViewLogicalSize != null &&
      viewportFor(
            viewWidth: _lastViewLogicalSize!.width,
            viewHeight: _lastViewLogicalSize!.height,
          ) !=
          null;

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

  /// 编码边界策略（清晰度取舍；见 [VideoBoundsMode]）。
  VideoBoundsMode get boundsMode => _sessionService.boundsMode;

  /// 切换"省设备算力 / 清晰优先"。
  ///
  /// 与 [setVideoFitMode] 的区别：这个**会真的改设备那边的编码像素数**，
  /// 所以切换后会立刻补发一条 `CHANGE_STREAM_PARAMETERS`（服务端会重建编码器，
  /// 画面可能短暂停顿一下）。为什么要立刻发：用户点了"清晰优先"就要马上看到变化。
  void setBoundsMode(VideoBoundsMode mode) {
    if (_sessionService.boundsMode == mode) {
      return;
    }
    final result = _sessionService.setBoundsMode(mode);
    if (result.isError) {
      _logs.add('切换编码边界策略失败：${result.error!.message}');
    }
    _lastRenderDiagnosticsSignature = null;
    _maybeLogRenderDiagnostics();
    _notify();
  }

  /// web 专用：把画面几何交给解码器（原生是空实现，见 [VideoDecoder.applyDisplayGeometry]）。
  ///
  /// 只有 web 的 canvas 平台视图需要——那边不能靠 `FittedBox` 缩放 DOM 元素，
  /// 所以 contain/cover 得由我们用同一套 [VideoViewport] 数字写进 CSS。
  void applyWebDisplayGeometry(VideoViewport? viewport) =>
      _decoder.applyDisplayGeometry(viewport);

  /// 画面填充方式（默认完整显示）。见 [VideoFitMode]。
  VideoFitMode get videoFitMode => _videoFitMode;
  VideoFitMode _videoFitMode = VideoFitMode.contain;

  /// 横屏时画面是否**铺到灵动岛/刘海下面**。
  ///
  /// 默认 `false` = 避让：iOS 横屏会把刘海那一侧的安全区**左右都报成 ~59 点**
  /// （因为系统不告诉你缺口在哪一侧），所以画面左右各让一条，缺口永远压不到内容上。
  /// 打开 = 画面铺满整块屏幕，缺口可能遮住画面一角（换来左右多 ~118 点宽度，
  /// 只有"画面宽度受限"的设备上才真的变大——多数手机横屏是高度受限）。
  ///
  /// 用户 2026-10-07 反馈"灵动岛挡住了"，就是缺了这条避让。
  bool get fillCutout => _fillCutout;
  bool _fillCutout = false;

  /// 切换"画面是否填满到灵动岛/刘海"（只影响横屏；竖屏顶栏本来就避开了）。
  void setFillCutout(bool value) {
    if (_fillCutout == value) {
      return;
    }
    _fillCutout = value;
    _inputLogger.info('画面${value ? '填满到灵动岛（可能被遮一角）' : '避让灵动岛/刘海'}');
    // 几何变了 → 输入换算与视口上报都要重算（画面区尺寸会变）。
    _lastRenderDiagnosticsSignature = null;
    _maybeLogRenderDiagnostics();
    _notify();
  }

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
    // 切换后把新的换算数字打出来：铺满模式下"点哪都偏/点不动"要能对着这几个数看。
    _lastRenderDiagnosticsSignature = null;
    _maybeLogRenderDiagnostics();
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
    _maybeLogRenderDiagnostics();
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
        isVideoDecodingSupported &&
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
    // 异步错误（web 的 WebCodecs 是回调式）：一发生就报出来，别等下一帧
    // ——服务端只在画面变化时发帧，等不到下一帧就是一块无解释的黑屏。
    _decoderErrorSubscription ??= _decoder.asyncErrors.listen((
      String message,
    ) {
      if (_disposed || _decoderUnavailable) {
        return;
      }
      _decoderUnavailable = true;
      _decoderError = RemoteException(message: message);
      _logs.add('解码器不可用：$message');
      unawaited(_frameSubscription?.cancel());
      _frameSubscription = null;
      _notify();
    });
    _videoSizeSubscription ??= _decoder.sizeChanges.listen((VideoSize size) {
      if (_disposed) {
        return;
      }
      _videoSize = size;
      _maybeLogRenderDiagnostics();
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
      _maybeLogRenderDiagnostics();
      // 只在这里订阅视频帧：之前的帧由广播流丢弃，避免喂给未就绪的解码器。
      _frameSubscription = _sessionService.videoFrames.listen(_onVideoFrame);
      // ★ web 例外：那边解码器是"后建"的（要先有 DOM 平台视图），而服务端可能在我们订阅
      // 之前就把「参数集 + 首个 IDR」推完并丢掉了（broadcast 流没有监听者）——设备画面静止时
      // 又不会再发帧，于是永远 configure 不了 = 全黑无解释（2026-10-07 实测）。
      // 所以补喂最近一段"从 IDR 开始"的序列（原生三端不依赖这个，保持原行为不动）。
      if (_isWeb) {
        for (final Uint8List frame in _sessionService.replayFramesForNewDecoder()) {
          unawaited(_decoder.pushFrame(frame));
        }
      }
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
    await _decoderErrorSubscription?.cancel();
    _decoderErrorSubscription = null;
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

  /// 往 UI 日志面板里追加一条并打印（视口/画面诊断用；业务日志走 `_onLog`）。
  void _appendLog(String line) {
    if (_disposed) {
      return;
    }
    _logs.add(line);
    if (_logs.length > maxLogLines) {
      _logs.removeRange(0, _logs.length - maxLogLines);
    }
    _viewportLogger.info(line);
    _notify();
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
    _viewportSettleTimer?.cancel();
    _viewportSettleTimer = null;
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
