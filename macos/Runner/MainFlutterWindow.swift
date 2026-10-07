import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 原生 H.264 硬解通道（M2 路线 A / macOS：VideoToolbox → Flutter 纹理）。
  ///
  /// 必须**持有**它：`FlutterMethodChannel` 的处理器与解码器/纹理的生命周期都挂在这个对象上，
  /// 只创建不保存的话会被立刻释放，通道调用全部落空。
  ///
  /// 通道实现、纹理与解码器都在 `darwin/`（与 iOS **共用同一份文件**）——
  /// 本文件是 macOS 侧唯一需要写的东西，就是"把注册表接上"。
  private var videoChannel: ScrcpyVideoChannelHandler?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 与 iOS / Android / Windows 注册的是同一个通道名 `ws_scrcpy/video`，
    // 所以 Dart 侧一行都不用改（lib/feature/stream/data/remote/native_video_decoder.dart）。
    //
    // 拿注册表的路径与 iOS 不同：macOS 走 `FlutterPluginRegistrar`
    // （`messenger` / `textures` 是**属性**，iOS 上是方法）。
    // 兜底用引擎本身——`FlutterEngine` 也实现了 `FlutterTextureRegistry`。
    // 原生视频层（见 docs/native-video-surface-darwin.md）：视图工厂与视频通道同一个注册表。
    flutterViewController
      .registrar(forPlugin: "WsScrcpyVideoSurface")
      .register(ScrcpyVideoSurfaceFactory(), withId: ScrcpyVideoSurfaceFactory.viewType)

    let registrar = flutterViewController.registrar(forPlugin: "WsScrcpyVideo")
    videoChannel = ScrcpyVideoChannelHandler(
      messenger: registrar.messenger,
      textureRegistry: registrar.textures,
      fallbackTextureRegistry: { flutterViewController.engine })

    super.awakeFromNib()
  }

  /// 窗口关闭时摘掉通道，避免回调活过引擎（与 iOS 侧 `teardown` 同一个意图）。
  override func close() {
    videoChannel?.teardown()
    videoChannel = nil
    super.close()
  }
}
