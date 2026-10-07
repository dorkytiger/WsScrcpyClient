import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 原生视频层（macOS / iOS 先行）：让解码结果**直接**进平台视图，绕开 Flutter 合成。
///
/// 背景、收益（10–25ms）与风险见 `docs/native-video-surface-darwin.md`；
/// 原生侧实现在 `darwin/ScrcpyVideoSurface.swift`（两端共用一份）。
///
/// 两条路都在：原生层没挂上/状态异常时，原生侧会返回 false 并继续走 FlutterTexture，
/// 所以这里切过去不会黑屏，最坏情况就是"回到旧行为"。
///
/// ★ **手势必须留在 Flutter 侧**：视频上的触摸要发给被控设备（见 AGENTS §9.1/§10），
/// 所以平台视图用 `PlatformViewHitTestBehavior.transparent` —— 它对命中测试透明，
/// Flutter 侧的 `Listener`（`_VideoStage`）照旧拿到指针事件，坐标换算完全不用改。
class NativeVideoSurface extends StatelessWidget {
  const NativeVideoSurface({super.key});

  /// 平台视图类型名，必须与原生 `ScrcpyVideoSurfaceFactory.viewType` 一致。
  static const String viewType = 'ws_scrcpy/video_surface';

  /// 测试钩子：强制走 FlutterTexture 路径（widget 测试断言的是那条路的几何）。
  static bool debugForceTexture = false;

  /// 原生层开关。**默认开**（用户 2026-10-07 定调：不要纹理兜底 ——
  /// "能实现就是能稳定跑，不能实现就是不能实现"）。关掉它只会用于单元测试/对照实验。
  static bool debugForceEnabled = true;

  /// 该平台有没有原生层实现（darwin 先行；Android/Windows 见方案 P2）。
  ///
  /// ⚠️ 两端原生 API **不同名**：iOS 用 `FlutterPlatformView` 包装，
  /// macOS 的工厂直接返回 `NSView`（`FlutterPlatformViews.h`）—— 细节见
  /// docs/native-video-surface-darwin.md。
  static bool get isPlatformSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// 是否走原生层：平台支持 + 显式开启 + 没被测试强制关掉。
  static bool get isEnabled =>
      isPlatformSupported && debugForceEnabled && !debugForceTexture;

  @override
  Widget build(BuildContext context) {
    // 非 iOS/macOS 不该走到这里（调用方先问 isEnabled），真走到就什么都不画。
    if (!isEnabled) return const SizedBox.shrink();

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: viewType,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      );
    }
    return AppKitView(
      viewType: viewType,
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    );
  }
}
