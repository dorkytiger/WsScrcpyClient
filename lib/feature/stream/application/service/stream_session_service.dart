import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';
import 'package:ws_scrcpy_client/core/control/android_key_code.dart';
import 'package:ws_scrcpy_client/core/control/command_control_message.dart';
import 'package:ws_scrcpy_client/core/control/control_message.dart';
import 'package:ws_scrcpy_client/core/control/key_code_control_message.dart';
import 'package:ws_scrcpy_client/core/control/scroll_control_message.dart';
import 'package:ws_scrcpy_client/core/control/touch_control_message.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/stream_initial_info.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';
import 'package:ws_scrcpy_client/core/stream/video_settings.dart';
import 'package:ws_scrcpy_client/core/ws/reconnect_policy.dart';
import 'package:ws_scrcpy_client/feature/stream/data/model/bo/stream_session_snapshot.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/stream_remote_datasource.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/stream_connection_status.dart';

/// 快捷栏可发送的导航/音量按键（旋转屏幕是命令而非按键，走 [StreamSessionService.sendCommand]）。
enum NavigationKey {
  home('主页', AndroidKeyCode.home),
  back('返回', AndroidKeyCode.back),
  recents('最近任务', AndroidKeyCode.appSwitch),
  power('电源', AndroidKeyCode.power),
  volumeUp('音量+', AndroidKeyCode.volumeUp),
  volumeDown('音量-', AndroidKeyCode.volumeDown);

  const NavigationKey(this.description, this.keyCode);

  final String description;
  final int keyCode;
}

/// 投流会话服务：连接（候选地址轮询）→ 解析初始信息头 → 下发视频参数
/// → 统计视频数据 → 断线指数退避重连，并向 UI 暴露只读快照与日志流。
///
/// 输入映射、坐标换算属于 M3；本服务只做"会话生命周期 + 协议收发"。
class StreamSessionService {
  StreamSessionService(
    this._remoteDatasource, {
    this.reconnectPolicy = const ReconnectPolicy(),
    AppLogger? logger,
    Duration? settingsFallbackDelay,
  }) : _logger = logger ?? AppLogger('StreamSessionService'),
       _settingsFallbackDelay =
           settingsFallbackDelay ?? AppDefaults.settingsFallbackDelay;

  /// 连续自动重连的最大次数，超过后进入失败终态，由用户手动重试。
  static const int maxReconnectAttempts = 5;

  /// 每收到多少帧视频数据刷新一次快照（避免每帧都触发 UI 重建）。
  static const int framesPerSnapshot = 15;

  final StreamRemoteDatasource _remoteDatasource;
  final AppLogger _logger;

  /// 等 UI 上报视口尺寸的时长（可注入，测试里传 `Duration.zero`）。
  final Duration _settingsFallbackDelay;

  /// 断线重连退避策略（可注入，便于单元测试）。
  final ReconnectPolicy reconnectPolicy;

  final StreamController<StreamSessionSnapshot> _snapshots =
      StreamController<StreamSessionSnapshot>.broadcast();
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<Uint8List> _videoFrames =
      StreamController<Uint8List>.broadcast();

  // WS 收到视频帧的吞吐（每秒一条日志）。
  //
  // 为什么要在这一层数：它是"服务端到底给没给帧"的唯一直接证据。与
  // NativeVideoDecoder 的"发起/完成"、原生心跳的"收到/已发布/光栅回调"三条线一对照，
  // 就能把"服务端没给帧 / Dart 转发卡住 / 通道卡住 / 解码慢 / 引擎上屏慢"分开
  // （判据见 AGENTS.md §12.8）。
  final Stopwatch _videoThroughputClock = Stopwatch()..start();
  Duration _lastVideoThroughputLogAt = Duration.zero;
  int _videoFramesSeen = 0;
  int _loggedVideoFramesSeen = 0;

  StreamSession? _session;
  StreamSubscription<Object>? _subscription;
  Timer? _reconnectTimer;
  StreamTarget? _target;
  String? _authorization;
  VideoSettings? _videoSettings;
  StreamSessionSnapshot _snapshot = const StreamSessionSnapshot.idle();
  int _attempt = 0;
  int _candidateIndex = 0;
  bool _settingsSentForCurrentConnection = false;
  bool _stopped = true;

