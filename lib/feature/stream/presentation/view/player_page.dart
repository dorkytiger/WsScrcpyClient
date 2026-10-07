import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';
import 'package:ws_scrcpy_client/common/widget/async_state_view.dart';
import 'package:ws_scrcpy_client/core/control/command_control_message.dart';
import 'package:ws_scrcpy_client/core/control/touch_control_message.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';
import 'package:ws_scrcpy_client/core/platform/platform_capabilities.dart';
import 'package:ws_scrcpy_client/core/util/message_of.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';
import 'package:ws_scrcpy_client/feature/stream/application/service/stream_session_service.dart';
import 'package:ws_scrcpy_client/feature/stream/data/model/bo/stream_session_snapshot.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/stream_connection_status.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/video_bounds_mode.dart';
import 'package:ws_scrcpy_client/feature/stream/presentation/view/web_video_surface.dart';
import 'package:ws_scrcpy_client/feature/stream/presentation/viewmodel/player_viewmodel.dart';

/// 投流页。
///
/// 当前里程碑（M1 + 协议层）已完成：连接、初始信息头解析、视频参数下发、
/// 断线重连、快捷栏按键；**画面解码**在 M2 接入（见 `FLUTTER_AGENT.md` §5），
/// 因此这里先渲染会话状态与视频数据统计，并保留日志面板用于排查协议问题。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.viewModel,
    required this.target,
    required this.title,
    this.authorization,
    this.keepScreenOn = true,
  });

  final PlayerViewModel viewModel;
  final StreamTarget target;
  final String title;
  final String? authorization;
  final bool keepScreenOn;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final AppLogger _logger = AppLogger('PlayerPage');

  /// 物理键盘要有人拿着焦点才会往这里送事件；点画面时抢一次焦点。
  final FocusNode _keyboardFocusNode = FocusNode(debugLabel: 'ws-scrcpy-input');
  bool _showLogs = false;

  /// 横屏时顶栏默认收起，把高度让给画面（横屏总共才 400 出头，顶栏就占 56）。
  ///
  /// **不做成"点画面唤出"**：画面上的点击是要发给被控设备的，
  /// 不能同时又拿来开关自己的 UI —— 所以用一个常驻的半透明小按钮唤出。
  bool _chromeVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.viewModel.connect(
        target: widget.target,
        authorization: widget.authorization,
      );
      _keyboardFocusNode.requestFocus();
      // 新会话的第一条"输入层"日志必须是完整的（见 _VideoStage._lastInteractiveLogged）。
      _VideoStage._lastInteractiveLogged = null;
    });
    _setWakelock(widget.keepScreenOn);
  }

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    _setWakelock(false);
    super.dispose();
  }

  /// 屏幕常亮是平台副作用，放在 view 层；失败只记日志，不打断投流。
  void _setWakelock(bool enable) {
    final future = enable ? WakelockPlus.enable() : WakelockPlus.disable();
    future.catchError((Object error, StackTrace stackTrace) {
      _logger.warn('设置屏幕常亮失败', error, stackTrace);
    });
  }

  Future<void> _send(Future<Result<void>> Function() action) async {
    final result = await action();
    if (result.isError && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(messageOf(result.error))));
    }
  }

  /// 打开"更多"面板并派发选中的动作。
  ///
  /// 先关面板再发命令：避免命令失败时 SnackBar 被面板盖住看不见。
  Future<void> _openMoreActions() async {
    final action = await showModalBottomSheet<_MoreAction>(
      context: context,
      showDragHandle: true,
      // 横屏时可用高度只有 400 上下，默认的 9/16 上限会把内容挤到溢出
      // （真机截图里那条 `BOTTOM OVERFLOWED BY 3.9 PIXELS`）。
      // 打开 isScrollControlled 让面板按内容取高，配合面板内部的整体滚动，
      // 内容再高也只是滚，不会再溢出。
      isScrollControlled: true,
      builder: (BuildContext context) =>
          _MoreActionsSheet(viewModel: widget.viewModel),
    );
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case _MoreAction.wakeDevice:
        await _send(
          () => Future<Result<void>>.value(widget.viewModel.wakeDevice()),
        );
      case _MoreAction.volumeUp:
        await _send(
          () => widget.viewModel.pressNavigationKey(NavigationKey.volumeUp),
        );
      case _MoreAction.volumeDown:
        await _send(
          () => widget.viewModel.pressNavigationKey(NavigationKey.volumeDown),
        );
      case _MoreAction.power:
        await _send(
          () => widget.viewModel.pressNavigationKey(NavigationKey.power),
        );
      case _MoreAction.rotateDevice:
        await _send(
          () => widget.viewModel.sendCommand(CommandType.rotateDevice),
        );
      case _MoreAction.expandNotifications:
        await _send(
          () =>
              widget.viewModel.sendCommand(CommandType.expandNotificationPanel),
        );
      case _MoreAction.expandSettings:
        await _send(
          () => widget.viewModel.sendCommand(CommandType.expandSettingsPanel),
        );
      case _MoreAction.collapsePanels:
        await _send(
          () => widget.viewModel.sendCommand(CommandType.collapsePanels),
        );
      case _MoreAction.disconnect:
        await widget.viewModel.disconnect();
        if (mounted) {
          Navigator.of(context).maybePop();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (BuildContext context, _) {
        // 横屏：顶栏收起、快捷栏挪到右侧 —— 把 402 点里被 UI 吃掉的 120 点还给画面。
        // 竖屏：维持原样（顶栏 + 底部快捷栏），拇指够得着、也更符合习惯。
        final media = MediaQuery.sizeOf(context);
        final isLandscape = media.width > media.height;
        return Scaffold(
          appBar: isLandscape
              ? null
              : AppBar(
                  title: Text(widget.title),
                  actions: <Widget>[_logButton()],
                ),
          body: AsyncStateView<StreamSessionSnapshot>(
            state: widget.viewModel.state,
            onRetry: widget.viewModel.retry,
            errorHint: widget.target.candidateUris.isEmpty
                ? '设备未上报网卡地址'
                : '已尝试 ${widget.target.candidateUris.length} 个地址（代理优先）',
            loadingBuilder: (BuildContext context) => const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircularProgressIndicator(),
                  SizedBox(height: AppSpacing.md),
                  Text('正在建立投流连接…'),
                ],
              ),
            ),
            dataBuilder: (BuildContext context, StreamSessionSnapshot data) =>
                isLandscape ? _landscapeBody(data) : _portraitBody(data),
          ),
        );
      },
    );
  }

  Widget _logButton() => IconButton(
    tooltip: _showLogs ? '隐藏日志' : '显示日志',
    onPressed: () => setState(() => _showLogs = !_showLogs),
    icon: Icon(_showLogs ? Icons.article : Icons.article_outlined),
  );

  /// 只在快捷栏里放"返回/主页/最近/更多"四个高频入口，其余动作收进"更多"面板。
  Widget _quickBar(
    StreamSessionSnapshot data, {
    Axis axis = Axis.horizontal,
  }) => _QuickBar(
    axis: axis,
    enabled: data.status.isUsable,
    onBack: () =>
        _send(() => widget.viewModel.pressNavigationKey(NavigationKey.back)),
    onHome: () =>
        _send(() => widget.viewModel.pressNavigationKey(NavigationKey.home)),
    onRecents: () =>
        _send(() => widget.viewModel.pressNavigationKey(NavigationKey.recents)),
    onMore: _openMoreActions,
  );

  Widget _portraitBody(StreamSessionSnapshot data) => Column(
    children: <Widget>[
      Expanded(
        child: _VideoStage(
          snapshot: data,
          viewModel: widget.viewModel,
          focusNode: _keyboardFocusNode,
        ),
      ),
      _quickBar(data),
      if (_showLogs) _LogPanel(logs: widget.viewModel.logs),
    ],
  );

  /// 横屏布局：**快捷栏竖着贴右边**，顶栏收起。
  ///
  /// 横屏下横向空间富余（874 宽里画面只用 ~500）、纵向极缺（402 点里
  /// 顶栏 56 + 快捷栏 64 就吃掉 30%）。把快捷栏竖过来正好把浪费的横向空间
  /// 换成画面的高度：画面从 501x282 变成约 615x346（**像素 +50%**），而且不裁切。
  Widget _landscapeBody(StreamSessionSnapshot data) => Row(
    children: <Widget>[
      Expanded(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: _VideoStage(
                snapshot: data,
                viewModel: widget.viewModel,
                focusNode: _keyboardFocusNode,
              ),
            ),
            if (_showLogs)
              Align(
                alignment: Alignment.bottomCenter,
                child: _LogPanel(logs: widget.viewModel.logs),
              ),
            if (_chromeVisible)
              Align(
                alignment: Alignment.topCenter,
                child: _ChromeBar(
                  title: widget.title,
                  // 横屏没有 AppBar → 也就没有返回箭头（浏览器更没有系统返回键）。
                  // 原生端靠系统返回/手势，web 上必须给一个入口，否则回不到设备列表。
                  onBack: () => Navigator.of(context).maybePop(),
                  fitMode: widget.viewModel.videoFitMode,
                  onToggleFit: () => widget.viewModel.setVideoFitMode(
                    widget.viewModel.videoFitMode.toggled,
                  ),
                  showLogs: _showLogs,
                  onToggleLogs: () => setState(() => _showLogs = !_showLogs),
                  onHide: () => setState(() => _chromeVisible = false),
                ),
              )
            else
              // 常驻的小入口（半透明、只占左上角一点）。
              // 刻意**不做**"点画面唤出"：画面上的点击是要发给被控设备的。
              Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  child: _ChromeHandle(
                    onPressed: () => setState(() => _chromeVisible = true),
                  ),
                ),
              ),
          ],
        ),
      ),
      _quickBar(data, axis: Axis.vertical),
    ],
  );
}

