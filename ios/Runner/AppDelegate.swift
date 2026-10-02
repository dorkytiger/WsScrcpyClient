import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 原生 H.264 硬解通道（M2 路线 A / iOS：VideoToolbox → Flutter 纹理）。
  ///
  /// 必须**持有**它：`FlutterMethodChannel` 的处理器与解码器/纹理的生命周期都挂在这个对象上，
  /// 只创建不保存的话会被立刻释放，通道调用全部落空。
  ///
  /// 通道实现与解码器都在 `darwin/`（iOS / macOS 共用同一份文件）。
  private var videoChannel: ScrcpyVideoChannelHandler?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 本项目的 iOS 是 **Scene 生命周期 + 隐式引擎**（Info.plist 的 UIApplicationSceneManifest
    // + SceneDelegate），拿不到"在 didFinishLaunching 里取 window.rootViewController"那种
    // 常见示例里的 FlutterViewController。引擎只在这里暴露出来，所以通道就在这里注册。
    // `applicationRegistrar` 同时提供 messenger 与纹理注册表。
    // 详见 docs/platform-feasibility.md §3.2.1。
    //
    // `fallbackTextureRegistry`：隐式引擎下 `applicationRegistrar.textures()` 拿到的是
    // `FlutterTextureRegistryRelay`，它的 parent 是 **weak** 的，此刻还没接上宿主视图 →
    // `registerTexture:` 直接返回 0（画面全黑，报"注册 Flutter 纹理失败"）。
    // `FlutterViewController` 自己就实现了 `FlutterTextureRegistry`，作为兜底。
    // 详见 AGENTS §15.3。
    videoChannel = ScrcpyVideoChannelHandler(
      messenger: engineBridge.applicationRegistrar.messenger(),
      textureRegistry: engineBridge.applicationRegistrar.textures(),
      fallbackTextureRegistry: { AppDelegate.findFlutterViewController() })
  }

  /// 在当前 Scene 的窗口层级里找 `FlutterViewController`
  /// （storyboard 的 initial controller 就是它；这里用递归兼容被导航/标签容器包一层的情况）。
  private static func findFlutterViewController() -> FlutterTextureRegistry? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        if let found = findFlutterViewController(in: window.rootViewController) {
          return found
        }
      }
    }
    return nil
  }

  private static func findFlutterViewController(
    in controller: UIViewController?
  ) -> FlutterViewController? {
    guard let controller else { return nil }
    if let flutter = controller as? FlutterViewController {
      return flutter
    }
    for child in controller.children {
      if let flutter = findFlutterViewController(in: child) {
        return flutter
      }
    }
    if let presented = controller.presentedViewController {
      return findFlutterViewController(in: presented)
    }
    return nil
  }
}
