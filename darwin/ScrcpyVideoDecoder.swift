import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 原生侧日志：**两个出口都要写**。
///
/// Windows 那轮的教训（`AGENTS.md` §12.2）：解码器日志只走调试器通道的话，
/// `flutter run` 的控制台里什么都看不到，真机排查会全程静默。这里是同一课在 iOS 上的翻版
/// （2026-10-02 实测：`NSLog` 只进系统日志，`flutter run` 抓不到）——
///
/// - `NSLog` → 系统日志：`xcrun simctl spawn booted log show --predicate 'process == "Runner"'`
///   或 Console.app 可见，带时间戳与进程信息；
/// - `print` → stdout：`flutter run` 的控制台直接可见。
func scrcpyVideoLog(_ message: String) {
    NSLog("[ScrcpyVideo] %@", message)
    print("[ScrcpyVideo] \(message)")
}

/// 用 VideoToolbox 硬解 scrcpy 下发的裸 H.264（Annex-B），输出 `CVPixelBuffer`。
///
/// 与 Windows（`windows/runner/scrcpy_video_decoder.cpp`，Media Foundation MFT）、
/// Android（`ScrcpyVideoDecoder.kt`，MediaCodec）是同一层的三个实现，共用
/// `lib/feature/stream/data/remote/native_video_decoder.dart` 的通道契约。
///
/// 两个**必须**照做的点（`AGENTS.md` §1.2）：
///
/// 1. **低延迟**：`kVTDecompressionPropertyKey_RealTime = true`。
///    Windows 上漏掉对应开关（`MF_LOW_LATENCY`）的后果是"默认攒约 1.2 秒才吐第一帧"——
///    画面静止时服务端只给二十来帧，于是**永远黑屏**；编码器一重建就再攒一批，
///    表现为"隔几秒卡一下然后一次性追平"。Apple 这端不允许只靠默认值。
///    （`VTDecompressionProperties.h` 说 RealTime 默认是 true，我们仍然显式设一次并记返回码，
///    这样日志里能自证，不必去猜系统版本的行为。）
/// 2. **输入是 AVCC 不是 Annex-B**：VideoToolbox 的 H.264 输入按"4 字节大端长度前缀"解释
///    （`CMVideoFormatDescriptionCreateFromH264ParameterSets` 的 `nalUnitHeaderLength = 4`），
///    而协议给的是起始码分隔的 Annex-B。所以每条消息都要先过 [`annexBToAVCC`]。
///    忘了转换的典型症状是 `kVTVideoDecoderBadDataErr`（-12909）→ 一帧都出不来。
///
/// 本类**不 import Flutter**（只用 Foundation / CoreMedia / VideoToolbox），
/// 因此 macOS 可以复用同一份文件，也能在 Mac 上直接编译成命令行探针离线验证
/// （见 `tools/run_vt_replay_probe.sh`）。Flutter 相关的东西在
/// `ScrcpyVideoTexture.swift` 与 `ScrcpyVideoChannelHandler.swift`。
final class ScrcpyVideoDecoder {

    // MARK: - 常量

    /// 等待解码的帧数上限，超出丢最旧的帧。
    ///
    /// 取值理由（`AGENTS.md` §12.8 的教训：队列会把延迟放大，Windows 因此从 60 降到 4）：
    /// - **比 Android 的 60 窄得多**——60 帧 ≈ 2 秒，一旦积压就是"延迟滚雪球"；
    /// - **比 Windows 的 4 略宽**——VideoToolbox 是硬解、正常远快于 30fps 的到达节奏，
    ///   队列平常就是空的，这里只是异常情况下的兜底，留一点余量吸收调度抖动。
    ///
    /// 注意丢帧的代价：H.264 的 P 帧引用前面的帧，丢掉中间的帧会让画面花到下一个 IDR 为止。
    /// 所以这个值不能太小，且丢帧必须记进心跳（下面的 `丢弃` 计数）。
    private static let maxPendingFrames = 8

    /// 喂给解码器的时间戳时基。协议没开 `sendFrameMeta`，WS 消息里没有 PTS
    /// （`docs/ws-scrcpy-protocol.md` §6.3），所以按到达顺序自增造一个单调时间戳。
    private static let frameTimescale: CMTimeScale = 30

    /// 心跳间隔。
    private static let heartbeatInterval: CFTimeInterval = 1.0