/// 画面区域 + 输入层（M3）。
///
/// Android（M2 路线 A）：原生 MediaCodec 解出来的画面通过 [Texture] 渲染；
/// Windows（M2 路线 A）：Media Foundation MFT 解出 NV12 后转 BGRA 走像素缓冲纹理，
/// 同样通过 [Texture] 渲染；其它平台保留状态占位。
///
/// 输入：手指/鼠标按下拖动 → 触摸消息；滚轮 → 滚动消息；物理键盘 → 按键消息。
/// 坐标统一先经 [VideoViewport] 换算成**视频像素**，落在黑边上的一律忽略。
class _VideoStage extends StatelessWidget {
  const _VideoStage({
    required this.snapshot,
    required this.viewModel,
    required this.focusNode,
  });

  final StreamSessionSnapshot snapshot;
  final PlayerViewModel viewModel;
  final FocusNode focusNode;

  /// 输入诊断日志：把"原始指针事件 → 视频像素坐标"这一段单独打出来。
  ///
  /// 为什么要专门一条：用户报告"点一下像触发两次 / 总差上一次"。要判断是**事件重复**
  /// 还是**坐标换算/时序**问题，必须同时看到"控件内坐标"和"换算后的视频像素"——
  /// 视图层给前者，[PlayerViewModel] 给后者（带发出序号），两边的序号/坐标一对就定位了。
  static final AppLogger _inputLogger = AppLogger('Input');

