package com.example.ws_scrcpy_client

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

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
 */
class ScrcpyVideoDecoder(
    private val textureRegistry: TextureRegistry,
    private val onSizeChanged: (width: Int, height: Int) -> Unit,
) {
    companion object {
        private const val TAG = "ScrcpyVideoDecoder"
        private const val MIME_TYPE = "video/avc"
        private const val DEQUEUE_TIMEOUT_US = 10_000L

        /** 起始码前的占位尺寸：真实尺寸由 SPS/输出格式回调决定。 */
        private const val INITIAL_WIDTH = 1280
        private const val INITIAL_HEIGHT = 720

        /** 等待解码的最大帧数（约 2 秒 @30fps），超出丢最旧的帧。 */
        private const val MAX_PENDING_FRAMES = 60
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

    private data class Frame(val bytes: ByteArray, val isCodecConfig: Boolean)

    /** 返回给 Dart 侧的纹理 id。 */
    fun create(): Long {
        val surfaceProducer = textureRegistry.createSurfaceProducer()
        producer = surfaceProducer
        surface = surfaceProducer.surface

        val thread = HandlerThread("ws-scrcpy-video").also { it.start() }
        handlerThread = thread
        val codecHandler = Handler(thread.looper)
        handler = codecHandler

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

        val mediaCodec = MediaCodec.createDecoderByType(MIME_TYPE)
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
                        // render = true：直接渲染到 SurfaceTexture。
                        codec.releaseOutputBuffer(index, true)
                    } catch (error: IllegalStateException) {
                        Log.w(TAG, "释放输出缓冲失败", error)
                    }
                }

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                    if (released.get()) return
                    val width = format.getInteger(MediaFormat.KEY_WIDTH)
                    val height = format.getInteger(MediaFormat.KEY_HEIGHT)
                    applySize(width, height)
                }

                override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
                    Log.e(TAG, "解码器错误：${error.diagnosticInfo}", error)
                }
            },
            codecHandler,
        )
        mediaCodec.configure(format, surface, null, 0)
        mediaCodec.start()
        codec = mediaCodec

        // SurfaceProducer 在尺寸未知时是 1x1，先按初始尺寸给个可用值。
        applySize(INITIAL_WIDTH, INITIAL_HEIGHT)
        return surfaceProducer.id()
    }

    /** 喂一帧原始字节；[bytes] 是一条完整的 Annex-B 帧（可能含多 NAL）。 */
    fun pushFrame(bytes: ByteArray) {
        if (released.get()) return
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
        // 解码跟不上时丢掉最旧的帧，避免内存无界增长；
        // 丢帧后靠下一个关键帧重新同步（编码侧 iFrameInterval 会定期给关键帧）。
        while (pendingFrames.size >= MAX_PENDING_FRAMES) {
            pendingFrames.poll()
        }
        pendingFrames.add(frame)
    }

    /** 停止解码并释放纹理；可重复调用。 */
    fun release() {
        if (!released.compareAndSet(false, true)) return
        pendingFrames.clear()
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
        } catch (error: IllegalStateException) {
            Log.w(TAG, "喂帧失败（已丢弃一帧）", error)
        }
    }

    private fun applySize(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        if (width == currentWidth && height == currentHeight) return
        currentWidth = width
        currentHeight = height
        producer?.setSize(width, height)
        Log.i(TAG, "画面尺寸：${width}x$height")
        onSizeChanged(width, height)
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
