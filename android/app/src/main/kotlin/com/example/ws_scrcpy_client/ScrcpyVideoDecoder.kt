package com.example.ws_scrcpy_client

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * 用 MediaCodec 硬解 scrcpy 下发的裸 H.264（Annex-B），渲染到 Flutter 的 SurfaceTexture。
 *
 * 设计要点（对应 docs/ws-scrcpy-protocol.md §4.4 的实测结论）：
 * - 一条 WebSocket 消息 = 一帧 Annex-B（`00 00 00 01` 起始码），SPS/PPS 单独作为一条消息先到；
 * - 因此 SPS/PPS 那条按 `BUFFER_FLAG_CODEC_CONFIG` 喂进去，其余帧按普通输入喂；
 * - 解码在**独立线程**上跑（MediaCodec 异步模式 + 自己的 HandlerThread），
 *   避免阻塞 Flutter 的 platform thread；
 * - 真实分辨率以解码器回调的 `INFO_OUTPUT_FORMAT_CHANGED` 为准（投流中可能变化），
 *   变化时同步调整 SurfaceProducer 的尺寸并通知 Dart 侧。
 *
 * **2026-10-08：按 AGENTS §1.2 的对照表把这一端补齐到与 Apple / Windows 同级**（见各条注释）：
 * 1. `KEY_LOW_LATENCY`（API 30+）+ `KEY_PRIORITY=0`（realtime）+ `KEY_OPERATING_RATE`
 *    —— 就是 Apple 的 `kVTDecompressionPropertyKey_RealTime` / Windows 的 `MF_LOW_LATENCY`
 *    在这一端的对应物。**必须显式设 1 并把结果写进日志**，否则将来没人能自证它到底设没设上；
 * 2. 队列上限 **60 → 8**（60 帧 ≈ 2 秒，一旦积压就是"延迟滚雪球"，见 §12.8 原因②）；
 * 3. **优先挑硬件解码器**（API 29+ 能拿到 `isHardwareAccelerated`）并把选中的编解码器名写进日志；
 *    拿不到判断依据的旧系统**不猜**，直接回落到 `createDecoderByType`；
 * 4. **新增每秒心跳**（收到 / 已喂入 / 已解出 / 丢弃 / 队列深度 / 帧间隔 + 停摆 WARNING）——
 *    口径与 `windows/runner/scrcpy_video_decoder.cpp`、`darwin/ScrcpyVideoDecoder.swift` 一致，
 *    这样"`已解出 ≪ 已喂入` = 解码器在憋"这条判据在 Android 上同样可用（此前这一端**完全没有**诊断）。
 */
