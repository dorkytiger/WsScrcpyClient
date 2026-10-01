import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_all/webview_all.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';
import 'package:ws_scrcpy_client/common/widget/async_state_view.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/feature/shell/presentation/viewmodel/webview_shell_viewmodel.dart';
import 'package:ws_scrcpy_client/feature/shell/presentation/widget/browser_fallback_view.dart';

/// M1：WebView 壳。
///
/// 目标（文档 §5 M1）：把 ws-scrcpy 网页直接装进 App —— 真全屏、屏幕常亮、
/// 带上 Basic Auth 头、Android 返回键映射为网页后退。
///
/// 平台实现走 `webview_all`：Android / iOS / macOS / Windows / Linux 都有对应实现
/// （官方 `webview_flutter` 只覆盖移动端 + macOS，桌面端不够用）；
/// 若某平台的实现初始化失败，退回到 [BrowserFallbackView] 引导用系统浏览器打开。
class WebviewShellPage extends StatefulWidget {
  const WebviewShellPage({
    super.key,
    required this.viewModel,
    required this.initialUri,
    this.basicAuthUsername,
    this.basicAuthPassword,
    this.title,
    this.keepScreenOn = true,
  });

  final WebviewShellViewModel viewModel;

  /// 要加载的服务入口（例如 `https://android.dorkytiger.top/`）。
  final Uri initialUri;

  /// Basic Auth 账号；为空表示服务端未开启鉴权。
  final String? basicAuthUsername;

  /// Basic Auth 密码。
  final String? basicAuthPassword;

  /// 标题栏文案（按设备打开时用设备名）。
  final String? title;

  final bool keepScreenOn;

  @override
  State<WebviewShellPage> createState() => _WebviewShellPageState();
}

