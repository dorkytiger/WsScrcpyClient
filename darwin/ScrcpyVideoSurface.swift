import AVFoundation
import Flutter

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 原生视频层（macOS / iOS 共用）：把解码出的 `CVPixelBuffer` **直接**送进
/// `AVSampleBufferDisplayLayer`，绕开 Flutter 的合成管线。
///
/// 为什么这么做 / 收益与风险见 `docs/native-video-surface-darwin.md`：
/// 现在这条链是 `解码器 → 拷进 FlutterTexture → 引擎合成 → 提交`，
/// 换成 `解码器 → AVSampleBufferDisplayLayer.enqueue()` 后少一次拷贝 + 一次合成排队（10–25ms）。
///
/// **两条路都留着**：平台视图没挂上（或失败）时，通道处理器继续走原来的 FlutterTexture 路径，
/// 所以任何异常都只是"回到旧行为"，不会黑屏。
final class ScrcpyVideoSurfaceRegistry {
  static let shared = ScrcpyVideoSurfaceRegistry()

  private var layer: AVSampleBufferDisplayLayer?
  private let lock = NSLock()

  private init() {}

  func attach(_ layer: AVSampleBufferDisplayLayer) {
    lock.lock()
    self.layer = layer
    lock.unlock()
    scrcpyVideoLog("原生视频层已接入：解码结果将直接送 layer（纹理路径让位）")
  }

  func detach(_ layer: AVSampleBufferDisplayLayer) {
    lock.lock()
    if self.layer === layer { self.layer = nil }
    lock.unlock()
    scrcpyVideoLog("原生视频层已断开：回退 FlutterTexture 路径")
  }

  /// 有原生层就 enqueue 并返回 `true`（调用方据此**跳过**纹理拷贝）。
  ///
  /// 积压策略与解码器一致：**跟不上就丢这一帧，绝不排队** —— 排队只会把延迟越堆越大。
  @discardableResult
  func enqueue(_ pixelBuffer: CVPixelBuffer) -> Bool {
    lock.lock()
    let layer = self.layer
    lock.unlock()
    guard let layer else { return false }

    if layer.status == .failed {
      scrcpyVideoLog("原生视频层状态异常，flush 后重试")
      layer.flush()
    }
    guard layer.isReadyForMoreMediaData else { return true }

    var format: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &format)
    guard let format else { return true }

    // presentationTimeStamp = .invalid + DisplayImmediately：不等排程，立刻显示（低延迟的关键）
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: format,
      sampleTiming: &timing,
      sampleBufferOut: &sample)
    guard let sample else { return true }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let count = CFArrayGetCount(attachments)
      if count > 0 {
        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CMSetAttachment(
          dict,
          key: kCMSampleAttachmentKey_DisplayImmediately,
          value: kCFBooleanTrue,
          attachmentMode: kCMAttachmentMode_ShouldPropagate)
      }
    }

    layer.enqueue(sample)
    return true
  }
}

#if os(iOS)

/// iOS 侧的原生显示视图：自带 layer 就是 `AVSampleBufferDisplayLayer`。
final class ScrcpyVideoSurfaceNativeView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

  var displayLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }
}

#elseif os(macOS)

/// macOS 侧的原生显示视图：backing layer 换成 `AVSampleBufferDisplayLayer`。
final class ScrcpyVideoSurfaceNativeView: NSView {
  override func makeBackingLayer() -> CALayer { AVSampleBufferDisplayLayer() }

  var displayLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }
}

#endif

/// 交给 Flutter 的平台视图：只负责"把 layer 挂上/摘下"，
/// 真正的像素走 `ScrcpyVideoSurfaceRegistry.enqueue`（不经过 Dart）。
final class ScrcpyVideoSurfacePlatformView: NSObject, FlutterPlatformView {
  private let nativeView: ScrcpyVideoSurfaceNativeView
  private let displayLayer: AVSampleBufferDisplayLayer?

  init(frame: CGRect) {
    nativeView = ScrcpyVideoSurfaceNativeView(frame: frame)
    #if os(macOS)
    nativeView.wantsLayer = true
    #endif
    displayLayer = nativeView.displayLayer
    super.init()

    // 与现有渲染语义保持一致：contain（cover 模式 P1 再做进原生层，先回退纹理路径）
    displayLayer?.videoGravity = .resizeAspect
    if let displayLayer { ScrcpyVideoSurfaceRegistry.shared.attach(displayLayer) }
  }

  func view() -> ScrcpyVideoSurfaceNativeView { nativeView }

  deinit {
    if let displayLayer { ScrcpyVideoSurfaceRegistry.shared.detach(displayLayer) }
  }
}

/// 平台视图工厂。视图类型名与 Dart 侧 `NativeVideoSurface.viewType` 必须一致。
final class ScrcpyVideoSurfaceFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "ws_scrcpy/video_surface"

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    scrcpyVideoLog("原生视频层视图已创建：id=\(viewId)")
    return ScrcpyVideoSurfacePlatformView(frame: frame)
  }
}