  /// 诊断用：上一次"输入层接上/未接上"的状态——只用来避免重复刷同一条日志，
  /// 不参与任何渲染或命中判定。每次进投流页在 [PlayerPage.initState] 里清零。
  static bool? _lastInteractiveLogged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 横竖屏切换 / 窗口缩放后按新尺寸重算编码边界，画面才会重新填满。
        final available = Size(constraints.maxWidth, constraints.maxHeight);
        if (available.width > 0 && available.height > 0) {
          final pixelRatio = MediaQuery.devicePixelRatioOf(context);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            viewModel.applyViewportSize(available, pixelRatio);
          });
        }
        return _buildStage(context, constraints);
      },
    );
  }

  Widget _buildStage(BuildContext context, BoxConstraints constraints) {
    final textureId = viewModel.textureId;
    // ★ 解码器出错时**即使旧纹理还在**也要把错误说出来（2026-10-07）。
    // 否则 view 一直渲染那块已经死掉的画面：用户看到的是"没有任何解释的黑屏/卡住的画面"，
    // 连"重试解码"都点不到。web 上最容易撞到——WebCodecs 一失败，服务端又只在画面变化时
    // 发帧，就再也不会自己恢复（用户实测：全黑、无提示）。
    if (textureId == null || viewModel.decoderError != null) {
      return _VideoPlaceholder(
        snapshot: snapshot,
        decoderError: viewModel.decoderError,
        isDecoderCreating: viewModel.isDecoderCreating,
        isVideoDecodingSupported: viewModel.isVideoDecodingSupported,
        onRetryDecoder: viewModel.retryDecoder,
      );
    }

    final size = viewModel.videoSize;
    final fit = viewModel.videoFitMode;
    final viewport = viewModel.viewportFor(
      viewWidth: constraints.maxWidth,
      viewHeight: constraints.maxHeight,
    );
    final interactive = viewport != null && snapshot.status.isUsable;

    // 输入层到底挂没挂上，只在翻转时记一条：用户说"点画面没反应"时，
    // 有这一条就能立刻分清是**事件根本没到 Listener**（这条会说"未接上"）
    // 还是事件到了、被坐标换算/状态机丢掉了（`[Input]` 的逐条日志会说话）。
    if (_lastInteractiveLogged != interactive) {
      _lastInteractiveLogged = interactive;
      _inputLogger.info(
        interactive
            ? '输入层已接上：视频 ${size?.width}x${size?.height}，'
                  '控件 ${constraints.maxWidth.toStringAsFixed(0)}x'
                  '${constraints.maxHeight.toStringAsFixed(0)}，'
                  'fit=${fit.name}，scale=${viewport.scale.toStringAsFixed(3)}'
            : '输入层**未接上**（点画面不会有任何反应）：原因='
                  '${viewport == null ? '视口不可用（视频 ${size?.width}x${size?.height} / '
                        '控件 ${constraints.maxWidth.toStringAsFixed(0)}x'
                        '${constraints.maxHeight.toStringAsFixed(0)}）'
                      : '会话状态=${snapshot.status.description}（${snapshot.status.name}）'}',
      );
    }

    // 渲染与 [VideoViewport] 必须是**同一套变换**（同一个 BoxFit + 居中），
    // 否则改成"铺满"之后点哪都偏 —— 所以这里直接交给 FittedBox，
    // 不再手写 AspectRatio：两边的比例来源都是 videoSize。
    //
    // web 例外：那边画面是 **DOM canvas 平台视图**，不参与 Flutter 绘制，FittedBox
    // 管不到它 —— 改成把 [VideoViewport] 原样交给解码器，由它用**同一套数字**写 CSS
    // （见 `WebCodecsVideoDecoder.applyDisplayGeometry`；两边一旦分家就会"点哪都偏"）。
    final video = isWebPlatform
        ? buildWebVideoSurface(
            viewport: viewport,
            onGeometry: viewModel.applyWebDisplayGeometry,
          )
        : ColoredBox(
            color: Colors.black,
            child: ClipRect(
              child: SizedBox.expand(
                child: FittedBox(
                  fit: fit == VideoFitMode.cover ? BoxFit.cover : BoxFit.contain,
                  child: SizedBox(
                    width: (size?.width ?? 1280).toDouble(),
                    height: (size?.height ?? 720).toDouble(),
                    child: Texture(textureId: textureId),
                  ),
                ),
              ),
            ),
          );
    if (!interactive) {
      return video;
    }

    return Focus(
      focusNode: focusNode,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        final result = viewModel.handleKeyEvent(event);
        return result == null ? KeyEventResult.ignored : KeyEventResult.handled;
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (PointerDownEvent event) {
          focusNode.requestFocus();
          _sendTouch(TouchAction.down, event, viewport);
        },
        onPointerMove: (PointerMoveEvent event) =>
            _sendTouch(TouchAction.move, event, viewport),
        onPointerUp: (PointerUpEvent event) =>
            _sendTouch(TouchAction.up, event, viewport),
        onPointerCancel: (PointerCancelEvent event) =>
            _sendTouch(TouchAction.up, event, viewport),
        onPointerSignal: (PointerSignalEvent event) =>
            _sendScroll(event, viewport),
        child: video,
      ),
    );
  }

  void _sendTouch(
    TouchAction action,
    PointerEvent event,
    VideoViewport viewport,
  ) {
    final point = viewport.toVideoPoint(
      event.localPosition.dx,
      event.localPosition.dy,
    );
    if (point == null && action == TouchAction.down) {
      // 黑边上的**按下**不转发：投过去设备会点到他不想点的地方。
      // 但要记账——"点了没反应"经常就是点在黑边上了（视图层给的是控件内坐标，
      // 视频像素坐标由 ViewModel 统一记录，两边对不上时一眼能看出是换算前的坑）。
      viewModel.noteInputRejected(
        action: action,
        pointerId: event.pointer,
        localX: event.localPosition.dx,
        localY: event.localPosition.dy,
        reason: viewport.isUsable
            ? '黑边（画面 ${viewport.videoWidth}x${viewport.videoHeight} '
                  '绘于 ${viewport.displayWidth.toStringAsFixed(1)}x'
                  '${viewport.displayHeight.toStringAsFixed(1)}，'
                  '偏移 ${viewport.offsetX.toStringAsFixed(1)},'
                  '${viewport.offsetY.toStringAsFixed(1)}）'
            : '视口不可用（$viewport）',
      );
      // **不要在这里 return**：这条按下会被状态机忽略，但 MOVE/UP 必须继续往下走
      // ——见 TouchPointerTracker 的注释：黑边上丢掉 UP 会把设备端的手指永久卡住。
    } else if (point != null && action != TouchAction.move) {
      // 视图层只记"原始事件"（哪种设备、控件内坐标、按下/抬起），与 ViewModel 那条
      // "视频像素坐标 + 序号"拼起来就是完整链路：原始 → 换算 → 发出。
      _inputLogger.info(
        '原始 ${action.name} id=${event.pointer} kind=${event.kind.name} '
        '控件内=(${event.localPosition.dx.toStringAsFixed(1)},'
        '${event.localPosition.dy.toStringAsFixed(1)}) → '
        '视频=(${point.x},${point.y})',
      );
    }
    viewModel.dispatchTouch(
      action: action,
      // Flutter 的 pointer 本身就能当 scrcpy 的 pointerId（只需在连接内唯一），
      // 直接用它就能天然支持多指。
      pointerId: event.pointer,
      point: point,
      // 鼠标要带按键位，否则设备端收不到"按下"的语义；抬起时归 0（与网页端一致）。
      buttons: event.kind == PointerDeviceKind.mouse
          ? AndroidMotionEventButtons.primary
          : 0,
    );
  }

  void _sendScroll(PointerSignalEvent event, VideoViewport viewport) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final point = viewport.toVideoPoint(
      event.localPosition.dx,
      event.localPosition.dy,
    );
    if (point == null) {
      return;
    }
    // 与服务端网页端一致：取方向并**取反**（delta>0 记 -1，delta<0 记 1）。
    viewModel.sendScroll(
      x: point.x,
      y: point.y,
      hScroll: -event.scrollDelta.dx.sign.round(),
      vScroll: -event.scrollDelta.dy.sign.round(),
    );
  }
}