class _WebviewShellPageState extends State<WebviewShellPage>
    with WidgetsBindingObserver {
  /// 去掉页面默认边距、禁用长按选中与回弹，让网页更接近全屏 App 的手感。
  static const String _fitViewportScript = '''
    (function () {
      var style = document.createElement('style');
      style.id = '__ws_scrcpy_client_fit__';
      style.textContent = 'html, body { margin: 0; padding: 0; ' +
        'overscroll-behavior: none; -webkit-user-select: none; }';
      if (!document.getElementById(style.id)) {
        document.head.appendChild(style);
      }
    })();
  ''';

  /// 在页面里装一套小工具并立即"适合屏幕"。
  ///
  /// 网页端的投流页默认是 **1:1 显示**（所以手机上会看到一小块画面缩在角落），
  /// 控制面板里那个 `Fit` 才是"缩放到窗口"。这里按按钮文案找元素并点击，
  /// 不依赖服务端给元素起的 id/class（那些会随版本变）。
  static const String _autoFitScript = '''
    (function () {
      if (!window.__wsScrcpyClient) {
        window.__wsScrcpyClient = {
          clickByText: function (text) {
            var nodes = document.querySelectorAll(
              'button, a, input[type="button"], input[type="submit"], span'
            );
            for (var i = 0; i < nodes.length; i++) {
              var value = (nodes[i].textContent || nodes[i].value || '').trim();
              if (value === text) {
                nodes[i].click();
                return true;
              }
            }
            return false;
          },
          fit: function () {
            // 只点 Fit：网页端内部有 equals 去重，参数确实变了才会下发
            // CHANGE_STREAM_PARAMETERS。
            // **不要**顺手点 "Change video settings"：重复下发会把服务端拖进
            // "改参数 → 重发初始头 → 再改参数" 的循环，编码器反复重启就永远没画面
            // （这个坑记在 docs/ws-scrcpy-protocol.md §6.2）。
            return this.clickByText('Fit');
          },
          rotate: function () {
            return this.clickByText('Rotate device');
          },
          watchResize: function () {
            // 横竖屏切换 / 窗口尺寸变化后必须重新 Fit，否则画面还是按旧尺寸摆，
            // 不会重新填满屏幕。防抖 350ms，避免旋转过程中连点。
            if (window.__wsScrcpyClientResizeBound) return;
            window.__wsScrcpyClientResizeBound = true;
            var timer = null;
            var schedule = function () {
              if (timer) clearTimeout(timer);
              timer = setTimeout(function () {
                window.__wsScrcpyClient &&
                  window.__wsScrcpyClient.fit();
              }, 350);
            };
            window.addEventListener('resize', schedule);
            window.addEventListener('orientationchange', schedule);
          }
        };
      }
      window.__wsScrcpyClient.watchResize();
      return window.__wsScrcpyClient.fit();
    })();
  ''';

  /// 只做一次 Fit（尺寸变化后调用）。
  static const String _fitOnceScript =
      'window.__wsScrcpyClient && window.__wsScrcpyClient.fit();';

  final AppLogger _logger = AppLogger('WebviewShellPage');
  WebViewController? _controller;
  String? _initError;

  /// 默认显示标题栏：这个页面是按设备打开的路由，用户需要一眼看到返回入口；
  /// 右上角的按钮可切到真全屏。
  bool _isFullScreen = false;

  /// 是否把本机锁定为横屏。
  ///
  /// 被控设备（这里是一台 1280x720 的安卓）画面是横的，手机竖屏看只能缩成一条，
  /// 所以默认锁横屏；用户可用标题栏按钮切回"跟随系统"。
  bool _lockLandscape = true;

  /// 平台实现不可用（创建失败或加载时抛错，例如缺 WebView2 运行时）——
  /// 此时渲染兜底页，而不是让异常冒到 framework 变成未捕获异常。
  bool _isUnavailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setWakelock(widget.keepScreenOn);
    _createController();
    _enterFullScreen();
    _applyOrientation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setWakelock(false);
    _exitFullScreen();
    // 离开投流页要还原方向，否则整个 App 会一直被锁在横屏。
    SystemChrome.setPreferredOrientations(DeviceOrientation.values)
        .catchError((Object error, StackTrace stackTrace) {
          _logger.warn('还原屏幕方向失败', error, stackTrace);
        });
    super.dispose();
  }

  /// 按当前开关设置本机方向（仅移动端有意义）。
  void _applyOrientation() {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    final orientations = _lockLandscape
        ? const <DeviceOrientation>[
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : DeviceOrientation.values;
    SystemChrome.setPreferredOrientations(orientations)
        .catchError((Object error, StackTrace stackTrace) {
          _logger.warn('设置屏幕方向失败', error, stackTrace);
        });
  }

  void _setWakelock(bool enable) {
    final future = enable ? WakelockPlus.enable() : WakelockPlus.disable();
    future.catchError((Object error, StackTrace stackTrace) {
      _logger.warn('设置屏幕常亮失败', error, stackTrace);
    });
  }

  void _enterFullScreen() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
        .catchError((Object error, StackTrace stackTrace) {
          _logger.warn('进入全屏失败', error, stackTrace);
        });
  }

  void _exitFullScreen() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
        .catchError((Object error, StackTrace stackTrace) {
          _logger.warn('退出全屏失败', error, stackTrace);
        });
  }

  /// 创建并初始化控制器；失败时记录原因，改由兜底页呈现。
  void _createController() {
    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (String url) => widget.viewModel.markLoading(),
            onPageFinished: (String url) async {
              await _controller?.runJavaScript(_fitViewportScript);
              final canGoBack = await _controller?.canGoBack() ?? false;
              widget.viewModel.markLoaded(Uri.parse(url), canGoBack: canGoBack);
              // 控制面板是异步渲染的，这里按重试节奏反复尝试"适合屏幕"。
              unawaited(_applyAutoFit());
            },
            onWebResourceError: (WebResourceError error) {
              widget.viewModel.markResourceError(
                description: error.description,
                isForMainFrame: error.isForMainFrame ?? true,
              );
            },
            // Basic Auth：**必须走 401 质询**。
            //
            // 之前用 loadRequest(headers: Authorization) 预置凭据，页面本身能打开，
            // 但页面里 JS 自己发起的 WebSocket 不会带这个头 → 设备列表一直拉不到，
            // 表现就是"网页壳全黑"。让质询发生并在协议层应答，WebView 才会把凭据
            // 缓存到该 realm，后续（含 WS 握手）才会自动带上。
            onHttpAuthRequest: _onHttpAuthRequest,
            onHttpError: (HttpResponseError error) {
              final status = error.response?.statusCode;
              final uri = error.request?.uri.toString();
              _logger.warn('网页资源 HTTP 错误：status=$status uri=$uri');
              if (status == 401 || status == 403) {
                widget.viewModel.markResourceError(
                  description:
                      '服务端要求鉴权（HTTP $status）：请在"设置"里填写 Basic Auth 账号与密码',
                  isForMainFrame: true,
                );
              }
            },
            onNavigationRequest: (NavigationRequest request) {
              // 服务端页面全量放行；SSO/外链场景另行处理。
              return NavigationDecision.navigate;
            },
          ),
        )
        // JS 控制台日志接到统一 logger：全黑/协议异常时能直接从日志定位。
        ..setOnConsoleMessage((JavaScriptConsoleMessage message) {
          _logger.info('[web] ${message.level.name}: ${message.message}');
        });
      _controller = controller;
      unawaited(_load(controller));
    } catch (error, stackTrace) {
      _logger.error('内嵌浏览器初始化失败', error, stackTrace);
      _initError = '$error';
      _isUnavailable = true;
    }
  }

  /// 应答 HTTP Basic Auth 质询；没有配置凭据时取消（页面会回到未授权状态）。
  void _onHttpAuthRequest(HttpAuthRequest request) {
    final username = widget.basicAuthUsername;
    final password = widget.basicAuthPassword;
    if (username == null || username.isEmpty || password == null) {
      _logger.warn('收到鉴权质询但未配置凭据：host=${request.host} realm=${request.realm}');
      request.onCancel();
      return;
    }
    _logger.info('应答鉴权质询：host=${request.host} realm=${request.realm}');
    request.onProceed(WebViewCredential(user: username, password: password));
  }

  /// 加载入口地址。
  ///
  /// 部分平台（如 Windows 的 WebView2）创建失败是**异步**报出来的，
  /// 必须在这里接住，否则会变成未捕获异常、界面停留在空白页。
  Future<void> _load(WebViewController controller) async {
    try {
      // 刻意不带 Authorization 头：让服务端发 401，交给 _onHttpAuthRequest 应答，
      // WebView 才会记住该 realm 的凭据（页面内的 WebSocket 依赖这一点）。
      await controller.loadRequest(widget.initialUri);
    } catch (error, stackTrace) {
      _logger.error('加载网页壳失败', error, stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _initError = '$error';
        _isUnavailable = true;
      });
      widget.viewModel.markResourceError(
        description: '$error',
        isForMainFrame: true,
      );
    }
  }

  /// 横竖屏切换 / 窗口尺寸变化：页面里虽然挂了 resize 监听，这里再兜一次底。
  ///
  /// 表现问题是"旋转后画面不重新填满屏幕"——网页端只在收到 Fit 时才按新窗口
  /// 重算 bounds 并（在参数真的变化时）下发，所以尺寸一变就要主动点一次。
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    unawaited(_fitOnce());
  }

  Future<void> _fitOnce() async {
    // 等布局稳定下来再点，否则拿到的是旋转过程中的中间尺寸。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) {
      return;
    }
    final controller = _controller;
    if (controller == null) {
      return;
    }
    try {
      await controller.runJavaScript(_fitOnceScript);
    } catch (error, stackTrace) {
      _logger.warn('尺寸变化后重新 Fit 失败', error, stackTrace);
    }
  }

  /// 页面就绪后反复尝试"适合屏幕"。
  ///
  /// 投流页的控制面板是异步渲染的（还要等设备列表/播放器初始化），
  /// 点一次不一定点得到，所以按固定节奏重试几次；脚本本身是幂等的。
  Future<void> _applyAutoFit() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) {
        return;
      }
      final controller = _controller;
      if (controller == null) {
        return;
      }
      try {
        await controller.runJavaScript(_autoFitScript);
      } catch (error, stackTrace) {
        _logger.warn('执行"适合屏幕"脚本失败', error, stackTrace);
        return;
      }
    }
  }

  /// 让被控设备自己转一次屏（点网页端的 `Rotate device`）。
  Future<void> _rotateDevice() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    try {
      await controller.runJavaScript(
        'window.__wsScrcpyClient && window.__wsScrcpyClient.rotate();',
      );
    } catch (error, stackTrace) {
      _logger.warn('旋转设备失败', error, stackTrace);
    }
  }

  /// 切换本机"锁定横屏 / 跟随系统"。
  void _toggleLandscapeLock() {
    setState(() => _lockLandscape = !_lockLandscape);
    _applyOrientation();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_lockLandscape ? '已锁定横屏' : '已跟随系统方向')),
    );
  }

  Future<void> _openInBrowser(BuildContext context, Uri uri) async {
    final opened = await openInSystemBrowser(uri);
    if (opened || !context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('打开系统浏览器失败')));
  }

  Future<void> _reload() async {
    widget.viewModel.markLoading();
    final controller = _controller;
    if (controller == null || _isUnavailable) {
      setState(() {
        _initError = null;
        _isUnavailable = false;
        _createController();
      });
      return;
    }
    await _load(controller);
  }

  Future<bool> _handleBack() async {
    final controller = _controller;
    if (controller == null) {
      return false;
    }
    if (await controller.canGoBack()) {
      await controller.goBack();
      widget.viewModel.updateCanGoBack(await controller.canGoBack());
      return true;
    }
    return false;
  }

  void _toggleFullScreen() {
    setState(() => _isFullScreen = !_isFullScreen);
    if (_isFullScreen) {
      _enterFullScreen();
    } else {
      _exitFullScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || _isUnavailable) {
      return Scaffold(
        appBar: AppBar(title: const Text('网页壳')),
        body: BrowserFallbackView(
          serverUri: widget.initialUri,
          reason: _initError,
          onOpenInBrowser: (Uri uri) => _openInBrowser(context, uri),
        ),
      );
    }

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (BuildContext context, _) {
        final state = widget.viewModel.state;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, Object? result) async {
            if (didPop) {
              return;
            }
            final handled = await _handleBack();
            if (!handled && context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: Scaffold(
            appBar: _isFullScreen
                ? null
                : AppBar(
                    title: Text(widget.title ?? widget.initialUri.host),
                    actions: <Widget>[
                      IconButton(
                        tooltip: '旋转被控设备',
                        onPressed: _rotateDevice,
                        icon: const Icon(Icons.rotate_right),
                      ),
                      IconButton(
                        tooltip: _lockLandscape ? '跟随系统方向' : '锁定横屏',
                        onPressed: _toggleLandscapeLock,
                        icon: Icon(
                          _lockLandscape
                              ? Icons.screen_lock_rotation
                              : Icons.screen_rotation,
                        ),
                      ),
                    ],
                  ),
            body: AsyncStateView<Uri>(
              state: state,
              onRetry: _reload,
              errorHint: widget.viewModel.lastErrorDetail,
              loadingBuilder: (BuildContext context) => const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    CircularProgressIndicator(),
                    SizedBox(height: AppSpacing.md),
                    Text('正在加载网页壳…'),
                  ],
                ),
              ),
              dataBuilder: (BuildContext context, Uri uri) => Stack(
                children: <Widget>[
                  WebViewWidget(controller: controller),
                  Positioned(
                    right: AppSpacing.md,
                    bottom: AppSpacing.xl,
                    child: FloatingActionButton.small(
                      tooltip: _isFullScreen ? '显示标题栏' : '进入全屏',
                      onPressed: _toggleFullScreen,
                      child: Icon(
                        _isFullScreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
