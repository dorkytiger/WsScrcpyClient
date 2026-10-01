package com.example.ws_scrcpy_client

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 宿主 Activity：把原生 H.264 解码器挂到 MethodChannel 上。
 *
 * 通道协议（Dart 侧见 lib/feature/stream/data/remote/native_video_decoder.dart；
 * Windows 侧同一份契约见 windows/runner/flutter_window.cpp）：
 * - `create`    → 建解码器与纹理，返回 `{"textureId": Long}`
 * - `pushFrame`（参数为 ByteArray）→ 喂一帧 Annex-B
 * - `release`   → 释放
 * - 反向调用 `onSizeChanged`（`{"width": Int, "height": Int}`）→ 画面真实分辨率变化
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val TAG = "MainActivity"
        const val CHANNEL = "ws_scrcpy/video"
    }

    private var decoder: ScrcpyVideoDecoder? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "create" -> {
                    try {
                        // 同一个引擎同时只保留一个投流画面：重复 create 先释放旧的。
                        decoder?.release()
                        // FlutterRenderer 本身就是 TextureRegistry 的实现。
                        val created = ScrcpyVideoDecoder(flutterEngine.renderer) { width, height ->
                            // 回调来自解码线程，切回主线程再回 Dart。
                            runOnUiThread {
                                channel?.invokeMethod(
                                    "onSizeChanged",
                                    mapOf("width" to width, "height" to height),
                                )
                            }
                        }
                        decoder = created
                        result.success(mapOf("textureId" to created.create()))
                    } catch (error: Exception) {
                        Log.e(TAG, "创建解码器失败", error)
                        result.error(
                            "decoder_create_failed",
                            "创建 H.264 解码器失败：${error.message}",
                            null,
                        )
                    }
                }

                "pushFrame" -> {
                    val active = decoder
                    if (active == null) {
                        result.error("decoder_not_created", "解码器尚未创建", null)
                        return@setMethodCallHandler
                    }
                    val bytes = call.arguments as? ByteArray
                    if (bytes == null) {
                        result.error("invalid_argument", "pushFrame 需要 ByteArray 参数", null)
                        return@setMethodCallHandler
                    }
                    try {
                        active.pushFrame(bytes)
                        result.success(null)
                    } catch (error: Exception) {
                        Log.e(TAG, "喂帧失败", error)
                        result.error("push_frame_failed", "喂帧失败：${error.message}", null)
                    }
                }

                "release" -> {
                    decoder?.release()
                    decoder = null
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        decoder?.release()
        decoder = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }
}
