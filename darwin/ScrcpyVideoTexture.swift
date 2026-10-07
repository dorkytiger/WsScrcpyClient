import CoreVideo
import Foundation

// Flutter 的模块名在两端不同：iOS 是 `Flutter`，macOS 是 `FlutterMacOS`。
// 这是 iOS / macOS 共享源码的标准写法（Flutter 自己的 federated 插件也这么写）。
#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// 把解码出来的 `CVPixelBuffer` 交给 Flutter 引擎渲染的纹理。
///
/// **iOS / macOS 共用同一份**（放在 `darwin/`）。
///
/// 线程约定（`docs/platform-feasibility.md` §3.2.2，也是本平台风险最高的一环）：
/// - `copyPixelBuffer()` 由引擎的**光栅线程**调用；
/// - 写"最新一帧"的是**解码队列**；
/// - 两者必须用锁隔开，且**锁里只做取引用，不做解码/拷贝**。
///
/// 所有权：`copyPixelBuffer()` 返回 `Unmanaged.passRetained`，等于把 +1 的引用交给引擎，
/// 由引擎负责释放；`latestBuffer` 自己那份强引用一直留着，所以缓冲在被下一帧替换之前
/// 不会被释放（不会出现"我们释放了、引擎还在读"的 use-after-free）。
/// 返回 nil 表示还没解出第一帧——**必须**返回 nil，不能给一个空的/未初始化的缓冲。
final class ScrcpyVideoTexture: NSObject, FlutterTexture {

    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?

    /// 解码队列调用：登记最新一帧。
    func update(with buffer: CVPixelBuffer) {
        lock.lock()
        latestBuffer = buffer
        lock.unlock()
    }

    /// 释放前调用：把引用放掉，免得纹理注销后引擎还拿到旧帧。
    func clear() {
        lock.lock()
        latestBuffer = nil
        lock.unlock()
    }

    /// 引擎（光栅线程）调用。见类注释的所有权说明。
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        let buffer = latestBuffer
        lock.unlock()
        guard let buffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }
}