/// 还没有画面时显示状态与排查提示（三态里的"信息态"）。
class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({
    required this.snapshot,
    required this.decoderError,
    required this.isDecoderCreating,
    required this.isVideoDecodingSupported,
    required this.onRetryDecoder,
  });

  final StreamSessionSnapshot snapshot;
  final GlobalException? decoderError;
  final bool isDecoderCreating;
  final bool isVideoDecodingSupported;
  final Future<void> Function() onRetryDecoder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = snapshot.display;
    return Container(
      color: Colors.black,
      width: double.infinity,
      // 横屏手机（402 点高）时，"AppBar + 快捷栏"之后留给画面的只有 280 上下，
      // 这块占位内容装不下会直接报 RenderFlex overflow（真机首帧到达前就能看到）。
      // 用"能放下就居中、放不下就滚"的标准写法，两种尺寸都不会溢出。
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    snapshot.hasVideo
                        ? Icons.smart_display
                        : Icons.hourglass_empty,
                    color: theme.colorScheme.onInverseSurface,
                    size: AppIconSize.xl,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    snapshot.hasVideo ? '已收到视频数据（M2 接入解码后在此渲染）' : '已连接，等待视频数据',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '状态：${snapshot.status.description}'
                    '${display == null ? '' : ' · 分辨率 ${display.displayInfo.size}'}'
                    '${snapshot.deviceName == null ? '' : ' · ${snapshot.deviceName}'}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '视频帧：${snapshot.videoFrameCount} · 已接收：${(snapshot.videoBytes / 1024).toStringAsFixed(0)} KiB'
                    '${snapshot.activeUri == null ? '' : '\n链路：${snapshot.activeUri}'}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                    ),
                  ),
                  if (decoderError != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      '${isWebPlatform ? 'WebCodecs 解码失败' : '原生解码失败'}：'
                      '${decoderError!.message}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    FilledButton.tonalIcon(
                      onPressed: () => onRetryDecoder(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试解码'),
                    ),
                  ] else if (isDecoderCreating) ...<Widget>[
                    const SizedBox(height: AppSpacing.lg),
                    const SizedBox(
                      width: AppIconSize.md,
                      height: AppIconSize.md,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '正在启动${isWebPlatform ? ' WebCodecs' : '原生'}解码器…',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ] else if (snapshot.hasVideo &&
                      isVideoDecodingSupported &&
                      !snapshot.status.isUsable) ...<Widget>[
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      '连接已断开，等待重连后继续解码。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ],
                  if (!snapshot.hasVideo &&
                      snapshot.status == StreamConnectionStatus.connected) ...[
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      '已建立投流会话，但还没收到视频数据。\n'
                      '若持续如此，请检查服务端设备端的 scrcpy-server 是否正常'
                      '（见 FLUTTER_AGENT.md §1），或换一个投流地址重试。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ],
                  if (snapshot.hasVideo &&
                      !isVideoDecodingSupported) ...<Widget>[
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      '收到的是裸 H.264（Annex-B，一条消息一帧）。\n'
                      '解码目前已在 Android / Windows / iOS / macOS（系统硬解）'
                      '与 web（WebCodecs）上实现；其它平台可先用设备卡片上的"网页"入口观看。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "更多"面板里的动作：文案与图标都挂在枚举上，UI 不再散落字符串。
enum _MoreAction {
  wakeDevice('唤醒设备屏幕', Icons.lightbulb_outline),
  volumeUp('音量 +', Icons.volume_up_outlined),
  volumeDown('音量 −', Icons.volume_down_outlined),
  power('电源键', Icons.power_settings_new),
  rotateDevice('旋转设备屏幕', Icons.screen_rotation),
  expandNotifications('下拉通知面板', Icons.notifications_outlined),
  expandSettings('下拉快捷设置', Icons.tune),
  collapsePanels('收起面板', Icons.keyboard_arrow_down),
  disconnect('断开投流', Icons.link_off);

  const _MoreAction(this.label, this.icon);

  final String label;
  final IconData icon;

  /// 是否属于危险/收尾动作（在面板里单独分组）。
  bool get isDestructive => this == _MoreAction.disconnect;
}

/// 常驻快捷栏：只保留最高频的三个导航键 + "更多"。
///
/// 早期版本把音量/电源/旋转/面板都平铺在底部，一排 8 个按钮把画面挤得很小；
/// 现在其余动作都进 [_MoreActionsSheet]。
/// 横屏顶栏：标题 + 画面填充方式 + 日志 + 收起。
///
/// 做成**浮层**而不是 `Scaffold.appBar`：它盖在画面上，收起后一点高度都不占。
/// 高度刻意压到 44（比标准 AppBar 的 56 矮），横屏下每一点高度都是画面。
class _ChromeBar extends StatelessWidget {
  const _ChromeBar({
    required this.title,
    required this.onBack,
    required this.fitMode,
    required this.onToggleFit,
    required this.showLogs,
    required this.onToggleLogs,
    required this.onHide,
  });

  final String title;

  /// 返回设备列表（横屏没有 AppBar，只能自己给一个）。
  final VoidCallback onBack;

  final VideoFitMode fitMode;
  final VoidCallback onToggleFit;
  final bool showLogs;
  final VoidCallback onToggleLogs;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isContain = fitMode == VideoFitMode.contain;
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.92),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: AppSpacing.xxl + AppSpacing.md,
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: '返回设备列表',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: isContain ? '铺满屏幕（会裁掉画面上下边缘）' : '完整显示（保留黑边）',
                onPressed: onToggleFit,
                icon: Icon(isContain ? Icons.fit_screen : Icons.aspect_ratio),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: showLogs ? '隐藏日志' : '显示日志',
                onPressed: onToggleLogs,
                icon: Icon(showLogs ? Icons.article : Icons.article_outlined),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: '收起顶栏（把高度让给画面）',
                onPressed: onHide,
                icon: const Icon(Icons.expand_less),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
          ),
        ),
      ),
    );
  }
}

