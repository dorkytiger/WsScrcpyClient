#ifndef RUNNER_SCRCPY_PIXEL_STORE_H_
#define RUNNER_SCRCPY_PIXEL_STORE_H_

#include <flutter/texture_registrar.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include "present_latency.h"

// 交给 Flutter 引擎读取的像素缓冲（CPU 路线，`flutter::PixelBufferTexture`）。
//
// 为什么单独抽成一个编译单元（不再藏在 scrcpy_video_decoder.cpp 的匿名命名空间里）：
// 它是"解码线程 ↔ raster 线程"唯一共享可变状态的地方，也是第一版首跑崩溃的同族风险点
// （引擎读缓冲 vs 我们释放缓冲）。抽成一个**不依赖 Media Foundation** 的小类之后，
// `tools/pixel_store_test.cpp` 就能在本机用真假难辨的时序（发布→取走→释放→尺寸变化→
// Clear）直接压它，并用 AddressSanitizer 证明没有 use-after-free，**不需要真实设备**。
//
// 四条来自 Flutter 引擎实现的硬约束（都逐行核对过
// shell/platform/windows/external_texture_pixelbuffer.cc）：
// 1) 回调返回 nullptr 是安全的（引擎有判空，直接跳过这一帧）；
// 2) 返回的 `FlutterDesktopPixelBuffer.width/height` 才是纹理尺寸（引擎用它覆盖自己那份）；
// 3) 引擎按 `GL_RGBA` + `GL_UNSIGNED_BYTE` 上传，且没有设 GL_UNPACK_ROW_LENGTH，
//    所以行跨距**必须**等于 width*4（紧凑排布）；
// 4) `release_callback` 在 `TexImage2D` 之后、同一个调用里立刻触发。
//
// 第 4 条正是这里做所有权移交的理由：引擎读缓冲发生在**我们释放锁之后**，
// 所以不能把裸指针交出去（注销回调里的 Clear() 会在另一个线程把它销毁 → use-after-free）。
// 改成每帧发一张 Grant：它用 shared_ptr 把那一帧钉住，并把 release_callback 指成
// "删除自己"，于是内存一定活到引擎读完为止，也不再需要 retired_ 这类手工记账。
class PixelBufferStore {
 public:
  PixelBufferStore() = default;

  // 解码线程：把刚换算好的整帧换进来（与 copy 缓冲交换，O(1)）。
  void PublishDecoded(std::vector<uint8_t>* scratch);

  // 解码线程：按新尺寸换一张缓冲；返回整帧字节数。
  size_t Resize(uint32_t width, uint32_t height, std::vector<uint8_t>* scratch);

  // raster 线程（引擎回调）：把最新一帧连同所有权一起交给引擎。
  const FlutterDesktopPixelBuffer* CopyLatest();

  // 纹理注销完成后才会走到这里；因为 Grant 各自持有引用，这里可以放心释放。
  void Clear();

  // 当前纹理尺寸（0 表示还没有缓冲）。
  uint32_t width() const;
  uint32_t height() const;

  // 是否已经有过一帧真正发布进 latest_（供日志判断"有没有画面"）。
  bool has_published() const;

  // 引擎（光栅线程）来取缓冲的次数。
  //
  // 为什么单独计数：它和"解码线程发布了多少帧"是**两个不同的节奏**。
  // 心跳里对比这两个数就能一刀切开"是我们（解码/换算）慢"还是"引擎侧（上传/合成）慢"：
  //   - 发布数 ≈ 光栅回调数 → 我们的节奏就是瓶颈；
  //   - 发布数 ≫ 光栅回调数 → 引擎根本没按我们的节奏来取，瓶颈在引擎侧的上传/合成
  //     （第 4 方证据见 AGENTS.md §12.8；这也是 Windows 从 CPU 像素路换到 GPU 共享纹理路的依据）。
  uint64_t raster_callbacks() const;

  // "发布 → 引擎取走"的延迟样本数与累计微秒数（口径见 present_latency.h；
  // 与 GPU 路的 D3d11VideoPresenter 用的是同一份实现，所以两条路可以直接对比）。
  uint64_t present_latency_samples() const;
  uint64_t present_latency_sum_us() const;

 private:
  struct Frame {
    std::vector<uint8_t> pixels;
    uint32_t width = 0;
    uint32_t height = 0;
  };

  // 一次"交给引擎读"的授权：descriptor 与 frame 同生共死。
  struct Grant {
    std::shared_ptr<Frame> frame;
    FlutterDesktopPixelBuffer descriptor{};
  };

  mutable std::mutex mutex_;
  std::shared_ptr<Frame> current_;  // 引擎最近拿到的那张
  std::vector<uint8_t> latest_;     // 解码线程刚产出的整帧
  bool dirty_ = false;              // latest_ 是否比 current_ 新
  bool published_ = false;          // 是否至少发布过一帧
  std::atomic<uint64_t> raster_callbacks_{0};  // 引擎来取缓冲的次数
  // "发布 → 引擎取走"的延迟（两条呈现路共用同一份实现，见 present_latency.h）。
  PresentLatencyMeter latency_;
};

#endif  // RUNNER_SCRCPY_PIXEL_STORE_H_