  /// 是否在会话建立后自动唤醒被控设备屏幕（**可选功能，默认关**）。
  ///
  /// 注意：曾经以为它是"进去黑屏"的修复，**这是错的**——真实 `bundle.js` 里服务端网页端
  /// 根本不发唤醒键（`WAKEUP` 只命中常量表，没有自动调用点）。黑屏的正解是
  /// "首发视频参数只发一次、且回显服务端值"（见 `_scheduleFirstVideoSettings` 与 AGENTS §12.5）。
  /// 唤醒保留为**可选**：有些设备确实会因为屏幕休眠而不出帧，用户想开就自己开。
  bool _wakeOnConnect = AppDefaults.wakeDeviceOnConnect;

  /// 本次连接是否已经发过唤醒键（每条连接只发一次，避免变成"每帧都发控制消息"）。
  bool _wakeSentForCurrentConnection = false;

  /// UI 上报的最新视口尺寸（设备像素）。**连接前就可能已经有值**，
  /// 首发视频参数会带上它（只发一次，见 [_scheduleFirstVideoSettings]）。
  VideoSize? _reportedViewportBounds;

  /// 等 UI 视口尺寸的兜底定时器；等不到就"不带 bounds"退化发一次（宁可退化也别不发）。
  Timer? _settingsFallbackTimer;

  /// 拿到初始信息头、但还没发首发的那个 display。
  DisplayStreamState? _pendingFirstSettingsDisplay;

  /// 最近一次按窗口下发的编码边界，用于去重。
  (int, int)? _lastViewportBounds;

  /// 会话快照流（UI 订阅它渲染状态）。
  Stream<StreamSessionSnapshot> get snapshots => _snapshots.stream;

  /// 视频帧流：**裸 H.264 Annex-B，一条消息一帧**（实测，见协议记录 §4.4）。
  ///
  /// M2 的解码器订阅它喂帧；不订阅时不会有任何开销（广播流）。
  Stream<Uint8List> get videoFrames => _videoFrames.stream;

  /// 会话日志流（供日志面板展示，排查协议问题）。
  Stream<String> get logs => _logs.stream;

  /// 当前快照。
  StreamSessionSnapshot get snapshot => _snapshot;

  /// 当前连接是否可以发送控制消息。
  bool get canSendControl => _session?.isOpen ?? false;

  /// 启动投流会话；返回首次连接的结果（失败后仍会自动重连）。
  Future<Result<void>> start(
    StreamTarget target, {
    String? authorization,
    VideoSettings? videoSettings,
  }) async {
    await stop();
    _stopped = false;
    _attempt = 0;
    _candidateIndex = 0;
    _target = target;
    _authorization = authorization;
    _videoSettings = videoSettings;
    _lastViewportBounds = null;
    return _connect();
  }