/// 横屏顶栏收起后的常驻唤出入口（半透明小圆钮，只占左上角一点）。
///
/// **刻意不做"点画面唤出"**：画面上的点击是要发给被控设备的，
/// 同一手势不能既操作远端又开关本地 UI。
class _ChromeHandle extends StatelessWidget {
  const _ChromeHandle({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.7),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: '显示标题栏',
        onPressed: onPressed,
        icon: const Icon(Icons.expand_more),
        iconSize: AppIconSize.md,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(
          minWidth: AppSpacing.xxl + AppSpacing.xs,
          minHeight: AppSpacing.xxl + AppSpacing.xs,
        ),
      ),
    );
  }
}

class _QuickBar extends StatelessWidget {
  const _QuickBar({
    required this.enabled,
    required this.onBack,
    required this.onHome,
    required this.onRecents,
    required this.onMore,
    this.axis = Axis.horizontal,
  });

  final bool enabled;
  final VoidCallback onBack;
  final VoidCallback onHome;
  final VoidCallback onRecents;
  final VoidCallback onMore;

  /// 横屏时用 [Axis.vertical]：竖着贴右边，把横向浪费的空间换成画面的高度。
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buttons = <Widget>[
      _QuickBarButton(
        icon: Icons.arrow_back,
        label: '返回',
        onPressed: enabled ? onBack : null,
        compact: axis == Axis.vertical,
      ),
      _QuickBarButton(
        icon: Icons.home_outlined,
        label: '主页',
        onPressed: enabled ? onHome : null,
        compact: axis == Axis.vertical,
      ),
      _QuickBarButton(
        icon: Icons.apps,
        label: '最近',
        onPressed: enabled ? onRecents : null,
        compact: axis == Axis.vertical,
      ),
      _QuickBarButton(
        icon: Icons.more_horiz,
        label: '更多',
        onPressed: enabled ? onMore : null,
        compact: axis == Axis.vertical,
      ),
    ];
    final isVertical = axis == Axis.vertical;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        // 竖排时右侧要避开 Home Indicator（横屏时它在右边）。
        right: isVertical,
        left: !isVertical,
        top: false,
        bottom: false,
        child: Padding(
          // 竖排时把内边距也收紧：横屏下这一条每一点宽度都是从画面里抠出来的。
          padding: EdgeInsets.symmetric(
            horizontal: isVertical ? AppSpacing.xs : AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          child: isVertical
              // **不要用 spaceEvenly**：横屏时这一列会拿到整屏高度，
              // spaceEvenly 把 4 个按钮摊到 400 多点里，看着"散"、拇指也够不着。
              // 收成居中一小组（间距 AppSpacing.xs），既紧凑又好按。
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    spacing: AppSpacing.xs,
                    children: buttons,
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: buttons,
                ),
        ),
      ),
    );
  }
}

