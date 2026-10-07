#ifndef RUNNER_PRESENT_LATENCY_H_
#define RUNNER_PRESENT_LATENCY_H_

#include <atomic>
#include <chrono>
#include <cstdint>

// "发布 → 引擎来取"的延迟计量器：**两条呈现路（CPU 像素缓冲 / GPU 共享纹理）共用这一份**。
//
// 为什么要它：`光栅回调` 只回答"引擎来取过几次"，**没有时间维度**——引擎按自己的节奏
// （vsync）来取，我们发布得再快也要等到下一个 vsync 才被取走。这一段等待是我们完全
// 控制不了的（AGENTS.md §12.8 的原因 ③），但它是不是瓶颈、换呈现路有没有变好，
// 必须先变成一个能横向对比的毫秒数（同 §12.8 的教训②："高延迟"要拆成
// 吞吐 / 排队 / present 节奏三件事再动手）。
//
// 口径（两条路必须一字不差，否则 A/B 没有意义）：
//   - MarkPublished()：解码线程在"一帧真的发布出去"之后调用，记下序号与时刻；
//   - MarkPickedUp() ：引擎的光栅回调里调用，**只有当前这帧是新发布的**才计一个样本
//     （引擎每个 vsync 都会来取，即使没有新帧；那种"空取"不是这一帧的延迟）；
//   - 样本 = 取走时刻 − 发布时刻（微秒）。
//
// 线程安全：序号/时刻/累计值都是原子（发布在解码线程、取走在光栅线程）；
// `seen_seq_` 也做成原子，这样 Reset() 从任意线程调用都不会有数据竞争。
class PresentLatencyMeter {
 public:
  void MarkPublished() {
    // 先写时刻、再写序号（读者先读序号、后读时刻）：最坏读到"旧序号 + 新时刻"这种
    // 偏大的样本；反过来会读到"新序号 + 旧时刻"，那会把真实延迟算小——宁可偏大。
    publish_at_us_.store(NowUs(), std::memory_order_relaxed);
    publish_seq_.fetch_add(1, std::memory_order_release);
  }

  void MarkPickedUp() {
    const uint64_t seq = publish_seq_.load(std::memory_order_acquire);
    if (seq == 0 || seq == seen_seq_.load(std::memory_order_relaxed)) {
      return;  // 没有新帧：不算样本
    }
    seen_seq_.store(seq, std::memory_order_relaxed);
    const long long published_us = publish_at_us_.load(std::memory_order_relaxed);
    const long long now_us = NowUs();
    const long long delta_us = now_us > published_us ? now_us - published_us : 0;
    samples_.fetch_add(1, std::memory_order_relaxed);
    sum_us_.fetch_add(static_cast<uint64_t>(delta_us), std::memory_order_relaxed);
  }

  // 只在解码器启动/释放、引擎不会来取的时候调用（见类注释）。
  void Reset() {
    publish_seq_.store(0, std::memory_order_release);
    publish_at_us_.store(0, std::memory_order_relaxed);
    seen_seq_.store(0, std::memory_order_relaxed);
    samples_.store(0, std::memory_order_relaxed);
    sum_us_.store(0, std::memory_order_relaxed);
  }

  uint64_t samples() const { return samples_.load(std::memory_order_relaxed); }
  uint64_t sum_us() const { return sum_us_.load(std::memory_order_relaxed); }

 private:
  static long long NowUs() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
  }

  std::atomic<uint64_t> publish_seq_{0};
  std::atomic<long long> publish_at_us_{0};
  std::atomic<uint64_t> seen_seq_{0};
  std::atomic<uint64_t> samples_{0};
  std::atomic<uint64_t> sum_us_{0};
};

#endif  // RUNNER_PRESENT_LATENCY_H_
