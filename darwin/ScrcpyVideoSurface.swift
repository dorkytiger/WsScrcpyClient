import AVFoundation

// macOS 上 Flutter 的模块名是 `FlutterMacOS`，iOS 上才是 `Flutter` —— 与
// ScrcpyVideoChannelHandler.swift 保持同一种写法（这里是两端共用的一份文件）。
#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

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

  /// 已经成功 enqueue 的帧数；配合 `status == .rendering` 用来判断"原生层真的在工作"。
  private var enqueuedFrames = 0
  private var loggedFirstFrame = false

  /// 原生层是否已确认在消费帧。**没确认之前纹理路径继续跑** ——
  /// 否则一旦 layer 因为任何原因不显示（比如视图尺寸为 0），画面就直接黑了（实测踩过）。
  var isLive: Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let layer else { return false }
    return enqueuedFrames >= 3 && layer.status == .rendering
  }

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
    lock.lock()
    enqueuedFrames += 1
    let first = !loggedFirstFrame
    if first { loggedFirstFrame = true }
    lock.unlock()
    if first {
      // 一行把"layer 到底有没有条件显示"讲清楚：尺寸为 0 / 没进 window 都会是黑的
      // 注意：`window` 是 NSView/UIView 的属性，CALayer 上没有（写 `.window` 会编译失败）
      scrcpyVideoLog(
        "原生层首帧：layer bounds=\(layer.bounds.size) status=\(layer.status.rawValue) "
          + "ready=\(layer.isReadyForMoreMediaData)")
    }
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

#if os(iOS)

/// 交给 Flutter 的平台视图：只负责"把 layer 挂上/摘下"，
/// 真正的像素走 `ScrcpyVideoSurfaceRegistry.enqueue`（不经过 Dart）。
final class ScrcpyVideoSurfacePlatformView: NSObject, FlutterPlatformView {
  private let nativeView: ScrcpyVideoSurfaceNativeView
  private let displayLayer: AVSampleBufferDisplayLayer?

  init(frame: CGRect) {
    nativeView = ScrcpyVideoSurfaceNativeView(frame: frame)
    displayLayer = nativeView.displayLayer
    super.init()
    displayLayer?.videoGravity = .resizeAspect
    if let displayLayer { ScrcpyVideoSurfaceRegistry.shared.attach(displayLayer) }
  }

  // ★ 必须返回 `UIView` 而不是具体子类：Swift 的协议见证不允许协变返回类型，
  //   写成子类会报 `does not conform to protocol 'FlutterPlatformView'`（实测）。
  func view() -> UIView { nativeView }

  deinit {
    if let displayLayer { ScrcpyVideoSurfaceRegistry.shared.detach(displayLayer) }
  }
}

final class ScrcpyVideoSurfaceFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "ws_scrcpy/video_surface"

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    scrcpyVideoLog("原生视频层视图已创建（iOS）：id=\(viewId)")
    return ScrcpyVideoSurfacePlatformView(frame: frame)
  }
}

#elseif os(macOS)

/// macOS 的平台视图工厂与 iOS **不是一个协议**：这里直接返回 `NSView`，
/// 不需要 `FlutterPlatformView` 包装（那个类型在 FlutterMacOS 里根本不存在，
/// 见 `FlutterPlatformViews.h`：`createWithViewIdentifier:arguments:` → `NSView`）。
final class ScrcpyVideoSurfaceFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "ws_scrcpy/video_surface"

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    scrcpyVideoLog("原生视频层视图已创建（macOS）：id=\(viewId)")
    let view = ScrcpyVideoSurfaceNativeView(frame: .zero)
    view.wantsLayer = true
    let displayLayer = view.layer as? AVSampleBufferDisplayLayer
    displayLayer?.videoGravity = .resizeAspect
    if let displayLayer { ScrcpyVideoSurfaceRegistry.shared.attach(displayLayer) }
    return view
  }
}

#endif
