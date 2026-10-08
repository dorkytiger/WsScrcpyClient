import AVFoundation

// macOS 上 Flutter 的模块名是 `FlutterMacOS`，iOS 上才是 `Flutter`（两端共用这一份文件）。
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
/// 设计原则（用户 2026-10-07 明确要求）：**没有纹理兜底** —— 挂着原生层就走原生层，
/// "能实现就是能稳定跑，不能实现就是不能实现"。这里只做一件事：把帧用**最标准的方式**送进 layer。
/// 背景与实测记录见 `docs/native-video-surface-darwin.md`。
final class ScrcpyVideoSurfaceRegistry {
  static let shared = ScrcpyVideoSurfaceRegistry()

  private var layer: AVSampleBufferDisplayLayer?
  private let lock = NSLock()

  /// 自增序号：用来造**递增的有效 PTS**（PTS 为 invalid 时，若 DisplayImmediately
  /// 那个 attachment 没被 layer 采纳，layer 会永远不出图 —— 实测全黑）。
  private var frameIndex: Int64 = 0
  private var loggedFirstFrame = false

  private init() {}

  func attach(_ layer: AVSampleBufferDisplayLayer) {
    lock.lock()
    self.layer = layer
    lock.unlock()
    scrcpyVideoLog("原生视频层已接入：解码结果直接送 layer")
  }

  func detach(_ layer: AVSampleBufferDisplayLayer) {
    lock.lock()
    if self.layer === layer { self.layer = nil }
    lock.unlock()
    scrcpyVideoLog("原生视频层已断开")
  }

  /// 把解码帧送进原生层；挂着 layer 返回 `true`（调用方不再走纹理）。
  @discardableResult
  func enqueue(_ pixelBuffer: CVPixelBuffer) -> Bool {
    lock.lock()
    let layer = self.layer
    lock.unlock()
    guard let layer else { return false }

    if layer.status == .failed {
      scrcpyVideoLog("原生层状态异常，flush 重来")
      layer.flush()
    }
    guard layer.isReadyForMoreMediaData else { return true }  // 跟不上就丢这帧，不排队

    var format: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &format)
    guard let format else { return true }

    lock.lock()
    frameIndex += 1
    let index = frameIndex
    lock.unlock()

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 60),
      presentationTimeStamp: CMTime(value: index, timescale: 60),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: format,
      sampleTiming: &timing,
      sampleBufferOut: &sample)
    guard let sample else { return true }

    // `CMSampleBuffer` 本身符合 `CMAttachmentBearer` → 直接 CMSetAttachment。
    // （不要走 unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0)) 那条路：很可能
    //   根本没写到该写的地方 —— 这是上一版全黑的可疑点之一。）
    CMSetAttachment(
      sample,
      key: kCMSampleAttachmentKey_DisplayImmediately,
      value: kCFBooleanTrue,
      attachmentMode: kCMAttachmentMode_ShouldPropagate)  // CMMAttachmentMode 是 UInt32 别名，没有 Swift 枚举成员

    layer.enqueue(sample)

    lock.lock()
    let first = !loggedFirstFrame
    if first { loggedFirstFrame = true }
    lock.unlock()
    if first {
      scrcpyVideoLog(
        "原生层首帧：bounds=\(layer.bounds.size) status=\(layer.status.rawValue) "
          + "ready=\(layer.isReadyForMoreMediaData) pts=\(timing.presentationTimeStamp.seconds)")
    }
    return true
  }
}

#if os(iOS)

/// iOS：视图自带的 layer 就是 `AVSampleBufferDisplayLayer`。
final class ScrcpyVideoSurfaceNativeView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }
}

/// iOS 的平台视图包装：`FlutterPlatformView` 要求 `view()` 返回 **UIView**
///（返回具体子类会报协议不满足：Swift 的协议见证不允许协变返回）。
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

/// macOS：把 backing layer 换成 `AVSampleBufferDisplayLayer`。
final class ScrcpyVideoSurfaceNativeView: NSView {
  override func makeBackingLayer() -> CALayer { AVSampleBufferDisplayLayer() }
  var displayLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }
}

/// macOS 的平台视图工厂与 iOS **不是同一个协议**（`FlutterPlatformViews.h`）：
/// `createWithViewIdentifier:arguments:`（Swift: `create(withViewIdentifier:arguments:)`）
/// **直接返回 `NSView`** —— 没有 iOS 那个 `FlutterPlatformView` 包装类型。
final class ScrcpyVideoSurfaceFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "ws_scrcpy/video_surface"

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    scrcpyVideoLog("原生视频层视图已创建（macOS）：id=\(viewId)")
    let view = ScrcpyVideoSurfaceNativeView(frame: .zero)
    view.wantsLayer = true
    let displayLayer = view.layer as? AVSampleBufferDisplayLayer
    displayLayer?.videoGravity = .resizeAspect
    if let displayLayer { ScrcpyVideoSurfaceRegistry.shared.attach(displayLayer) }

    // "layer 明明在 rendering 却看不见" 的第一嫌疑是层级/位置：把事实打出来。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak view] in
      guard let view else { return }
      scrcpyVideoLog(
        "原生层视图：frame=\(view.frame) hidden=\(view.isHidden) "
          + "superview=\(view.superview != nil) window=\(view.window != nil) "
          + "alpha=\(view.alphaValue) layerBounds=\(view.layer?.bounds.size ?? .zero)")
    }
    return view
  }
}

#endif
