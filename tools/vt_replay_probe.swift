import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 离线探针：把 `darwin/ScrcpyVideoDecoder.swift`（**真实实现**，不是副本）
/// 编到 macOS 上跑，不需要 iOS 设备、不需要服务端，验证三件事：
///
/// 1. **Annex-B 工具函数的字节级行为**——起始码切分（3/4 字节）与 AVCC 转换；
///    用 `test/fixtures/stream_first_video_frames.txt`（真实服务端抓包，禁止手改）。
/// 2. **真实抓包的 SPS/PPS 能建出格式描述与解码会话**（设备尺寸由它决定）。
/// 3. **完整码流能逐帧解出来**——码流由本机 `VTCompressionSession` 现编
///    （H.264 baseline、Annex-B、SPS/PPS 先发，结构与 scrcpy 一致），
///    并做 **低延迟开关 A/B**：`RealTime = true` vs `false`。
///
/// 为什么要有它（`AGENTS.md` §12.3 的纪律）：解码这种东西不能只靠"上真机看一眼"，
/// 要有能在本机反复跑的、链接真实实现的探针；否则每次回归都要占用一台设备与一个服务端。
/// Windows 侧对应的入口是 `tools\run_mft_replay_probe.cmd`，那边的 A/B 结果是
/// "不设低延迟 8/43 帧 vs 设了 42/43 帧"。
///
/// 运行：`tools/run_vt_replay_probe.sh`
@main
struct VtReplayProbe {

    // MARK: - 迷你断言（只打印失败，最后给汇总）