    /// 距上一帧超过这么久就发一条 WARNING。
    ///
    /// 阈值取 5 秒、且措辞把"设备画面没变化"放最前面：scrcpy **只在画面变化时发帧**，
    /// 静止时"没有帧"是正常的（Windows 上 3 秒就喊 WARNING 曾被用户当成报错，见 `AGENTS.md` §12.2）。
    private static let stallWarningInterval: CFTimeInterval = 5.0

    // MARK: - 对外回调

    /// 每解出一帧调一次。**在解码队列上回调**，实现方自己决定要不要切线程。
    var onDecodedFrame: ((CVPixelBuffer) -> Void)?

    // MARK: - 内部状态

    private let queue = DispatchQueue(label: "ws-scrcpy.video.decode")
    private let lock = NSLock()

    /// **仅供离线探针**做"低延迟 A/B"（`tools/run_vt_replay_probe.sh`）：
    /// `nil`（默认）= 设 `kVTDecompressionPropertyKey_RealTime = true`；
    /// 设为 `false` 可以复现"不设低延迟"的行为，用来证明这个开关确实有用。
    /// 对齐 Windows 的 `tools\run_mft_replay_probe.cmd`（那边 A/B 出的是 8/43 vs 42/43）。
    var realtimeOverrideForProbe: Bool?

    /// **仅供离线探针**：完全不设 `RealTime` 属性，用来印证"系统默认值就是实时"
    /// （`VTDecompressionProperties.h` 这么写，探针负责把它变成实测事实）。
    var skipRealtimePropertyForProbe = false

    /// 诊断计数快照（离线探针与排障用；从**非解码队列**调用是安全的）。
    ///
    /// 口径与心跳一致：`已解出 ≪ 已喂入` = 解码器在憋；`丢弃 > 0` = 推得比解的快，
    /// 而丢帧会断掉 H.264 的参考帧链（画面花到下一个 IDR 为止），所以这个数必须能看见。
    struct DebugStats {
        let received: Int
        let fed: Int
        let decoded: Int
        let dropped: Int
    }

    var debugStats: DebugStats {
        lock.lock()
        let received = receivedCount
        let dropped = droppedCount
        lock.unlock()
        let (fed, decoded) = queue.sync { (fedCount, decodedCount) }
        return DebugStats(received: received, fed: fed, decoded: decoded, dropped: dropped)
    }

    /// 还没喂给解码器的帧（FIFO）。用 `lock` 保护。
    private var pendingFrames: [Data] = []
    /// 是否已经有一个 drain 循环在跑（避免每帧都 schedule 一次）。
    private var draining = false
    private var released = false
    private var pendingDepth = 0

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var spsBytes: [UInt8]?
    private var ppsBytes: [UInt8]?

    private var frameIndex: Int64 = 0
    private var currentWidth = 0
    private var currentHeight = 0

    // 诊断计数（口径与 Windows 一致：收到 / 已喂入 / 已解出 / 丢弃）
    private var receivedCount = 0
    private var droppedCount = 0
    private var fedCount = 0
    private var decodedCount = 0
    private var decodeErrorCount = 0
    private var formatChangeCount = 0
    private var lastDecodeAt: CFTimeInterval?
    private var lastHeartbeatAt: CFTimeInterval = 0
    private var lastStallWarningAt: CFTimeInterval = 0
    private var warnedMissingFormat = false

    // MARK: - 生命周期

    /// 开始一次投流（`create` 时调）。可重复调用。
    func start() {
        lock.lock()
        released = false
        pendingFrames.removeAll()
        pendingDepth = 0
        receivedCount = 0
        droppedCount = 0
        lock.unlock()

        queue.sync {
            fedCount = 0
            decodedCount = 0
            decodeErrorCount = 0
            formatChangeCount = 0
            frameIndex = 0
            lastDecodeAt = nil
            lastHeartbeatAt = 0
            lastStallWarningAt = 0
            warnedMissingFormat = false
            currentWidth = 0
            currentHeight = 0
            spsBytes = nil
            ppsBytes = nil
            formatDescription = nil
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
        }
        scrcpyVideoLog("解码器已启动（等待 SPS/PPS 决定分辨率）")
    }

