#ifndef RUNNER_SCRCPY_VIDEO_DECODER_H_
#define RUNNER_SCRCPY_VIDEO_DECODER_H_

#include <flutter/texture_registrar.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

// Windows 端的 scrcpy 视频解码器（M2 路线 A，与 Android 的 ScrcpyVideoDecoder.kt 行为对齐）。
//
// 链路：Annex-B 帧 → Media Foundation H.264 解码器 MFT → NV12 → RGBA →
//       flutter::PixelBufferTexture（CPU 缓冲路线，见 .cpp 里的升级说明）。
//
// 线程模型：
//   - PushFrame 只在调用线程上入队并唤醒解码线程（不阻塞 platform thread）；
//   - 解码 / 色彩转换 / 上屏都在内部专用线程上串行执行；
//   - Release 会 join 该线程并注销纹理，可重复调用。
//
// **尺寸是"拉"出来的，不是"推"给 Dart 的**（这是 0x58CA5 崩溃的修法，见 AGENTS.md §12）：
//   - `CurrentSize()` 任何时候都能调（跨线程安全，内部加锁）；
//   - 通道层在 `create` 与每次 `pushFrame` 的 **回执** 里带上当前尺寸，
//     Dart 侧顺手更新，因此不需要任何"解码线程 → platform thread"的投递。
namespace ws_scrcpy {

/// 解码器当前输出尺寸（未知时为 0x0）。
struct DecoderSize {
  uint32_t width = 0;
  uint32_t height = 0;
};

/// `create` 各阶段的耗时（毫秒，相对模块首次写日志），由通道层测量后传进来，
/// 好让解码线程在启动时把这些阶段一次性写进日志。
///
/// 为什么由通道层测量：这些阶段大部分发生在 platform thread 上（注册纹理 /
/// 注册通道方法），只有解码线程自己知道线程内的 COM/MF 初始化耗时。
struct DecoderStartupTimings {
  long long com_ms = -1;                 // CoInitializeEx(MTA)
  long long mf_ms = -1;                  // MFStartup
  long long create_mft_ms = -1;          // 创建解码器 MFT（含解锁异步 MFT）
  long long configure_ms = -1;           // configure：输入类型 + 首次输出类型协商
  long long register_texture_ms = -1;    // RegisterTexture
  long long register_channel_ms = -1;    // 注册 ws_scrcpy/video 通道方法
};

}  // namespace ws_scrcpy

class ScrcpyVideoDecoder {
 public:
  ScrcpyVideoDecoder(flutter::TextureRegistrar* texture_registrar,
                     ws_scrcpy::DecoderStartupTimings startup);
  ~ScrcpyVideoDecoder();

  ScrcpyVideoDecoder(const ScrcpyVideoDecoder&) = delete;
  ScrcpyVideoDecoder& operator=(const ScrcpyVideoDecoder&) = delete;

  // 注册像素缓冲纹理并启动解码线程；返回纹理 id，失败返回 -1。
  //
  // 失败原因（COM/Media Foundation 起不来、解码器 MFT 建不出来）可以用
  // LastError() 取到可直接展示给用户的中文文案。
  int64_t Start();

  // 喂一帧完整的 Annex-B（`00 00 00 01` 起始码开头，可能含多个 NAL）。
  //
  // 内部会拷贝一份，调用方可以立刻复用入参缓冲；解码跟不上时丢最旧的帧。
  void PushFrame(const uint8_t* data, size_t size);

  // 停止解码线程并注销纹理；可重复调用，也可与 PushFrame 并发。
  void Release();

  // 当前解码输出尺寸；**任何线程**都可以调（内部加锁）。
  //
  // 这就是取代"解码线程 PostPlatformThreadTask 反向通知 Dart"的那个拉取入口：
  // 尺寸变化的中间状态由这里持有，不需要把回调投递到别的线程去。
  ws_scrcpy::DecoderSize CurrentSize() const;

  // 最近一次失败的可读原因（UTF-8）。
  std::string LastError() const;

 private:
  class Impl;

  // 实现类只在 .cpp 里定义；构造/析构都在 .cpp 里定义，
  // 所以这里是"不完整类型的 unique_ptr"，合法且不需要额外的头依赖。
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_SCRCPY_VIDEO_DECODER_H_