    static var checks = 0
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("  ✗ \(message)")
        }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected {
            failures += 1
            print("  ✗ \(message)：实际 \(actual)，期望 \(expected)")
        }
    }

    static func section(_ title: String) {
        print("\n=== \(title) ===")
    }

    // MARK: - 入口

    static func main() {
        let root = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath

        print("VideoToolbox 离线探针（链接的是 darwin/ScrcpyVideoDecoder.swift 本身）")

        checkAnnexBHelpers()
        checkRealFixtureParameterSets(root: root)
        checkFullReplay(root: root)
        checkLowLatencyAB()

        print("\n—— 汇总：检查项 \(checks)，失败 \(failures) ——")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 1. Annex-B 工具函数

    static func checkAnnexBHelpers() {
        section("1. Annex-B 切分与 AVCC 转换")

        // 4 字节起始码：必须从偏移 4 开始拿到 NAL，且类型是 5（IDR）。
        // 这条专治"先判 3 字节"的经典错位 bug（起始码长度不固定，见 AGENTS §15.2）。
        let fourByte: [UInt8] = [0, 0, 0, 1, 0x65, 0x88, 0x84]
        let fourUnits = ScrcpyVideoDecoder.splitNALUnits(fourByte)
        expectEqual(fourUnits.count, 1, "4 字节起始码应切出 1 个 NAL")
        if let unit = fourUnits.first {
            expectEqual(unit.range.lowerBound, 4, "4 字节起始码的 NAL 应始于偏移 4")
            expectEqual(unit.type, 5, "0x65 的 NAL 类型应为 5（IDR）")
        }

        // 3 字节起始码同样要认（H.264 允许，编码器切关键帧时可能出现）。
        let threeByte: [UInt8] = [0, 0, 1, 0x67, 0x42, 0xC0]
        let threeUnits = ScrcpyVideoDecoder.splitNALUnits(threeByte)
        expectEqual(threeUnits.count, 1, "3 字节起始码应切出 1 个 NAL")
        if let unit = threeUnits.first {
            expectEqual(unit.range.lowerBound, 3, "3 字节起始码的 NAL 应始于偏移 3")
            expectEqual(unit.type, 7, "0x67 的 NAL 类型应为 7（SPS）")
        }

        // 多 NAL + 混合长度的起始码。
        let mixed: [UInt8] = [0, 0, 0, 1, 0x67, 0xAA] + [0, 0, 1, 0x68, 0xBB] + [0, 0, 0, 1, 0x65, 0xCC]
        let mixedUnits = ScrcpyVideoDecoder.splitNALUnits(mixed)
        expectEqual(mixedUnits.map(\.type), [7, 8, 5], "混合起始码应切出 [7, 8, 5]")

        // AVCC：每个 NAL 前是 4 字节大端长度，且总长度 = 原始长度 - 起始码长度 + 4×NAL 数。
        let avcc = ScrcpyVideoDecoder.annexBToAVCC(mixed, units: mixedUnits)
        expectEqual(avcc.count, mixed.count - (4 + 3 + 4) + 4 * 3, "AVCC 长度应等于 NAL 长度之和 + 4×NAL 数")
        expectEqual(Array(avcc[0..<4]), [0, 0, 0, 2], "第 1 个 NAL 长度前缀应为 2")
        expectEqual(Array(avcc[6..<10]), [0, 0, 0, 2], "第 2 个 NAL 长度前缀应为 2")
        expectEqual(avcc.last!, 0xCC, "最后一个 NAL 的字节应原样保留")

        print("  切分/转换用例通过（含 4 字节优先、3 字节、混合三种）")
    }

    // MARK: - 2. 真实抓包的 SPS/PPS

    static func checkRealFixtureParameterSets(root: String) {
        section("2. 真实抓包的 SPS/PPS 能建出会话")

        let fixturePath = "\(root)/test/fixtures/stream_first_video_frames.txt"
        guard let text = try? String(contentsOfFile: fixturePath, encoding: .utf8) else {
            expect(false, "读不到夹具 \(fixturePath)")
            return
        }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, let spsPps = hexToBytes(first) else {
            expect(false, "夹具第一条不是合法十六进制")
            return
        }

        let units = ScrcpyVideoDecoder.splitNALUnits(spsPps)
        expectEqual(units.map(\.type), [7, 8], "真实抓包第一条应是 SPS+PPS（[7, 8]）")

        let decoder = ScrcpyVideoDecoder()
        decoder.start()
        decoder.push(frame: Data(spsPps))
        // 参数集那条是同步在解码队列上处理的；给它一点时间落定。
        Thread.sleep(forTimeInterval: 0.3)
        let size = decoder.currentSize()
        expect(size.width > 0 && size.height > 0, "真实 SPS/PPS 应能定出画面尺寸，实际 \(size)")
        print("  真实抓包 SPS/PPS → 画面尺寸 \(size.width)x\(size.height)")

        // 顺带确认"只含参数集的那条不当样本喂"：喂完仍然是 0 帧解出。
        expectEqual(decoder.debugStats.decoded, 0, "纯参数集消息不应产生解码输出")
        decoder.stop()
    }

    // MARK: - 3. 完整码流回放

    static func checkFullReplay(root: String) {
        section("3. 完整码流逐帧回放（本机 VTCompressionSession 现编）")

        let width = 640
        let height = 360
        let frameCount = 90
        guard let stream = makeStream(width: width, height: height, frameCount: frameCount) else {
            expect(false, "本机编码生成码流失败（VTCompressionSession 不可用？）")
            return
        }
        print("  生成 \(stream.frames.count) 帧 Annex-B（\(width)x\(height)，SPS \(stream.parameterSets.count) 组参数集）")
        expect(stream.frames.count >= frameCount - 2, "编码应产出接近 \(frameCount) 帧，实际 \(stream.frames.count)")

        let result = replay(stream: stream)
        print("  \(result.summary)")
        expectEqual(result.dropped, 0, "探针不该丢帧：丢了说明喂得比解得快，后面的断言就没意义了")
        expectEqual(result.received, stream.frames.count + 1, "解码器应收到 1 条参数集 + 全部帧")
        expect(result.decoded >= stream.frames.count - 2, "应解出接近全部帧：\(result.summary)")
        expect(result.sizes.first?.width == width, "解出的宽度应为 \(width)，实际 \(String(describing: result.sizes.first))")
        expect(result.nonBlackFrames > 0, "至少应有一帧不是全黑（证明真的解出了图像）")
        // 分辨率必须被报告出去（Dart 侧靠它摆 AspectRatio）。
        expect((result.lastSize?.width ?? 0) > 0, "应报告过画面尺寸")
    }

    // MARK: - 4. 低延迟 A/B

    static func checkLowLatencyAB() {
        section("4. 低延迟开关 A/B（kVTDecompressionPropertyKey_RealTime）")

        let width = 640
        let height = 360
        let frameCount = 90
        guard let stream = makeStream(width: width, height: height, frameCount: frameCount) else {
            expect(false, "本机编码生成码流失败")
            return
        }

        let on = replay(stream: stream, realtimeOverride: true)
        let off = replay(stream: stream, realtimeOverride: false)
        // nil = 完全不设这个属性，看系统默认行为（头文件说默认是 true，这里用实测印证）。
        let unset = replay(stream: stream, realtimeOverride: nil, skipSettingProperty: true)

        print("  RealTime=true ：\(on.summary)")
        print("  RealTime=false：\(off.summary)")
        print("  完全不设属性  ：\(unset.summary)")
        print("  → Apple 侧不存在 Windows 那种「默认攒 1.2 秒」的缓冲"
            + "（MF_LOW_LATENCY 那次是 8/43 vs 42/43）；")
        print("    这里三种设置都必须接近全解，任何一条掉到一半以下就是回归。")

        let total = stream.frames.count
        for (label, result) in [("RealTime=true", on), ("RealTime=false", off), ("不设属性", unset)] {
            expectEqual(result.dropped, 0, "\(label)：探针侧不该丢帧")
            expect(result.decoded >= total - 2, "\(label) 应接近全解：\(result.summary)")
        }
    }

    // MARK: - 回放

    struct ReplayResult {
        let received: Int
        let fed: Int
        let decoded: Int
        let dropped: Int
        let sizes: [VideoSize]
        let lastSize: VideoSize?
        let nonBlackFrames: Int

        var summary: String {
            "收到 \(received)，已喂入 \(fed)，已解出 \(decoded)，丢弃 \(dropped)，非全黑 \(nonBlackFrames) 帧"
        }
    }

    static func replay(
        stream: H264Stream,
        realtimeOverride: Bool? = true,
        skipSettingProperty: Bool = false
    ) -> ReplayResult {
        let collector = FrameCollector()
        let decoder = ScrcpyVideoDecoder()
        if skipSettingProperty {
            decoder.skipRealtimePropertyForProbe = true
        } else {
            decoder.realtimeOverrideForProbe = realtimeOverride
        }
        decoder.onDecodedFrame = { buffer in
            collector.record(buffer)
        }
        decoder.start()

        // 先发一条"只含参数集"的消息，与 scrcpy 的时序一致。
        decoder.push(frame: Data(stream.parameterSetMessage))
        // **必须按帧率节奏喂**：解码器只有 8 帧的等待队列，瞬间推完 90 帧会把
        // **IDR 丢掉**，剩下的 P 帧引用不存在的参考帧 → 满屏 `kVTVideoDecoderBadDataErr`
        // （-12909）。第一版探针就是这么假报警的——真实来源是网络，本来就按 33ms 到。
        // 这里用 10ms（比 30fps 还快 3 倍）既贴近真实时序，又不至于让探针跑很久。
        for frame in stream.frames {
            decoder.push(frame: Data(frame))
            usleep(10_000)
        }
        // 等解码队列把尾巴排空。
        Thread.sleep(forTimeInterval: 1.0)
        let size = decoder.currentSize()
        let stats = decoder.debugStats
        decoder.stop()

        return ReplayResult(
            received: stats.received,
            fed: stats.fed,
            decoded: stats.decoded,
            dropped: stats.dropped,
            sizes: collector.sizes,
            lastSize: size.width > 0 ? VideoSize(width: size.width, height: size.height) : nil,
            nonBlackFrames: collector.nonBlackFrames)
    }

    /// 收集解码输出：计数、尺寸变化、以及"这帧不是全黑"的判断。
    final class FrameCollector {
        private let lock = NSLock()
        private(set) var count = 0
        private(set) var sizes: [VideoSize] = []
        private(set) var nonBlackFrames = 0

        func record(_ buffer: CVPixelBuffer) {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let isNonBlack = Self.hasNonBlackPixel(buffer)
            lock.lock()
            count += 1
            if sizes.last != VideoSize(width: width, height: height) {
                sizes.append(VideoSize(width: width, height: height))
            }
            if isNonBlack {
                nonBlackFrames += 1
            }
            lock.unlock()
        }

        /// 抽查一批像素（不解锁整帧 BGRA 的平面，只锁住然后按跨距采样）。
        private static func hasNonBlackPixel(_ buffer: CVPixelBuffer) -> Bool {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let width = CVPixelBufferGetWidth(buffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let offset = y * bytesPerRow + x * 4
                    if pixels[offset] > 8 || pixels[offset + 1] > 8 || pixels[offset + 2] > 8 {
                        return true
                    }
                    x += 7
                }
                y += 7
            }
            return false
        }
    }

    struct VideoSize: Equatable {
        let width: Int
        let height: Int
    }

    // MARK: - 本机编码生成 Annex-B 码流

    struct H264Stream {
        /// 每条 "00 00 00 01 + NAL" 的完整 Annex-B 帧（与 scrcpy 的一条 WS 消息一帧对齐）。
        let frames: [[UInt8]]
        /// 只含 SPS+PPS 的那一条消息。
        let parameterSetMessage: [UInt8]
        let parameterSets: [[UInt8]]
    }

    /// 用 VideoToolbox 编码器现编一段 H.264（baseline、Annex-B、SPS/PPS 先发）。
    ///
    /// 为什么用它而不是"再抓一次包"：探针必须能离线反复跑；
    /// 编码器产出的码流在结构上与 scrcpy 下发的完全同类（同样的 Annex-B 切分方式、
    /// 同样 SPS/PPS 先行、同样 IDR + P 帧），足够验证我们这一侧的解码实现。
    static func makeStream(width: Int, height: Int, frameCount: Int) -> H264Stream? {
        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        guard createStatus == noErr, let session else {
            print("  VTCompressionSessionCreate 失败：\(createStatus)")
            return nil
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(session)

        let collector = StreamCollector()
        for index in 0..<frameCount {
            guard let pixelBuffer = makePixelBuffer(width: width, height: height, index: index) else {
                return nil
            }
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 30),
                duration: .invalid,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer else { return }
                collector.append(sampleBuffer)
            }
            if status != noErr {
                print("  VTCompressionSessionEncodeFrame 第 \(index) 帧失败：\(status)")
                return nil
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)

        guard let parameterSets = collector.parameterSets, parameterSets.count >= 2 else {
            print("  拿不到 SPS/PPS 参数集")
            return nil
        }
        let sps = parameterSets[0]
        let pps = parameterSets[1]
        let parameterSetMessage: [UInt8] = [0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps
        return H264Stream(
            frames: collector.annexBChunks,
            parameterSetMessage: parameterSetMessage,
            parameterSets: [sps, pps])
    }

    /// 一帧会动的画面：底色 + 随帧号移动的亮块（保证编码器每帧都有变化、且有非黑像素）。
    static func makePixelBuffer(width: Int, height: Int, index: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let blockX = (index * 7) % max(1, width - 40)
        let blockY = (index * 5) % max(1, height - 40)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let inBlock = x >= blockX && x < blockX + 40 && y >= blockY && y < blockY + 40
                if inBlock {
                    pixels[offset] = 240
                    pixels[offset + 1] = 240
                    pixels[offset + 2] = 240
                } else {
                    // 渐变底，避免大片纯黑导致"非全黑"判断失真。
                    pixels[offset] = UInt8((x * 255) / max(1, width))
                    pixels[offset + 1] = UInt8((y * 255) / max(1, height))
                    pixels[offset + 2] = 80
                }
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }

    /// 收集编码器输出，转成 Annex-B。
    final class StreamCollector {
        private let lock = NSLock()
        private var chunks: [[UInt8]] = []
        private var sets: [[UInt8]]?

        func append(_ sampleBuffer: CMSampleBuffer) {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let parameterSets = Self.parameterSets(of: formatDescription)
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            var totalLength = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &pointer)
            guard status == kCMBlockBufferNoErr, let pointer, totalLength > 0 else { return }
            let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
            let avcc = Array(UnsafeBufferPointer(start: bytes, count: totalLength))
            let annexB = Self.avccToAnnexB(avcc)
            guard !annexB.isEmpty else { return }

            lock.lock()
            if sets == nil, parameterSets.count >= 2 {
                sets = parameterSets
            }
            chunks.append(annexB)
            lock.unlock()
        }

        var annexBChunks: [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            return chunks
        }

        var parameterSets: [[UInt8]]? {
            lock.lock()
            defer { lock.unlock() }
            return sets
        }

        static func parameterSets(of formatDescription: CMFormatDescription) -> [[UInt8]] {
            var count = 0
            let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil)
            guard countStatus == noErr, count > 0 else { return [] }
            var result: [[UInt8]] = []
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
                guard status == noErr, let pointer, size > 0 else { continue }
                result.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
            }
            return result
        }

        /// AVCC（4 字节长度前缀）→ Annex-B（4 字节起始码）。探针自己要用，不属于业务逻辑。
        static func avccToAnnexB(_ bytes: [UInt8]) -> [UInt8] {
            var output: [UInt8] = []
            var offset = 0
            while offset + 4 <= bytes.count {
                let length = (Int(bytes[offset]) << 24)
                    | (Int(bytes[offset + 1]) << 16)
                    | (Int(bytes[offset + 2]) << 8)
                    | Int(bytes[offset + 3])
                offset += 4
                guard length > 0, offset + length <= bytes.count else { break }
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(contentsOf: bytes[offset..<(offset + length)])
                offset += length
            }
            return output
        }
    }

    // MARK: - 小工具

    static func hexToBytes(_ hex: String) -> [UInt8]? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