    /// 释放解码会话。可重复调用。
    func stop() {
        lock.lock()
        if released {
            lock.unlock()
            return
        }
        released = true
        pendingFrames.removeAll()
        pendingDepth = 0
        lock.unlock()

        // 串行队列保证此刻没有 decode 在跑，再去 invalidate，避免和输出回调抢。
        queue.sync {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            formatDescription = nil
            spsBytes = nil
            ppsBytes = nil
            scrcpyVideoLog("解码器已释放：收到 \(receivedCount)，已解出 \(decodedCount)")
        }
    }

    /// 当前已知的画面尺寸；还没拿到 SPS 时为 (0, 0)。
    ///
    /// 尺寸走"回执 / 拉取"给 Dart，**不做反向推送**——反向推送是 Windows 崩溃
    /// `0x58CA5` 的成因（跨线程任务活过它捕获的状态，见 `AGENTS.md` §12.1）。
    func currentSize() -> (width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (currentWidth, currentHeight)
    }

    // MARK: - 喂帧

    /// 入队一帧 Annex-B。**立刻返回**，真正的解码在串行队列上做
    /// （Windows 的设计意图：platform thread 不做重活）。
    func push(frame: Data) {
        var depthToLog: Int?
        lock.lock()
        if released {
            lock.unlock()
            return
        }
        receivedCount += 1
        if pendingFrames.count >= Self.maxPendingFrames {
            pendingFrames.removeFirst()
            droppedCount += 1
            // 丢帧日志限流：每 60 次记一条，异常能看见但不刷屏。
            if droppedCount == 1 || droppedCount % 60 == 0 {
                depthToLog = pendingFrames.count
            }
        }
        pendingFrames.append(frame)
        pendingDepth = pendingFrames.count
        let shouldStart = !draining
        if shouldStart {
            draining = true
        }
        lock.unlock()

        if let depth = depthToLog {
            scrcpyVideoLog("解码跟不上，丢弃最旧的帧（第 \(droppedCount) 次），队列深度 \(depth)")
        }
        if shouldStart {
            queue.async { [weak self] in
                self?.drain()
            }
        }
    }

    /// 串行消费待解码队列。只有一条 drain 循环在跑（`draining` 标记）。
    private func drain() {
        while true {
            lock.lock()
            if released {
                draining = false
                lock.unlock()
                return
            }
            if pendingFrames.isEmpty {
                draining = false
                pendingDepth = 0
                lock.unlock()
                return
            }
            let frame = pendingFrames.removeFirst()
            pendingDepth = pendingFrames.count
            lock.unlock()

            autoreleasepool {
                decode(frame)
            }
        }
    }

    // MARK: - 解码

    private func decode(_ data: Data) {
        let bytes = [UInt8](data)
        let units = Self.splitNALUnits(bytes)
        guard !units.isEmpty else {
            // 协议实测是 Annex-B；一条没有起始码的消息说明上游出了问题，直接拒绝而不是猜。
            scrcpyVideoLog("拒绝一条不含起始码的视频消息（\(bytes.count) 字节）——协议约定是 Annex-B")
            return
        }

        var newSPS: [UInt8]?
        var newPPS: [UInt8]?
        var hasSlice = false
        for unit in units {
            switch unit.type {
            case 7:
                newSPS = Array(bytes[unit.range])
            case 8:
                newPPS = Array(bytes[unit.range])
            case 1, 5:
                hasSlice = true
            default:
                break
            }
        }

        // 参数集变了（首帧、或投流中分辨率变化 / 编码器重建）→ 重建格式描述与解码会话。
        if let sps = newSPS, let pps = newPPS, sps != spsBytes || pps != ppsBytes {
            rebuild(sps: sps, pps: pps)
        }

        // 只含参数集、不含 VCL 的那条消息（scrcpy 每条连接开头先发一条 SPS+PPS）：
        // 它的作用是让解码器知道真实分辨率，不能当样本喂进去。
        guard hasSlice else { return }

        guard let session, let formatDescription else {
            if !warnedMissingFormat {
                warnedMissingFormat = true
                scrcpyVideoLog("收到片数据但还没有可用的格式描述（SPS/PPS 尚未到达）——已跳过该帧")
            }
            return
        }

        let presentationTime = CMTime(value: frameIndex, timescale: Self.frameTimescale)
        frameIndex += 1

        guard let sampleBuffer = makeSampleBuffer(
            avcc: Self.annexBToAVCC(bytes, units: units),
            formatDescription: formatDescription,
            presentationTime: presentationTime)
        else {
            scrcpyVideoLog("构造 CMSampleBuffer 失败（AVCC \(bytes.count) 字节）——已丢弃该帧")
            return
        }

        fedCount += 1
        var infoFlags = VTDecodeInfoFlags()
        // flags 留空：按 VTDecompressionSession.h 的说明，两个 flag 都不设时
        // 解码在本次调用返回前完成、输出回调同步触发。同步有它的好处——
        // 解码速率天然被串行队列约束，队列不会因为异步回调乱序而失真。
        // 注意 Swift 名：VideoToolbox 的 apinotes 把
        // `VTDecompressionSessionDecodeFrameWithOutputHandler` 重命名成了
        // `VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:infoFlagsOut:outputHandler:)`
        // （不是同名的那个 C 函数，参数标签也不同——照 C 头文件写会报 Extraneous argument labels）。
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { [weak self] decodeStatus, _, imageBuffer, _, _ in
            self?.handleDecoded(status: decodeStatus, imageBuffer: imageBuffer)
        }

        if status != noErr {
            // 注意：这个调用返回错误时输出回调**不会**被调（头文件明写），
            // 所以错误计数和日志只能在这里补。
            decodeErrorCount += 1
            logDecodeError(status: status, prefix: "VTDecompressionSessionDecodeFrame")
        }

        lastDecodeAt = CFAbsoluteTimeGetCurrent()
        heartbeatIfNeeded()
    }