  /// 停止会话（关闭连接、取消定时器）。
  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _settingsFallbackTimer?.cancel();
    _settingsFallbackTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    final session = _session;
    _session = null;
    if (session != null && session.isOpen) {
      await session.close();
    }
    _emit(const StreamSessionSnapshot.idle());
  }

  /// 释放服务（页面销毁时调用）。
  Future<void> dispose() async {
    await stop();
    await _snapshots.close();
    await _logs.close();
    await _videoFrames.close();
  }

  /// 发送任意控制消息（按键/命令）。
  Result<void> sendControlMessage(ControlMessage message) {
    final session = _session;
    if (session == null || !session.isOpen) {
      return Result.failure(const BusinessException(message: '投流未连接，无法发送控制消息'));
    }
    try {
      session.send(message.toBuffer());
      return successVoid();
    } catch (error, stackTrace) {
      _logger.warn('发送控制消息失败', error, stackTrace);
      return Result.failure(
        RemoteException(
          message: '发送控制消息失败：$error',
          exception: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  /// 发送一条无负载命令（展开面板、旋转设备、取剪贴板等）。
  Result<void> sendCommand(CommandType command) =>
      sendControlMessage(CommandControlMessage(command));

  /// 按当前窗口尺寸更新编码边界（横竖屏切换 / 窗口缩放后让画面重新填满）。
  ///
  /// 语义有两段（都很关键，改动前先读 AGENTS §12.5）：
  /// - **首发之前**：只记录尺寸。首发的视频参数会带上它，从而**只发一次**且一次到位
  ///   （服务端网页端就是这么做的）。连发两条（先 `bounds:null` 再实际尺寸）会让服务端
  ///   把编码器重建两次，重建后不会立刻出 IDR → 黑屏，直到画面变化才有帧。
  /// - **首发之后**：尺寸真的变了才补一条（旋转/改变窗口大小），相同尺寸去重。
  Result<void> applyViewportBounds({required int width, required int height}) {
    if (width <= 0 || height <= 0) {
      return successVoid();
    }
    final bounds = VideoSize(width, height);
    _reportedViewportBounds = bounds;

    // 还没发过首发：如果此刻已经拿到 display（初始信息头已到），就用这个尺寸发首发。
    if (!_settingsSentForCurrentConnection) {
      final pending = _pendingFirstSettingsDisplay;
      if (pending != null) {
        return _sendVideoSettings(pending, bounds: bounds);
      }
      return successVoid();
    }

    if (_lastViewportBounds case (final int lastWidth, final int lastHeight)
        when lastWidth == width && lastHeight == height) {
      return successVoid();
    }
    if (_session == null) {
      return failureVoid(const BusinessException(message: '投流未连接，无法更新画面尺寸'));
    }
    final display = _pendingFirstSettingsDisplay ?? _snapshot.display;
    if (display == null) {
      return failureVoid(const BusinessException(message: '还没有显示器信息，无法更新画面尺寸'));
    }
    _log('画面尺寸变化，补发视频参数：${width}x$height');
    return _sendVideoSettings(display, bounds: bounds);
  }

  /// 模拟一次按键（down + up），快捷栏的 Home/Back/Recents/音量都用它。
  Result<void> pressKey(int keyCode) {
    final down = sendControlMessage(
      KeyCodeControlMessage(action: KeyCodeAction.down, keycode: keyCode),
    );
    if (down.isError) {
      return down;
    }
    return sendControlMessage(
      KeyCodeControlMessage(action: KeyCodeAction.up, keycode: keyCode),
    );
  }

  /// 快捷栏动作。
  Result<void> pressNavigationKey(NavigationKey key) => pressKey(key.keyCode);

  /// 发一条触摸事件（M3 输入映射的核心）。
  Result<void> sendTouch({
    required TouchAction action,
    required int pointerId,
    required int x,
    required int y,
    required int screenWidth,
    required int screenHeight,
    double pressure = 1,
    int buttons = 0,
  }) {
    // 抬起时压力必须归 0：设备端据此判定手指离开（网页端也是这么处理的）。
    final effectivePressure = action == TouchAction.up ? 0.0 : pressure;
    return sendControlMessage(
      TouchControlMessage(
        action: action,
        pointerId: pointerId,
        position: TouchPosition(
          x: x,
          y: y,
          screenSize: ScreenSize(width: screenWidth, height: screenHeight),
        ),
        pressure: effectivePressure,
        buttons: buttons,
      ),
    );
  }

  /// 发一条滚轮事件。
  Result<void> sendScroll({
    required int x,
    required int y,
    required int screenWidth,
    required int screenHeight,
    required int hScroll,
    required int vScroll,
  }) {
    return sendControlMessage(
      ScrollControlMessage(
        position: TouchPosition(
          x: x,
          y: y,
          screenSize: ScreenSize(width: screenWidth, height: screenHeight),
        ),
        hScroll: hScroll,
        vScroll: vScroll,
      ),
    );
  }

  Future<Result<void>> _connect() async {
    final target = _target;
    if (target == null) {
      return Result.failure(const BusinessException(message: '投流目标为空'));
    }
    final candidates = target.candidateUris;
    if (candidates.isEmpty) {
      return Result.failure(
        const ValidationException(message: '设备未上报可用网卡地址，无法构造投流地址'),
      );
    }

    _emit(
      _snapshot.copyWith(
        status: _attempt == 0
            ? StreamConnectionStatus.connecting
            : StreamConnectionStatus.reconnecting,
      ),
    );
    _log('开始连接（第 ${_attempt + 1} 次尝试），候选地址 ${candidates.length} 个');

    GlobalException? lastError;
    for (var offset = 0; offset < candidates.length; offset++) {
      if (_stopped) {
        return successVoid();
      }
      final index = (_candidateIndex + offset) % candidates.length;
      final uri = candidates[index];
      final result = await _remoteDatasource.connect(
        uri: uri,
        authorization: _authorization,
      );
      if (result.isError) {
        lastError = result.error;
        _log('候选地址失败：$uri（${result.error!.message}）');
        continue;
      }
      _candidateIndex = index;
      _attach(result.data!);
      return successVoid();
    }

    final error = lastError ?? const RemoteException(message: '所有候选投流地址均连接失败');
    return _handleFailure(error);
  }

  void _attach(StreamSession session) {
    _session = session;
    _settingsSentForCurrentConnection = false;
    // 唤醒键也是"每条连接只发一次"：重连后设备可能又睡了，所以要重新允许发。
    _wakeSentForCurrentConnection = false;
    // 连接是新的：首发要等新的初始信息头；兜底定时器也重新算。
    _pendingFirstSettingsDisplay = null;
    _settingsFallbackTimer?.cancel();
    _settingsFallbackTimer = null;
    _log('已连接：${session.uri}');
    _emit(
      _snapshot.copyWith(
        status: StreamConnectionStatus.connected,
        activeUri: session.uri,
        videoFrameCount: 0,
        videoBytes: 0,
      ),
    );
    _subscription = session.messages.listen(
      _onMessage,
      onError: (Object error, StackTrace stackTrace) {
        _logger.warn('投流连接出错', error, stackTrace);
        unawaited(
          _handleFailure(
            RemoteException(
              message: '投流连接出错：$error',
              exception: error,
              stackTrace: stackTrace,
            ),
          ),
        );
      },
      onDone: () {
        _log('连接已断开');
        unawaited(_handleFailure(const RemoteException(message: '连接已断开')));
      },
      cancelOnError: false,
    );
  }

  void _onMessage(Object raw) {
    final Uint8List bytes;
    if (raw is Uint8List) {
      bytes = raw;
    } else if (raw is String) {
      bytes = Uint8List.fromList(utf8.encode(raw));
    } else if (raw is List<int>) {
      bytes = Uint8List.fromList(raw);
    } else {
      return;
    }

    if (StreamInitialInfo.matches(bytes)) {
      _handleInitialInfo(bytes);
      return;
    }
    _handleVideoFrame(bytes);
  }

  void _handleInitialInfo(Uint8List bytes) {
    try {
      final info = StreamInitialInfo.parse(bytes);
      final display = info.displays.isEmpty ? null : info.displays.first;
      _emit(
        _snapshot.copyWith(
          status: StreamConnectionStatus.connected,
          deviceName: info.deviceName,
          clientId: info.clientId,
          display: display,
          encoders: info.encoders,
        ),
      );
      _log(
        '初始信息头：设备=${info.deviceName} clientId=${info.clientId} '
        'display=${display?.displayInfo.displayId} '
        '分辨率=${display?.displayInfo.size} 连接数=${display?.connectionCount}',
      );
      if (!_settingsSentForCurrentConnection && display != null) {
        _scheduleFirstVideoSettings(display);
      }
    } on ParsingException catch (error, stackTrace) {
      _logger.warn('初始信息头解析失败', error, stackTrace);
      _log('初始信息头解析失败：${error.message}');
    }
  }

  /// 首发视频参数：**只发一次、且带上 UI 的最终视口尺寸**。
  ///
  /// 为什么必须"一次到位"（实测 + 服务端 bundle 证据，见 AGENTS §12.5）：
  /// 服务端网页端是在"布局尺寸已知"之后一次发出去的；而我们以前是
  /// "初始头一到就先发 `bounds:null`，紧接着 UI 布局好又发一条真实尺寸"，
  /// 两条命令会让服务端**重建两次编码器**，重建后不会立刻产出 IDR →
  /// 客户端黑屏，直到画面变化（用户点一下）才有帧。
  ///
  /// 退化路径：UI 还没报尺寸（页面尚未布局）时等一小会儿；超时就用"不带 bounds"发出去
  /// ——宁可退化也不能不发，不发就完全没有画面。
  void _scheduleFirstVideoSettings(DisplayStreamState display) {
    _pendingFirstSettingsDisplay = display;
    final bounds = _reportedViewportBounds;
    if (bounds != null) {
      _sendVideoSettings(display, bounds: bounds);
      return;
    }
    _settingsFallbackTimer?.cancel();
    _settingsFallbackTimer = Timer(_settingsFallbackDelay, () {
      if (_settingsSentForCurrentConnection) {
        return;
      }
      final pending = _pendingFirstSettingsDisplay;
      if (pending == null) {
        return;
      }
      _log(
        '等待 UI 视口尺寸超时（${_settingsFallbackDelay.inMilliseconds}ms），'
        '退化为不带 bounds 首发（UI 报尺寸后会自动补一条）',
      );
      _sendVideoSettings(pending);
    });
  }

  /// 把 UI 视口尺寸收敛成**绝不超过设备原生分辨率**的编码边界（见 AGENTS §12.7）。
  ///
  /// **数据依据（真机实测）**：设备原生 1280x720，而 UI 视口是 1898x853 —— 我们以前
  /// 把这个尺寸原样发给服务端，等于要求**在被控设备上放大 1.77 倍再编码**。
  /// 容器里的软编码器扛不住，实测服务端给帧间隔 53–166ms（≈6–19fps）、抖动、首帧慢；
  /// 而同一设备在网页端流畅。放大是**显示层**的职责（客户端已有 `AspectRatio`/`Texture`
  /// 缩放），不该让被控设备多编像素。
  ///
  /// 规则：`scale = min(1, min(原生宽/视口宽, 原生高/视口高))`，按比例缩到原生范围内；
  /// 视口本来就 ≤ 原生时**保持不动**（也不放大到原生，避免白烧编码）；
  /// 最后**按 16×16 宏块向下对齐**（见 [alignToMacroblock]）。
  static VideoSize clampBoundsToNative({
    required VideoSize viewport,
    required VideoSize native,
  }) {
    if (viewport.width <= 0 || viewport.height <= 0) {
      return alignToMacroblock(native);
    }
    if (native.width <= 0 || native.height <= 0) {
      return alignToMacroblock(viewport);
    }
    final scale = math.min(
      1.0,
      math.min(native.width / viewport.width, native.height / viewport.height),
    );
    if (scale >= 1) {
      return alignToMacroblock(viewport);
    }
    return alignToMacroblock(
      VideoSize(
        (viewport.width * scale).round(),
        (viewport.height * scale).round(),
      ),
    );
  }

  /// 把编码边界向下对齐到 16×16 宏块。
  ///
  /// **为什么必须对齐（真机实测，AGENTS §12.8）**：H.264 的宏块是 16×16，非对齐尺寸要靠
  /// 裁剪/补齐表达，而**容器里的编码器**为此产出的码流 Media Foundation 解不出来——
  /// 日志特征极其明确：`已喂入 12 / 已发布 0`、`ProcessOutput 需更多输入 12`、
  /// `流格式变化 0 次`、`解码器可用输出类型` 只有默认的 1920x1080（说明参数集压根没被解析）。
  /// 同一天同一设备的两次成功会话，下发的是 1280x720 与 992x560（**都是 16 对齐**）；
  /// 失败那次是等比收敛算出来的 **1280x575（奇数、非对齐）**。
  static VideoSize alignToMacroblock(VideoSize size) {
    const int block = 16;
    int align(int value) {
      final int aligned = (value ~/ block) * block;
      return aligned < block ? block : aligned;
    }

    return VideoSize(align(size.width), align(size.height));
  }

  /// 服务端没有给 `VideoSettings` 时的回落值：**与服务端网页端 `VideoSettings` 的
  /// 默认构造逐字段一致**（`bitrate 0 / maxFps 0 / iFrameInterval 0 / bounds null`）。
  ///
  /// bundle 原文：`this.bitrate=0; this.bounds=null; this.maxFps=0; this.iFrameInterval=0;
  /// this.sendFrameMeta=!1; this.lockedVideoOrientation=-1; this.displayId=0`。
  /// 我们以前在这里塞本地默认值（`bitrate 8000000 / iFrameInterval 10`）——**那是我们编的**，
  /// 网页端不会这么发（见 AGENTS §12.7）。
  static VideoSettings fallbackVideoSettings(int displayId) => VideoSettings(
    bitrate: 0,
    maxFps: 0,
    iFrameInterval: 0,
    displayId: displayId,
  );

  /// 发送视频参数（CHANGE_STREAM_PARAMETERS）。
  ///
  /// **回显服务端给的值**：以初始信息头里的 `videoSettings` 为基准逐字段回显，
  /// 只覆盖 `bounds`（我们的视口尺寸，且**收敛到不超过原生分辨率**）与
  /// `sendFrameMeta`（我们解的是裸 Annex-B）。
  /// 以前用本地默认值（bitrate 8000000 / maxFps 0 / iFrameInterval 10）覆盖服务端给的值，
  /// 与服务端网页端的行为不一致——真实服务端给的是例如
  /// `bitrate 7340032 / maxFps 60 / iFrameInterval 10 / bounds 1856x960`。
  Result<void> _sendVideoSettings(
    DisplayStreamState display, {
    VideoSize? bounds,
  }) {
    // 服务端给的那份（逐字段回显的基准）。
    final serverSettings = display.videoSettings;
    final nativeSize = display.displayInfo.size;
    final base =
        serverSettings ??
        _videoSettings ??
        fallbackVideoSettings(display.displayInfo.displayId);
    // 关键：**绝不要求放大**。尺寸无论来自 UI 视口，还是服务端自己给的那份
    // （夹具里服务端给的是 1856x960，同样大于原生 1280x720），都收敛到原生范围内。
    final requestedBounds = bounds ?? base.bounds;
    final effectiveBounds = requestedBounds == null
        ? null
        : clampBoundsToNative(viewport: requestedBounds, native: nativeSize);
    if (effectiveBounds != null && effectiveBounds != requestedBounds) {
      _log(
        '请求的编码边界 ${requestedBounds!.width}x${requestedBounds.height} 收敛/对齐为 '
        '${effectiveBounds.width}x${effectiveBounds.height}'
        '（不放大 + 16 宏块对齐，见 AGENTS §12.7/§12.8）',
      );
    }
    final normalized = base.copyWith(
      displayId: display.displayInfo.displayId,
      // 只在有 UI 视口尺寸时覆盖；没有就沿用服务端给的值（不再写 null）。
      bounds: effectiveBounds,
      // 裸 H.264：每帧前不加 12 字节帧信息，解码侧按 Annex-B 起始码切分。
      sendFrameMeta: false,
    );
    // 把"服务端给的"与"我们回的"都打出来，便于逐字段对照（这次排查就是靠它）。
    _log('服务端初始头给的 VideoSettings：$serverSettings');
    final result = sendControlMessage(
      CommandControlMessage.changeStreamParameters(normalized.toBuffer()),
    );
    if (result.isError) {
      _log('下发视频参数失败：${result.error!.message}');
      return result;
    }
    _settingsSentForCurrentConnection = true;
    _settingsFallbackTimer?.cancel();
    _settingsFallbackTimer = null;
    // 记住已生效的参数：后续按窗口更新边界时以它为基准；
    // 也记住这次用的 bounds（相同尺寸不再补发）。
    _videoSettings = normalized;
    _lastViewportBounds = bounds == null ? null : (bounds.width, bounds.height);
    _log('首发视频参数（回显服务端值 + bounds=${bounds ?? '服务端给的'}）：$normalized');
    if (_wakeOnConnect) {
      // 参数下发成功 = 服务端马上开始编码。唤醒是可选项，默认关（见字段注释）。
      _wakeDeviceOnce();
    }
    return result;
  }

  /// 是否在会话建立后自动唤醒被控设备屏幕。
  ///
  /// 关闭只影响**下一次**连接；打开会立刻补发一次唤醒——用户刚点的开关要马上有反馈，
  /// 不然他会以为"点了没用"。
  bool get wakeOnConnect => _wakeOnConnect;

  set wakeOnConnect(bool value) {
    if (_wakeOnConnect == value) {
      return;
    }
    _wakeOnConnect = value;
    _log(value ? '已开启：连接后自动唤醒被控设备' : '已关闭：连接后不自动唤醒被控设备');
    if (value && canSendControl) {
      _wakeDeviceOnce(force: true);
    }
  }

  /// 主动唤醒被控设备屏幕（`KEYCODE_WAKEUP`，按下 + 抬起）。
  ///
  /// 为什么需要它：scrcpy **只在画面变化时发帧**。设备屏幕休眠/静止时客户端一帧都收不到，
  /// 表现就是"进去黑屏、点一下按钮才有反应"（用户实测）。连上后主动按一次唤醒键，
  /// 屏幕点亮 → 画面开始变化 → 帧才会来。
  Result<void> wakeDevice() => _wakeDeviceOnce(force: true);

  Result<void> _wakeDeviceOnce({bool force = false}) {
    if (!force && _wakeSentForCurrentConnection) {
      return successVoid();
    }
    if (!canSendControl) {
      return failureVoid(const BusinessException(message: '投流未连接，无法唤醒设备'));
    }
    final result = pressKey(AndroidKeyCode.wakeup);
    if (result.isError) {
      _log('唤醒被控设备失败：${result.error!.message}');
      return result;
    }
    _wakeSentForCurrentConnection = true;
    _log('已发送唤醒键（KEYCODE_WAKEUP ${AndroidKeyCode.wakeup}），点亮被控设备屏幕');
    return result;
  }

  void _handleVideoFrame(Uint8List frame) {
    final frames = _snapshot.videoFrameCount + 1;
    final totalBytes = _snapshot.videoBytes + frame.length;
    // 帧本体转发给解码器（M2）；没有订阅者时广播流是零开销的。
    if (!_videoFrames.isClosed) {
      _videoFrames.add(frame);
    }
    _maybeLogVideoThroughput();
    final becameStreaming =
        _snapshot.status != StreamConnectionStatus.streaming;
    if (becameStreaming || frames % framesPerSnapshot == 0) {
      _emit(
        _snapshot.copyWith(
          status: StreamConnectionStatus.streaming,
          videoFrameCount: frames,
          videoBytes: totalBytes,
        ),
      );
    } else {
      // 计数继续累计，只是不每次都通知 UI（30fps 下逐帧刷新会拖慢渲染）。
      _snapshot = _snapshot.copyWith(
        status: StreamConnectionStatus.streaming,
        videoFrameCount: frames,
        videoBytes: totalBytes,
      );
    }
  }

  /// 每秒一条的"WS 收到帧"日志（诊断用；只在有帧流动时写）。
  void _maybeLogVideoThroughput() {
    _videoFramesSeen++;
    final elapsed = _videoThroughputClock.elapsed;
    if (elapsed - _lastVideoThroughputLogAt < const Duration(seconds: 1)) {
      return;
    }
    final delta = _videoFramesSeen - _loggedVideoFramesSeen;
    _lastVideoThroughputLogAt = elapsed;
    _loggedVideoFramesSeen = _videoFramesSeen;
    _logger.info(
      'WS 帧吞吐/s：收到 +$delta（累计 $_videoFramesSeen 帧，'
      '${_snapshot.videoBytes} 字节）',
    );
  }

  Future<Result<void>> _handleFailure(GlobalException error) async {
    await _subscription?.cancel();
    _subscription = null;
    final session = _session;
    _session = null;
    if (session != null && session.isOpen) {
      await session.close();
    }
    if (_stopped) {
      return successVoid();
    }
    if (_attempt >= maxReconnectAttempts) {
      _log('重连次数已达上限（$maxReconnectAttempts 次），停止自动重连');
      _emit(_snapshot.copyWith(status: StreamConnectionStatus.failed));
      return Result.failure(error);
    }
    final delay = reconnectPolicy.delayForAttempt(_attempt);
    _attempt++;
    _log('将在 ${delay.inMilliseconds} ms 后重连（第 $_attempt 次）');
    _emit(_snapshot.copyWith(status: StreamConnectionStatus.reconnecting));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (_stopped) {
        return;
      }
      unawaited(_connect());
    });
    return Result.failure(error);
  }

  void _emit(StreamSessionSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_snapshots.isClosed) {
      _snapshots.add(snapshot);
    }
  }

  void _log(String message) {
    _logger.info(message);
    if (!_logs.isClosed) {
      _logs.add(message);
    }
  }
}
