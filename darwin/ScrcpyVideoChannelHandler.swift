import Foundation

// Flutter 的模块名在两端不同：iOS 是 `Flutter`，macOS 是 `FlutterMacOS`。
#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// `ws_scrcpy/video` 通道的 **iOS / macOS 共用实现**
/// （M2 路线 A：VideoToolbox 硬解 → Flutter 纹理）。文件放在 `darwin/`，两端项目各自引用。
///
/// 契约与 Android（`android/.../MainActivity.kt`）、Windows（`windows/runner/flutter_window.cpp`）
/// **完全一致**，Dart 侧是 `lib/feature/stream/data/remote/native_video_decoder.dart`：
///
/// | 方向 | 方法 | 参数 | 返回 |
/// |---|---|---|---|
/// | Dart → 原生 | `create` | 无 | `{"textureId": Int}` |
/// | Dart → 原生 | `pushFrame` | `Uint8List`（一帧 Annex-B） | `{"width": Int, "height": Int}` |
/// | Dart → 原生 | `getSize` | 无 | `{"width": Int, "height": Int}` |
/// | Dart → 原生 | `release` | 无 | `null` |
///
/// 尺寸走"回执 + 拉取"，**没有** `onSizeChanged` 反向推送——那条路径是 Windows 崩溃
/// `0x58CA5` 的成因（`AGENTS.md` §12.1），Apple 这端不重蹈。
/// （Dart 侧对"实现不推送"是兼容的：`native_video_decoder.dart` 的 `getSize` 与每次
/// `pushFrame` 的回执都能刷尺寸。）
///
/// **两端唯一的差异是"从哪拿纹理注册表"**，所以把它做成构造参数，
/// 而不是把这份通道逻辑复制成两份（见 `AGENTS.md` §12.3 的纪律：
/// 诊断/平台代码都不要维护第二份业务逻辑）：
///
/// | 端 | 主注册表 | 兜底 |
/// |---|---|---|
/// | iOS | `engineBridge.applicationRegistrar.textures()` | 当前 Scene 里的 `FlutterViewController`（§15.3：隐式引擎下主注册表会返回 0） |
/// | macOS | `flutterViewController.registrar(forPlugin:).textures` | `flutterViewController.engine`（引擎自己实现了 `FlutterTextureRegistry`） |
final class ScrcpyVideoChannelHandler: NSObject {

    /// 与 Android / Windows 保持同一个通道名。
    static let channelName = "ws_scrcpy/video"

    /// 调用方给出的主注册表。
    private let primaryTextureRegistry: FlutterTextureRegistry
    /// 兜底注册表；返回 nil 表示这条端上没有/暂时拿不到。
    private let fallbackTextureRegistry: () -> FlutterTextureRegistry?
    /// 实际完成注册的那个注册表——注销时必须用**同一个**，否则注销不掉。
    private var resolvedTextureRegistry: FlutterTextureRegistry?

    private let decoder = ScrcpyVideoDecoder()
    private var texture: ScrcpyVideoTexture?
    private var textureId: Int64 = 0
    private var channel: FlutterMethodChannel?

    init(
        messenger: FlutterBinaryMessenger,
        textureRegistry: FlutterTextureRegistry,
        fallbackTextureRegistry: @escaping () -> FlutterTextureRegistry? = { nil }
    ) {
        self.primaryTextureRegistry = textureRegistry
        self.fallbackTextureRegistry = fallbackTextureRegistry
        super.init()

        decoder.onDecodedFrame = { [weak self] buffer in
            // ★ 原生视频层优先：平台视图挂着时直接 enqueue（不进 Flutter 合成），
            //   没挂/状态异常时返回 false，继续走原来的 FlutterTexture 路径 ——
            //   两条路都在，出问题只是"回到旧行为"，不会黑屏。
            if ScrcpyVideoSurfaceRegistry.shared.enqueue(buffer) { return }
            self?.publish(buffer)
        }

        let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        self.channel = channel
        scrcpyVideoLog("通道入口已注册：\(Self.channelName)")
    }

    /// 由 AppDelegate 在引擎初始化时调用，避免通道与纹理活过引擎。
    func teardown() {
        releaseDecoder()
        channel?.setMethodCallHandler(nil)
        channel = nil
    }

    // MARK: - 通道

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "create":
            do {
                let id = try createDecoder()
                result(["textureId": id])
            } catch {
                scrcpyVideoLog("创建解码器失败：\(error.localizedDescription)")
                result(FlutterError(
                    code: "decoder_create_failed",
                    message: "创建 H.264 解码器失败：\(error.localizedDescription)",
                    details: nil))
            }