    private func handleDecoded(status: OSStatus, imageBuffer: CVImageBuffer?) {
        guard status == noErr, let imageBuffer else {
            decodeErrorCount += 1
            logDecodeError(status: status, prefix: "解码输出")
            return
        }
        guard let pixelBuffer = imageBuffer as? CVPixelBuffer else {
            scrcpyVideoLog("解码输出不是 CVPixelBuffer")
            return
        }
        decodedCount += 1
        // 实际渲染出去的是这张缓冲，尺寸以它为准（SPS 给的编码尺寸正常情况下一致）。
        applySize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if decodedCount == 1 {
            scrcpyVideoLog("已解出第一帧并交给纹理（\(currentWidth)x\(currentHeight)）")
        }
        onDecodedFrame?(pixelBuffer)
    }

    /// 把 VideoToolbox 的错误码翻成可读中文——"黑屏"时能一眼看出是帧格式问题还是会话问题。
    private func logDecodeError(status: OSStatus, prefix: String) {
        let reason: String
        switch status {
        case -12909:
            reason = "kVTVideoDecoderBadDataErr：喂进去的字节不是解码器期待的格式"
                + "（绝大多数情况是 Annex-B→AVCC 转换漏了，或 nalUnitHeaderLength 不是 4）"
        case -12916:
            reason = "kVTFormatDescriptionChangeNotSupportedErr：中途换了格式描述而会话没重建"
        case -12911:
            reason = "kVTVideoDecoderMalfunctionErr：解码器内部错误，只能整会话重建"
        case -12902:
            reason = "kVTVideoDecoderNotAvailableNowErr：解码器当前不可用（多半是后台/被系统回收）"
        default:
            reason = "未知 VideoToolbox 错误"
        }
        // 限流：坏数据会连续刷屏。
        if decodeErrorCount <= 3 || decodeErrorCount % 60 == 0 {
            scrcpyVideoLog("\(prefix) 失败（第 \(decodeErrorCount) 次）status=\(status)：\(reason)")
        }
    }

    // MARK: - 格式描述与解码会话