class ScrcpyVideoDecoder(
    private val textureRegistry: TextureRegistry,
    private val onSizeChanged: (width: Int, height: Int) -> Unit,
) {
    companion object {
        private const val TAG = "ScrcpyVideoDecoder"
        private const val MIME_TYPE = "video/avc"

        /** 起始码前的占位尺寸：真实尺寸由 SPS/输出格式回调决定。 */
        private const val INITIAL_WIDTH = 1280
        private const val INITIAL_HEIGHT = 720

        /**
         * 等待解码的最大帧数，超出丢**最旧**的帧。
         *
         * **60 → 8**（2026-10-08）：60 帧在 30fps 下就是约 2 秒的排队延迟，一旦解码跟不上，
         * 延迟会滚雪球（Windows 上为此把上限从 60 降到 4，见 AGENTS §12.8 原因②）。
         * 取 8 而不是 4：Android 这边解码器直写 GPU 纹理（SurfaceProducer），
         * 正常远快于到帧节奏、队列平常就是空的，留一点余量吸收调度抖动。
         *
         * 丢帧的代价要记住：H.264 的 P 帧引用前面的帧，丢中间的帧会让画面花到下一个 IDR 为止
         * —— 所以这个值不能太小，且丢帧必须进心跳（下面的 `丢弃`）。
         */
        private const val MAX_PENDING_FRAMES = 8

        /** 心跳间隔（与另外两端一致：每秒一条）。 */
        private const val HEARTBEAT_INTERVAL_MS = 1000L

        /** 距上一帧超过这么久就发一条 WARNING（阈值与 Apple/Windows 对齐）。 */
        private const val STALL_WARNING_MS = 5000L

    /// "喂了却一帧都没解出来"多久之后开始报警（见 [logHeartbeat]）。
    private const val NO_OUTPUT_WARNING_MS = 3000L
    }

    private var producer: TextureRegistry.SurfaceProducer? = null
    private var surface: Surface? = null
    private var codec: MediaCodec? = null
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null

    /** 等待喂给解码器的帧；解码器输入缓冲可用但没数据时会短暂排队。 */
    private val pendingFrames = ConcurrentLinkedQueue<Frame>()

    /** 已拿到但还没数据可填的输入缓冲下标（-1 表示没有）。 */
    private var pendingInputIndex = -1

    /** 解码器是否已释放，防止 release 之后还有回调进来。 */
    private val released = AtomicBoolean(false)

    private var currentWidth = 0
    private var currentHeight = 0

    /** 选中的编解码器名（日志与心跳用；拿不到时是空串）。 */
    private var codecName = ""
    private var codecIsHardware = false

    /** 低延迟开关的落地情况（一次性写进日志与心跳，见类注释第 1 条）。 */
    private var lowLatencyText = "未设置"

    // ---------------------------------------------------------------- 诊断计数
    //
    // 口径与 Windows / Apple 两端**逐字对齐**（收到 / 已喂入 / 已解出 / 丢弃），
    // 这样三端的日志可以横向比。计数在 platform thread 与解码线程上都会写，所以全用原子量。
    private val receivedCount = AtomicInteger()
    private val fedCount = AtomicInteger()
    private val decodedCount = AtomicInteger()
    private val droppedCount = AtomicInteger()
    private val decodeErrorCount = AtomicInteger()

    /// 收到的**空载荷**条数（scrcpy 在编码器刚重启时会发几条 0 字节的"帧"；
    /// 它们不是样本，不喂进解码器，但要单独数出来——见 [pushFrame] 的注释）。
    private val emptyFrameCount = AtomicInteger()

    /// 第一帧真正喂进解码器的时刻（用来判"喂了却一帧都没解出来"，0 = 还没喂过）。
    private var firstFedAtMs = 0L

    /// 上次报"喂了却一帧都没解出来"的时刻（避免每秒刷屏）。
    private var lastNoOutputWarningAtMs = 0L

    /**
     * 真实分辨率与初始尺寸不一致的次数（心跳里能看到）。
     *
     * **不再换 Surface** —— 换 Surface 会让引擎剪掉旧的 reader，而编解码器还往里写，
     * 结果是"解码每秒 28 帧、画面永久冻住"，详见 [applySize] 的注释。
     */
    private val sizeChangeWithoutSwapCount = AtomicInteger()
    private var lastDecodedAtMs = 0L
    private var lastHeartbeatAtMs = 0L
    private var lastStallWarningAtMs = 0L

    private data class Frame(val bytes: ByteArray, val isCodecConfig: Boolean)

    /** 返回给 Dart 侧的纹理 id。 */
    fun create(): Long {
        val surfaceProducer = textureRegistry.createSurfaceProducer()
        producer = surfaceProducer

        // ★ 顺序很重要：**先 setSize、再 getSurface()**。
        //
        // 引擎的语义（反汇编 `FlutterRenderer$ImageReaderSurfaceProducer` 确认，2026-10-08）：
        //   setSize(w,h) —— 与 requested 不同就 `createNewReader = true`（下次 getSurface() 建**新** reader）
        //   getSurface() —— 返回当前 reader 的 Surface
        // 反过来写（先取 Surface 再 setSize）时，引擎会在**之后某个时刻**才换 reader，
        // 而旧 Surface 已经交给编解码器了 —— 那就是 [applySize] 里记的那个"画面冻结"缺陷。
        surfaceProducer.setSize(INITIAL_WIDTH, INITIAL_HEIGHT)
        val initialSurface = surfaceProducer.surface
        surface = initialSurface

        val thread = HandlerThread("ws-scrcpy-video").also { it.start() }
        handlerThread = thread
        val codecHandler = Handler(thread.looper)
        handler = codecHandler

        startCodec(initialSurface)

        // 初始尺寸在这里定死：**不要再走 applySize**（那条路会 setSize + 换 Surface，
        // 而此刻解码器刚按同一块 Surface 配好）。真实尺寸由 onOutputFormatChanged 触发 applySize。
        currentWidth = INITIAL_WIDTH
        currentHeight = INITIAL_HEIGHT
        onSizeChanged(INITIAL_WIDTH, INITIAL_HEIGHT)
        codecHandler.postDelayed(heartbeatRunnable, HEARTBEAT_INTERVAL_MS)
        return surfaceProducer.id()
    }

    /** 建解码器并把它绑到 [outputSurface]（只在 `create()` 里调用一次，见 [applySize] 的注释）。 */
    private fun startCodec(outputSurface: Surface) {
        val codecHandler = handler ?: return

        val format = MediaFormat.createVideoFormat(MIME_TYPE, INITIAL_WIDTH, INITIAL_HEIGHT)
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
        )
        // 允许投流过程中分辨率变化（scrcpy 会随设备旋转/设置调整）。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            format.setInteger(MediaFormat.KEY_MAX_WIDTH, INITIAL_WIDTH * 4)
            format.setInteger(MediaFormat.KEY_MAX_HEIGHT, INITIAL_HEIGHT * 4)
        }
        applyLowLatencyKeys(format)

        val mediaCodec = createCodec()
        mediaCodec.setCallback(
            object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                    onInputAvailable(codec, index)
                }

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo,
                ) {
                    if (released.get()) return
                    try {
                        // render = true：渲染到 `create()` 里定下来的那块 Surface。
                        // **不要**在这里或别处换 Surface（会让引擎剪掉旧 reader、画面永久冻结，
                        // 见 applySize 的注释）。
                        codec.releaseOutputBuffer(index, true)
                        decodedCount.incrementAndGet()
                        lastDecodedAtMs = SystemClock.elapsedRealtime()
                    } catch (error: IllegalStateException) {
                        decodeErrorCount.incrementAndGet()
                        Log.w(TAG, "释放输出缓冲失败", error)
                    }
                }

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                    if (released.get()) return
                    applySize(
                        format.getInteger(MediaFormat.KEY_WIDTH),
                        format.getInteger(MediaFormat.KEY_HEIGHT),
                    )
                }

                override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
                    decodeErrorCount.incrementAndGet()
                    Log.e(TAG, "解码器错误：${error.diagnosticInfo}", error)
                }
            },
            codecHandler,
        )
        mediaCodec.configure(format, outputSurface, null, 0)
        mediaCodec.start()
        codec = mediaCodec
        pendingInputIndex = -1

        // 解码器自己报告的输入格式（真实生效值的唯一自证材料，见 AGENTS §1.2 的"日志里能自证"）。
        Log.i(TAG, "解码器已启动：$codecName" +
            "（硬解=${if (codecIsHardware) "是" else "否/未知"}），低延迟 $lowLatencyText；" +
            "解码器报的输入格式=$format")
    }

    /**
     * 低延迟相关的三个键（类注释第 1 条）。
     *
     * - `KEY_PRIORITY = 0`：实时优先级（0 = realtime），与 `KEY_OPERATING_RATE` 是
     *   Android 官方给"低延迟/实时"场景的组合（AOSP 与 ExoPlayer 都这么设）；
     * - `KEY_OPERATING_RATE = Short.MAX_VALUE`：告诉编解码器"按最高吞吐跑"，别为省电降频；
     * - `KEY_LOW_LATENCY = 1`（**API 30+**）：等同于 Apple 的 `RealTime` / Windows 的
     *   `MF_LOW_LATENCY`；旧系统没有这个键，**不设**（不猜）。
     *
     * 设完把"设了什么"记进 [lowLatencyText]，心跳与启动日志都会带出去 —— 将来"画面慢"时
     * 第一件事就是看它到底设没设上（Apple 那端为此专门记 `设置结果=0x00000000`）。
     */
    private fun applyLowLatencyKeys(format: MediaFormat) {
        val applied = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
            applied += "KEY_PRIORITY=0"
            applied += "KEY_OPERATING_RATE=${Short.MAX_VALUE.toInt()}"
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            applied += "KEY_LOW_LATENCY=1"
        }
        lowLatencyText = if (applied.isEmpty()) {
            "未设置（API ${Build.VERSION.SDK_INT} 没有这些键）"
        } else {
            applied.joinToString("，")
        }
    }

    /**
     * 建解码器：**优先挑硬件解码器**（类注释第 3 条）。
     *
     * 为什么值得挑：`createDecoderByType` 交给平台按注册顺序选，实测有些机型会先给软件解码器
     * （Apple/Windows 两端都因此专门确认过"到底走的硬解还是软解"）。API 29+ 能拿到
     * `isHardwareAccelerated`，就按它挑；**拿不到判断依据的旧系统不猜**，直接用平台默认。
     * 挑中的名字进日志与心跳，出问题时一眼能看出走的是哪条路。
     */
    private fun createCodec(): MediaCodec {
        val hardware = findHardwareDecoder()
        if (hardware != null) {
            try {
                val created = MediaCodec.createByCodecName(hardware.name)
                codecName = hardware.name
                codecIsHardware = true
                return created
            } catch (error: Exception) {
                Log.w(TAG, "按名字创建硬解失败（${hardware.name}），回落到 createDecoderByType", error)
            }
        }
        val fallback = MediaCodec.createDecoderByType(MIME_TYPE)
        codecName = runCatching { fallback.name }.getOrDefault("")
        codecIsHardware = runCatching {
            val info = MediaCodecList(MediaCodecList.REGULAR_CODECS)
                .codecInfos.firstOrNull { it.name == codecName }
            info != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                info.isHardwareAccelerated
        }.getOrDefault(false)
        return fallback
    }

    /** 找一个硬件 H.264 解码器；拿不到判断依据或没找到都返回 null（回落平台默认）。 */
    private fun findHardwareDecoder(): MediaCodecInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // API 29 以下没有 isHardwareAccelerated：按名字猜会猜错，宁可不挑。
            return null
        }
        return try {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
                !info.isEncoder &&
                    info.supportedTypes.any { it.equals(MIME_TYPE, ignoreCase = true) } &&
                    info.isHardwareAccelerated
            }
        } catch (error: Exception) {
            Log.w(TAG, "枚举解码器失败，回落到 createDecoderByType", error)
            null
        }
    }

    /** 喂一帧原始字节；[bytes] 是一条完整的 Annex-B 帧（可能含多 NAL）。 */
    fun pushFrame(bytes: ByteArray) {
        if (released.get()) return
        // ★ 空载荷**不是样本**，喂进去只会让"收到/已喂入"虚高。
        //   2026-10-08 真机（Android 16，第一次进投流页必黑）实测：服务端在编码器刚重启时
        //   会发若干条 **0 字节**的"帧"，我们照单全喂 → 心跳
        //   `收到 10，已喂入 10，**已解出 0**，丢弃 0，尺寸变化 0 次`，屏幕整屏 4 秒 0 变化。
        //   这类帧没有任何 NAL，解不出东西也上报不了尺寸，必须单独计数、不进解码队列。
        if (bytes.isEmpty()) {
            emptyFrameCount.incrementAndGet()
            return
        }
        receivedCount.incrementAndGet()
        val frame = Frame(bytes, isCodecConfigOnly(bytes))
        val codecRef = codec ?: return
        synchronized(this) {
            if (pendingInputIndex >= 0) {
                val index = pendingInputIndex
                pendingInputIndex = -1
                feedInput(codecRef, index, frame)
                return
            }
        }
        // 解码跟不上时丢掉**最旧**的帧：内存不会无界增长，延迟有界；
        // 丢帧后靠下一个关键帧重新同步（编码侧 iFrameInterval 会定期给关键帧）。
        while (pendingFrames.size >= MAX_PENDING_FRAMES) {
            pendingFrames.poll()
            droppedCount.incrementAndGet()
        }
        pendingFrames.add(frame)
    }

    /** 停止解码并释放纹理；可重复调用。 */
    fun release() {
        if (!released.compareAndSet(false, true)) return
        handler?.removeCallbacks(heartbeatRunnable)
        pendingFrames.clear()
        Log.i(TAG, "释放：收到 ${receivedCount.get()}，已喂入 ${fedCount.get()}，" +
            "已解出 ${decodedCount.get()}，丢弃 ${droppedCount.get()}")
        try {
            codec?.stop()
        } catch (error: IllegalStateException) {
            Log.w(TAG, "停止解码器失败", error)
        }
        try {
            codec?.release()
        } catch (error: IllegalStateException) {
            Log.w(TAG, "释放解码器失败", error)
        }
        codec = null
        surface?.release()
        surface = null
        producer?.release()
        producer = null
        handlerThread?.quitSafely()
        handlerThread = null
        handler = null
    }

    // ---------------------------------------------------------------- 内部实现

    private fun onInputAvailable(codecRef: MediaCodec, index: Int) {
        if (released.get()) return
        val frame = pendingFrames.poll()
        if (frame == null) {
            synchronized(this) { pendingInputIndex = index }
            return
        }
        feedInput(codecRef, index, frame)
    }

    private fun feedInput(codecRef: MediaCodec, index: Int, frame: Frame) {
        try {
            val buffer: ByteBuffer = codecRef.getInputBuffer(index) ?: return
            buffer.clear()
            buffer.put(frame.bytes)
            codecRef.queueInputBuffer(
                index,
                0,
                frame.bytes.size,
                System.nanoTime() / 1000,
                if (frame.isCodecConfig) MediaCodec.BUFFER_FLAG_CODEC_CONFIG else 0,
            )
            fedCount.incrementAndGet()
            if (firstFedAtMs == 0L) {
                firstFedAtMs = SystemClock.elapsedRealtime()
            }
        } catch (error: IllegalStateException) {
            droppedCount.incrementAndGet()
            Log.w(TAG, "喂帧失败（已丢弃一帧）", error)
        }
    }

    /**
     * 画面尺寸变化 —— **这里以前会把画面弄死，改动前请先读完这段**（2026-10-08 真机定位）。
     *
     * **症状**：投流跑一会儿（几十秒到几分钟）后，画面冻在某一帧；解码计数依旧每秒 28 帧、
     * `丢弃 0`、`队列 0`，Flutter 自己的 UI（面板/按钮）照样能重绘 —— 也就是说
     * **"取到帧"和"上屏"彻底脱钩**，而所有计数器都是绿的。用户看到的是"点哪都不动、
     * 延迟越拖越大，最后完全卡死"。
     *
     * **根因在引擎的状态机里**（反汇编 `FlutterRenderer$ImageReaderSurfaceProducer` 逐条确认）：
     * - `SurfaceProducer.setSize()` 不是"改缓冲大小"，而是**下次 `getSurface()` 换一块新的
     *   ImageReader/Surface**（尺寸一变就 `createNewReader = true`）；
     * - 只要出现了第二块 reader，旧的那块就**不再是 active**；
     * - 旧 reader 的图片队列一空，`canPrune()` 就成立 → 引擎把它 `close()`（`closed = true`，不可逆）；
     * - 而**编解码器还在往旧 Surface 里写** → 之后每帧都走
     *   `queueImage()` 里那句 `if (closed) return null;` → `onImage()` 拿到 null 就**直接 return，
     *   不再调用 `scheduleEngineFrame()`** → **引擎再也不会因为"有新帧"而重绘** → 画面永久冻住。
     *
     * 真机上还试过 `MediaCodec.setOutputSurface(新 Surface)`（更"正统"的换 Surface 办法）：
     * 调用成功、日志也打了，但画面依旧冻着 —— 说明这颗 c2.qti 解码器并没有真的把输出切过去。
     * 因此这一端**唯一可靠的做法就是：只在建解码器之前定一次尺寸，之后永不换 Surface**。
     *
     * 代价（已知、可接受）：真实分辨率与初始尺寸不一致时，由编解码器把画面缩放进这块缓冲，
     * 引擎按图片的 crop rect 取样，几何仍由 Dart 侧（`onSizeChanged`）决定；换设备方向导致
     * 分辨率大幅变化时画面会有缩放/letterbox，但**不会冻屏**。要彻底支持那种情况，
     * 正确做法是**重建整个 SurfaceProducer 并换纹理 id**（见 AGENTS §11 的后续项），
     * 而不是在这里 `setSize`。
     */
    private fun applySize(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        if (width == currentWidth && height == currentHeight) return
        currentWidth = width
        currentHeight = height
        sizeChangeWithoutSwapCount.incrementAndGet()
        Log.i(TAG, "画面尺寸：${width}x$height（**不换 Surface**：换了会让引擎剪掉旧的、" +
            "编解码器继续写死 Surface，画面永久冻结，详见 applySize 注释）")
        onSizeChanged(width, height)
    }

    // ---------------------------------------------------------------- 心跳

    /**
     * 每秒一条（类注释第 4 条）。**在解码线程上跑**，与两外两端同一口径：
     *
     * - `帧间隔`：两次解出之间的间隔，**由服务端给帧的节奏决定**（30fps 就是 ~33ms）；
     * - `已解出 ≪ 已喂入` = **解码器在憋**（Windows 上实测不设低延迟开关是 8/43、设了 42/43）；
     * - `丢弃 > 0` = 推得比解的快（上限见 [MAX_PENDING_FRAMES]）；
     * - `队列深度` 长期 >0 说明解码跟不上，延迟会随之变大。
     */
    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            if (released.get()) return
            logHeartbeat()
            handler?.postDelayed(this, HEARTBEAT_INTERVAL_MS)
        }
    }

    private fun logHeartbeat() {
        val now = SystemClock.elapsedRealtime()
        lastHeartbeatAtMs = now
        val gap = if (lastDecodedAtMs == 0L) "—" else "${now - lastDecodedAtMs}ms"
        val emptyFrames = emptyFrameCount.get()
        Log.i(TAG, "心跳：收到 ${receivedCount.get()}，已喂入 ${fedCount.get()}，" +
            "已解出 ${decodedCount.get()}，丢弃 ${droppedCount.get()}，" +
            "队列深度 ${pendingFrames.size}，帧间隔 $gap，" +
            "解码失败 ${decodeErrorCount.get()}，" +
            (if (emptyFrames > 0) "空载荷 $emptyFrames（不是样本，未喂），" else "") +
            "尺寸 ${currentWidth}x$currentHeight，" +
            "尺寸变化 ${sizeChangeWithoutSwapCount.get()} 次（不换 Surface），" +
            "解码器 $codecName（硬解=${if (codecIsHardware) "是" else "否/未知"}），低延迟 $lowLatencyText")

        // ★ "喂了却一帧都没解出来" 必须自己喊出来 —— 这正是"没拿到 SPS/PPS + IDR"的签名，
        //   而它的表现是**日志全绿 + 屏幕全黑**（2026-10-08 真机：第一次进投流页 100% 复现，
        //   `收到 10 / 已喂入 10 / 已解出 0 / 尺寸变化 0 次`，整屏 4 秒 0 像素变化）。
        //   真实尺寸只在解出第一帧之后才上报，所以"尺寸变化 0 次"是同一个证据。
        if (decodedCount.get() == 0 && firstFedAtMs != 0L &&
            now - firstFedAtMs >= NO_OUTPUT_WARNING_MS &&
            now - lastNoOutputWarningAtMs >= NO_OUTPUT_WARNING_MS
        ) {
            lastNoOutputWarningAtMs = now
            Log.w(TAG, "WARNING 已喂入 ${fedCount.get()} 帧但**一帧都没解出来**" +
                "（已等 ${now - firstFedAtMs}ms，空载荷 $emptyFrames 条）：" +
                "大概率是**解码器没拿到 SPS/PPS + IDR**（参数集/首个关键帧在建解码器之前就过去了）" +
                "——画面会一直全黑且不报错，客户端会靠\"补喂订阅前的帧\"自愈（见 PlayerViewModel）。")
        }

        if (lastDecodedAtMs != 0L && now - lastDecodedAtMs >= STALL_WARNING_MS &&
            now - lastStallWarningAtMs >= STALL_WARNING_MS
        ) {
            lastStallWarningAtMs = now
            Log.w(TAG, "WARNING 距上一帧已 ${now - lastDecodedAtMs}ms（阈值 ${STALL_WARNING_MS}ms）：" +
                "**最常见的原因是设备画面这段时间没有变化**（scrcpy 只在画面变化时发帧，属正常现象）；" +
                "其次才是编码器重建中 / 流已停。收到 ${receivedCount.get()}，已解出 ${decodedCount.get()}")
        }
    }

    /**
     * 该帧是否只含 SPS/PPS 等非 VCL NAL —— 是的话按 codec-config 喂。
     *
     * NAL 类型在起始码后第一个字节的低 5 位：1=非 IDR 片、5=IDR 片，其余多是参数集/SEI。
     */
    private fun isCodecConfigOnly(bytes: ByteArray): Boolean {
        var index = 0
        while (index + 4 < bytes.size) {
            if (bytes[index] == 0.toByte() &&
                bytes[index + 1] == 0.toByte() &&
                bytes[index + 2] == 0.toByte() &&
                bytes[index + 3] == 1.toByte()
            ) {
                val nalType = bytes[index + 4].toInt() and 0x1F
                if (nalType == 1 || nalType == 5) return false
                index += 4
                continue
            }
            index++
        }
        return true
    }
}