        case "pushFrame":
            guard let data = Self.frameData(from: call.arguments) else {
                result(FlutterError(
                    code: "invalid_argument",
                    message: "pushFrame 需要二进制参数",
                    details: nil))
                return
            }
            guard texture != nil else {
                result(FlutterError(
                    code: "decoder_not_created",
                    message: "解码器尚未创建",
                    details: nil))
                return
            }
            decoder.push(frame: data)
            let size = decoder.currentSize()
            result(["width": size.width, "height": size.height])

        case "getSize":
            let size = decoder.currentSize()
            result(["width": size.width, "height": size.height])

        case "release":
            releaseDecoder()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 实现

    private func createDecoder() throws -> Int64 {
        // 同一个引擎同时只保留一个投流画面：重复 create 先释放旧的（与 Android 一致）。
        releaseDecoder()

        let texture = ScrcpyVideoTexture()
        guard let (id, registry) = register(texture) else {
            throw NSError(
                domain: "ws_scrcpy",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "注册 Flutter 纹理失败（引擎与 FlutterViewController 两条路都返回 0）"])
        }
        resolvedTextureRegistry = registry
        self.texture = texture
        self.textureId = id
        decoder.start()
        scrcpyVideoLog("通道入口：create → textureId=\(id)")
        return id
    }

    /// 注册纹理，返回 (textureId, 实际生效的注册表)。
    ///
    /// **为什么要两条路（2026-10-02 在 iOS 模拟器实测）**：隐式引擎（Scene 生命周期）下
    /// `applicationRegistrar.textures()` 拿到的是 `FlutterTextureRegistryRelay`，它的 parent
    /// 是 **weak** 的，在引擎初始化那一刻还没接上宿主视图 → `registerTexture:` 直接返回 0。
    /// 现象是投流页红字"原生解码失败：创建 H.264 解码器失败：注册 Flutter 纹理失败"、
    /// 画面全黑（设备列表/投流本身都是通的）。
    /// `FlutterViewController` **自己就实现了 `FlutterTextureRegistry`**
    /// （`FlutterViewController.h:57`），它才是纹理归属的最终宿主，所以作为兜底。
    /// 两条都记日志，下次换 Flutter 版本时一眼能看出是哪条在生效。
    ///
    /// macOS 侧的主注册表走 `FlutterPluginRegistrar.textures`、兜底是引擎本身
    /// （`FlutterEngine` 实现了 `FlutterTextureRegistry`），预期第一条就成——
    /// 但这里不做平台假设，两条都试、都记日志。
    private func register(_ texture: ScrcpyVideoTexture) -> (Int64, FlutterTextureRegistry)? {
        let candidates: [(String, FlutterTextureRegistry?)] = [
            ("主注册表（iOS applicationRegistrar / macOS registrar）", primaryTextureRegistry),
            ("兜底注册表", fallbackTextureRegistry()),
        ]
        for (name, registry) in candidates {
            guard let registry else {
                scrcpyVideoLog("纹理注册：来源=\(name) 不可用（拿不到对象），跳过")
                continue
            }
            let id = registry.register(texture)
            if id != 0 {
                scrcpyVideoLog("纹理注册成功：来源=\(name)，textureId=\(id)")
                return (id, registry)
            }
            scrcpyVideoLog("纹理注册返回 0（失败）：来源=\(name)")
        }
        return nil
    }

    private func releaseDecoder() {
        decoder.stop()
        texture?.clear()
        if textureId != 0 {
            // 纹理的注册/注销都必须在 platform thread 上、且必须用注册时的同一个注册表；
            // `release` 由 Dart 发起，正好落在 platform thread。
            (resolvedTextureRegistry ?? primaryTextureRegistry).unregisterTexture(textureId)
            textureId = 0
        }
        resolvedTextureRegistry = nil
        texture = nil
    }

    /// 解码队列回调 → 登记最新一帧并通知引擎（引擎会在光栅线程调 `copyPixelBuffer`）。
    private func publish(_ buffer: CVPixelBuffer) {
        guard let texture else { return }
        texture.update(with: buffer)
        (resolvedTextureRegistry ?? primaryTextureRegistry).textureFrameAvailable(textureId)
    }

    /// Dart 侧传的是 `Uint8List`，到原生就是 `FlutterStandardTypedData`；
    /// 兼容直接给 `Data` 的调用方（自测/其它入口）。
    private static func frameData(from arguments: Any?) -> Data? {
        if let typed = arguments as? FlutterStandardTypedData {
            return typed.data
        }
        if let data = arguments as? Data {
            return data
        }
        return nil
    }
}