    private func rebuild(sps: [UInt8], pps: [UInt8]) {
        guard !sps.isEmpty, !pps.isEmpty else {
            scrcpyVideoLog("参数集为空（SPS \(sps.count) 字节 / PPS \(pps.count) 字节）——忽略")
            return
        }
        spsBytes = sps
        ppsBytes = pps

        var description: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer in
                var pointers: [UnsafePointer<UInt8>] = []
                if let base = spsBuffer.baseAddress { pointers.append(base) }
                if let base = ppsBuffer.baseAddress { pointers.append(base) }
                var sizes = [spsBuffer.count, ppsBuffer.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    // 4 = 后续样本里的 NAL 前面是 4 字节大端长度（AVCC），不是起始码。
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else {
            scrcpyVideoLog("构造 CMVideoFormatDescription 失败：status=\(status)"
                + "（SPS \(sps.count) 字节 / PPS \(pps.count) 字节）")
            return
        }
        formatDescription = description

        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        applySize(width: Int(dimensions.width), height: Int(dimensions.height))

        if let existing = session {
            formatChangeCount += 1
            scrcpyVideoLog("参数集变化（第 \(formatChangeCount) 次），重建解码会话："
                + "\(Int(dimensions.width))x\(Int(dimensions.height))")
            VTDecompressionSessionInvalidate(existing)
            session = nil
        }

        // 输出像素格式：32BGRA。
        // FlutterTexture.h 明写支持的就是 32BGRA / 420v / 420f 三种；选 BGRA 是因为
        // VideoToolbox 在硬件里就把 YUV→RGB 做掉了，我们拿到的缓冲可以直接上屏，
        // 不需要自己写一遍 NV12→RGBA（Windows 那轮 CPU 整帧换算的教训，见 §12.8）。
        // IOSurface 属性给空字典是让缓冲由 IOSurface 承载的常规写法——引擎侧要靠它
        // 把缓冲直接映射成 Metal 纹理（潜在零拷贝）。
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession)
        guard createStatus == noErr, let newSession else {
            scrcpyVideoLog("VTDecompressionSessionCreate 失败：status=\(createStatus)")
            return
        }
        session = newSession

        // ★ 低延迟（`AGENTS.md` §1.2）。显式设置 + 记返回码，日志里能自证。
        // 离线探针可以覆盖/跳过这一步做 A/B（见 realtimeOverrideForProbe 的注释）。
        if skipRealtimePropertyForProbe {
            scrcpyVideoLog("低延迟模式：**本次刻意不设** kVTDecompressionPropertyKey_RealTime（探针 A/B 用）")
        } else {
            let realtimeValue = realtimeOverrideForProbe ?? true
            let realtimeStatus = VTSessionSetProperty(
                newSession,
                key: kVTDecompressionPropertyKey_RealTime,
                value: realtimeValue ? kCFBooleanTrue : kCFBooleanFalse)
            scrcpyVideoLog(
                "低延迟模式：kVTDecompressionPropertyKey_RealTime=\(realtimeValue) "
                    + "设置结果=\(hexStatus(realtimeStatus))")
        }

        // **不要**设 kVTDecompressionPropertyKey_MaximizePowerEfficiency。
        // VTDecompressionProperties.h 原文："Setting both MaximizePowerEfficiency and RealTime
        // is unsupported and results in undefined behavior"，而它的默认值本来就是 false（省电关闭），
        // 不设正是我们要的效果。（可行性文档里"顺手设成 false"的建议与头文件冲突，这里不采纳。）

        if #available(iOS 17.0, macOS 14.0, *) {
            // 只读，用来确认真的走了硬解（排障用；模拟器上一般是 false）。
            var hardwareRef: CFTypeRef?
            let copyStatus = withUnsafeMutablePointer(to: &hardwareRef) { pointer -> OSStatus in
                VTSessionCopyProperty(
                    newSession,
                    key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                    allocator: kCFAllocatorDefault,
                    valueOut: pointer)
            }
            if copyStatus == noErr, let value = hardwareRef as? Bool {
                scrcpyVideoLog("硬解：\(value ? "是" : "否（当前是软件解码）")")
            }
        }
    }

    private func makeSampleBuffer(
        avcc: [UInt8],
        formatDescription: CMFormatDescription,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        guard !avcc.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            scrcpyVideoLog("CMBlockBufferCreateWithMemoryBlock 失败：status=\(blockStatus)")
            return nil
        }
        // memoryBlock 传 nil 时必须先 AssureBlockMemory：块内存是懒分配的，
        // 不先申请就 ReplaceDataBytes 会失败（这一步漏了会静默出不了图）。
        let assureStatus = CMBlockBufferAssureBlockMemory(blockBuffer)
        guard assureStatus == kCMBlockBufferNoErr else {
            scrcpyVideoLog("CMBlockBufferAssureBlockMemory 失败：status=\(assureStatus)")
            return nil
        }
        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: avcc,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: avcc.count)
        guard copyStatus == kCMBlockBufferNoErr else {
            scrcpyVideoLog("CMBlockBufferReplaceDataBytes 失败：status=\(copyStatus)")
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Self.frameTimescale),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr else {
            scrcpyVideoLog("CMSampleBufferCreateReady 失败：status=\(sampleStatus)")
            return nil
        }
        return sampleBuffer
    }

    // MARK: - 尺寸

    private func applySize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lock.lock()
        let changed = width != currentWidth || height != currentHeight
        if changed {
            currentWidth = width
            currentHeight = height
        }
        lock.unlock()
        guard changed else { return }
        scrcpyVideoLog("画面尺寸：\(width)x\(height)")
    }

    // MARK: - 心跳

    /// 每秒一条。口径与 Windows 对齐，方便横向对比（`AGENTS.md` §12.2）：
    /// **`已解出 ≪ 已喂入` 就是"解码器在憋"**（Windows 上实测 8/43 vs 42/43）。
    private func heartbeatIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastHeartbeatAt >= Self.heartbeatInterval else { return }
        lastHeartbeatAt = now

        lock.lock()
        let received = receivedCount
        let dropped = droppedCount
        let depth = pendingDepth
        let width = currentWidth
        let height = currentHeight
        lock.unlock()

        let gapText: String
        if let last = lastDecodeAt {
            gapText = "\(Int((now - last) * 1000))ms"
        } else {
            gapText = "—"
        }
        scrcpyVideoLog(
            "心跳：收到 \(received)，已喂入 \(fedCount)，已解出 \(decodedCount)，丢弃 \(dropped)，"
                + "队列深度 \(depth)，帧间隔 \(gapText)，解码失败 \(decodeErrorCount)，"
                + "格式变化 \(formatChangeCount) 次，尺寸 \(width)x\(height)")

        if let last = lastDecodeAt, now - last >= Self.stallWarningInterval,
           now - lastStallWarningAt >= Self.stallWarningInterval {
            lastStallWarningAt = now
            scrcpyVideoLog(
                "WARNING 距上一帧已 \(Int((now - last) * 1000))ms（阈值 \(Int(Self.stallWarningInterval * 1000))ms）："
                    + "**最常见的原因是设备画面这段时间没有变化**（scrcpy 只在画面变化时发帧，属正常现象）；"
                    + "其次才是编码器重建中 / 流已停。收到 \(received)，已解出 \(decodedCount)")
        }
    }

    // MARK: - Annex-B 工具（纯函数，可离线单测）

    /// 一个 NAL 单元：类型 + 在原始字节里的区间（**不含**起始码）。
    struct NALUnit {
        let type: UInt8
        let range: Range<Int>
    }

    /// 按起始码切出 NAL 单元。
    ///
    /// 顺序**必须先判 4 字节再判 3 字节**：`00 00 00 01` 若先按 3 字节匹配，
    /// 会在偏移 1 处命中 `00 00 01`，于是每个 NAL 都多吃掉一个前导 0 字节——
    /// 切出来的 NAL 首字节错位、类型全错。（可行性文档 §3.1.2 专门提醒过这点。）
    static func splitNALUnits(_ bytes: [UInt8]) -> [NALUnit] {
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }

        var units: [NALUnit] = []
        for (position, start) in starts.enumerated() {
            let nalStart = start.offset + start.length
            let nalEnd = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            guard nalEnd > nalStart else { continue }
            units.append(NALUnit(type: bytes[nalStart] & 0x1F, range: nalStart..<nalEnd))
        }
        return units
    }

    /// Annex-B → AVCC：把每个起始码换成"该 NAL 的 4 字节大端长度"。
    ///
    /// 只动起始码：`00 00 03` 这种 emulation prevention byte **原样保留**，解码器自己会去掉。
    /// 一条消息里的多个 NAL 直接拼成一个字节流放进同一个 sample（不需要一个 NAL 一个 sample）。
    static func annexBToAVCC(_ bytes: [UInt8], units: [NALUnit]) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(bytes.count + units.count * 4)
        for unit in units {
            let length = UInt32(unit.range.count)
            output.append(UInt8((length >> 24) & 0xFF))
            output.append(UInt8((length >> 16) & 0xFF))
            output.append(UInt8((length >> 8) & 0xFF))
            output.append(UInt8(length & 0xFF))
            output.append(contentsOf: bytes[unit.range])
        }
        return output
    }

    /// 把 OSStatus 写成人类习惯的十六进制（`0x00000000` = 成功）。
    private func hexStatus(_ status: OSStatus) -> String {
        let raw = UInt32(bitPattern: status)
        return String(format: "0x%08X", raw)
    }
}