/// 单个快捷栏按钮：图标在上、文案在下，点击区域够大（拇指可及）。
///
/// [compact] 给横屏的**竖排**快捷栏用：内边距与图标都收小（那一列越窄，画面越宽），
/// 但最小可点区域仍然保持 44x44（低于这个值手指按不准，也过不了无障碍规范）。
class _QuickBarButton extends StatelessWidget {
  const _QuickBarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = onPressed == null
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
        : theme.colorScheme.onSurface;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? AppSpacing.xs : AppSpacing.lg,
            vertical: compact ? AppSpacing.xxs : AppSpacing.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                icon,
                size: compact ? AppIconSize.md : AppIconSize.lg,
                color: color,
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "更多"面板：音量 / 电源 / 旋转 / 面板 / 断开。
///
/// 投流页默认横屏、可用高度很小，所以这里用**紧凑按钮墙 + 可滚动**，
/// 而不是一列 ListTile（那会在横屏 / 小高度下竖直溢出——widget 测试抓到过）。
class _MoreActionsSheet extends StatelessWidget {
  const _MoreActionsSheet({required this.viewModel});

  final PlayerViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actions = _MoreAction.values
        .where((_MoreAction action) => !action.isDestructive)
        .toList(growable: false);
    // 整体一把梭地可滚动：投流页默认横屏、可用高度很小，任何"固定高度 + 内部再套一层
    // Flexible 滚动"的写法都会在某个尺寸下算不平（横屏真机上就溢出过 3.9px）。
    // 这里只留**一层**滚动，内容多高都只是滚，永远不溢出。
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                0,
              ),
              child: Row(
                children: <Widget>[
                  Text('更多操作', style: theme.textTheme.titleMedium),
                ],
              ),
            ),
            // 自动唤醒开关：设备屏幕休眠时 scrcpy 一帧都不发（"进去黑屏、点一下才有反应"
            // 就是这个），所以这个开关默认打开，并且放在面板最上面让用户能第一时间找到。
            ListenableBuilder(
              listenable: viewModel,
              builder: (BuildContext context, _) => SwitchListTile(
                value: viewModel.wakeOnConnect,
                onChanged: viewModel.setWakeOnConnect,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                ),
                title: const Text('连接后自动唤醒设备'),
                subtitle: const Text('设备屏幕休眠时不会发画面，连上后自动按一次唤醒键'),
              ),
            ),
            const Divider(height: 1),
            // 画面填充方式：竖屏时这里也是唯一入口（横屏顶栏里另有一个图标按钮）。
            // 只影响本地渲染与坐标换算，不动编码参数（§12.7：绝不向设备要放大）。
            ListenableBuilder(
              listenable: viewModel,
              builder: (BuildContext context, _) => SwitchListTile(
                value: viewModel.videoFitMode == VideoFitMode.cover,
                onChanged: (bool cover) => viewModel.setVideoFitMode(
                  cover ? VideoFitMode.cover : VideoFitMode.contain,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                ),
                title: const Text('铺满屏幕'),
                subtitle: const Text('裁掉画面上下边缘，换掉左右的黑边；不改设备那边的编码'),
              ),
            ),
            const Divider(height: 1),
            // 清晰度：网页端之所以看着更清楚，是因为它把**浏览器视口尺寸**当编码边界发过去，
            // 而我们原来一律封顶到设备原生（§12.7 是为了不许设备多编像素）。
            // 这个开关把选择权还给用户：清晰优先 = 允许设备多编到原生 2 倍像素。
            ListenableBuilder(
              listenable: viewModel,
              builder: (BuildContext context, _) => SwitchListTile(
                value: viewModel.boundsMode == VideoBoundsMode.viewport,
                onChanged: (bool clearFirst) => viewModel.setBoundsMode(
                  clearFirst
                      ? VideoBoundsMode.viewport
                      : VideoBoundsMode.nativeCap,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                ),
                title: const Text('清晰优先（按画面区像素编码）'),
                subtitle: Text(
                  '${VideoBoundsMode.viewport.description}；'
                  '关掉 = ${VideoBoundsMode.nativeCap.description}',
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: <Widget>[
                  for (final action in actions)
                    FilledButton.tonalIcon(
                      onPressed: () => Navigator.of(context).pop(action),
                      icon: Icon(action.icon),
                      label: Text(action.label),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                child: TextButton.icon(
                  onPressed: () =>
                      Navigator.of(context).pop(_MoreAction.disconnect),
                  icon: const Icon(Icons.link_off),
                  label: const Text('断开投流'),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 日志面板：协议异常与重连过程的可观测性入口。
class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: AppSpacing.xxl * 6,
      color: theme.colorScheme.surfaceContainerLow,
      child: logs.isEmpty
          ? const Center(child: Text('暂无日志'))
          : ListView.builder(
              padding: const EdgeInsets.all(AppSpacing.sm),
              itemCount: logs.length,
              itemBuilder: (BuildContext context, int index) =>
                  Text(logs[index], style: theme.textTheme.bodySmall),
            ),
    );
  }
}
