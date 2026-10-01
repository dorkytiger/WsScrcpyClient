// 本机可跑的换算自测：证明 NV12/I420/YV12 → RGBA 不越界，并且**能挡住**
// 实机首跑崩溃的那类输入（源缓冲比按 height/2 估算的要短）。
//
// 为什么这是最强证据：真机崩溃给不出码流，但越界这件事与 Media Foundation 无关，
// 只取决于"指针 + 跨距 + 宽高 + 缓冲长度"。这里用带 padding 的 pitch、奇数宽高、
// 1x1、半个 UV 平面、以及 0xAA 金丝雀字节把这件事钉死；再用
// AddressSanitizer（若可用）复跑一遍。
//
// 编译与运行：tools\run_yuv_test.cmd

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>

#include "yuv_to_rgba.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool condition, const char* what) {
  ++g_checks;
  if (!condition) {
    ++g_failures;
    std::printf("  [FAIL] %s\n", what);
  }
}

constexpr size_t kCanaryBytes = 32;
constexpr uint8_t kCanary = 0xAA;

/// 带金丝雀的缓冲：前 kCanaryBytes 与后 kCanaryBytes 都是哨兵字节。
class GuardedBuffer {
 public:
  explicit GuardedBuffer(size_t payload_bytes, uint8_t fill = 0)
      : storage_(payload_bytes + kCanaryBytes * 2, kCanary) {
    std::memset(storage_.data() + kCanaryBytes, fill, payload_bytes);
    payload_bytes_ = payload_bytes;
  }

  uint8_t* data() { return storage_.data() + kCanaryBytes; }
  size_t size() const { return payload_bytes_; }

  bool CanariesIntact() const {
    for (size_t index = 0; index < kCanaryBytes; ++index) {
      if (storage_[index] != kCanary) {
        return false;
      }
      if (storage_[storage_.size() - 1 - index] != kCanary) {
        return false;
      }
    }
    return true;
  }

 private:
  std::vector<uint8_t> storage_;
  size_t payload_bytes_ = 0;
};

/// 按"解码器实际会给出的长度"算：这正是崩溃现场的估算方式
/// （整数除法把奇数高度的最后一行 UV 截掉了）。
size_t NaivePitchTimesOneAndHalf(size_t pitch, size_t height) {
  return pitch * height * 3 / 2;
}

void TestPaddedPitchSucceeds() {
  std::printf("1) 带 padding 的 pitch（width=6, pitch=16, NV12）\n");
  const uint32_t width = 6;
  const uint32_t height = 4;
  const size_t pitch = 16;
  GuardedBuffer source(pitch * height + pitch * ((height + 1) / 2), 0x80);
  GuardedBuffer dest(static_cast<size_t>(width) * height * 4);

  const bool ok = ws_scrcpy::ConvertYuv420ToRgba(
      source.data(), source.size(), ws_scrcpy::Yuv420Layout::kNv12, pitch,
      width, height, false, dest.data(), dest.size());
  Check(ok, "padded pitch 应该换算成功");
  Check(source.CanariesIntact(), "源缓冲金丝雀必须完好（没有越界读）");
  Check(dest.CanariesIntact(), "目标缓冲金丝雀必须完好（没有越界写）");
}

void TestOddHeightShortBufferIsRejected() {
  std::printf("2) 奇数高度 + 缓冲只有 1.5*height*pitch（实机崩溃现场的估算）\n");
  const uint32_t width = 16;
  const uint32_t height = 5;  // 奇数：UV 需要 3 行，不是 2 行
  const size_t pitch = 16;
  const size_t short_bytes = NaivePitchTimesOneAndHalf(pitch, height);
  GuardedBuffer source(short_bytes, 0x80);
  GuardedBuffer dest(static_cast<size_t>(width) * height * 4);

  const ws_scrcpy::Yuv420SourceInfo info = ws_scrcpy::ValidateYuv420Source(
      ws_scrcpy::Yuv420Layout::kNv12, pitch, width, height, short_bytes);
  Check(!info.ok, "缓冲不足时必须判定为不可用");
  Check(std::strcmp(info.reason, "source buffer too small") == 0,
        "失败原因应为 source buffer too small");

  const bool ok = ws_scrcpy::ConvertYuv420ToRgba(
      source.data(), short_bytes, ws_scrcpy::Yuv420Layout::kNv12, pitch, width,
      height, false, dest.data(), dest.size());
  Check(!ok, "缓冲不足时必须拒绝换算（绝不能硬写）");
  Check(source.CanariesIntact(), "被拒绝时源缓冲金丝雀必须完好");
  Check(dest.CanariesIntact(), "被拒绝时目标缓冲金丝雀必须完好");
}

void TestSmallSizes() {
  std::printf("3) 极小尺寸：1x1、2x1、1x2\n");
  const uint32_t sizes[][2] = {{1, 1}, {2, 1}, {1, 2}, {3, 3}};
  for (const auto& size : sizes) {
    const uint32_t width = size[0];
    const uint32_t height = size[1];
    const size_t pitch = 2 * ((static_cast<size_t>(width) + 1) / 2);  // NV12 最小 pitch
    if (pitch < width) {
      continue;
    }
    const size_t needed = pitch * height + pitch * ((height + 1) / 2);
    GuardedBuffer source(needed, 0x80);
    GuardedBuffer dest(static_cast<size_t>(width) * height * 4);
    const bool ok = ws_scrcpy::ConvertYuv420ToRgba(
        source.data(), source.size(), ws_scrcpy::Yuv420Layout::kNv12, pitch,
        width, height, false, dest.data(), dest.size());
    Check(ok, "极小尺寸应该换算成功");
    Check(source.CanariesIntact(), "极小尺寸：源金丝雀完好");
    Check(dest.CanariesIntact(), "极小尺寸：目标金丝雀完好");
  }
}

void TestHalfUvPlaneIsRejected() {
  std::printf("4) 只给半个 UV 平面\n");
  const uint32_t width = 32;
  const uint32_t height = 8;
  const size_t pitch = 32;
  const size_t y_bytes = pitch * height;
  GuardedBuffer source(y_bytes + pitch * ((height + 1) / 2) / 2, 0x80);
  GuardedBuffer dest(static_cast<size_t>(width) * height * 4);
  const bool ok = ws_scrcpy::ConvertYuv420ToRgba(
      source.data(), source.size(), ws_scrcpy::Yuv420Layout::kNv12, pitch,
      width, height, false, dest.data(), dest.size());
  Check(!ok, "UV 平面不足时必须拒绝");
  Check(source.CanariesIntact(), "UV 不足：源金丝雀完好");
  Check(dest.CanariesIntact(), "UV 不足：目标金丝雀完好");
}

void TestDestinationCapacity() {
  std::printf("5) 目标容量差一个字节\n");
  const uint32_t width = 8;
  const uint32_t height = 4;
  const size_t pitch = 8;
  GuardedBuffer source(pitch * height + pitch * ((height + 1) / 2), 0x80);
  const size_t target_bytes = static_cast<size_t>(width) * height * 4;
  GuardedBuffer dest(target_bytes);

  const bool ok = ws_scrcpy::ConvertYuv420ToRgba(
      source.data(), source.size(), ws_scrcpy::Yuv420Layout::kNv12, pitch,
      width, height, false, dest.data(), target_bytes - 1);
  Check(!ok, "目标容量不足必须拒绝");
  Check(dest.CanariesIntact(), "目标容量不足时不得写入任何字节");
}

void TestPlanarLayouts() {
  std::printf("6) I420 / YV12（含奇数 pitch 必须拒绝）\n");
  const uint32_t width = 6;
  const uint32_t height = 4;
  const size_t pitch = 16;
  const size_t chroma_rows = (height + 1) / 2;
  const size_t needed = pitch * height + (pitch / 2) * chroma_rows * 2;

  for (const auto layout :
       {ws_scrcpy::Yuv420Layout::kI420, ws_scrcpy::Yuv420Layout::kYv12}) {
    GuardedBuffer source(needed, 0x80);
    GuardedBuffer dest(static_cast<size_t>(width) * height * 4);
    Check(ws_scrcpy::ConvertYuv420ToRgba(source.data(), source.size(), layout,
                                         pitch, width, height, false,
                                         dest.data(), dest.size()),
          "平面布局应该换算成功");
    Check(source.CanariesIntact(), "平面布局：源金丝雀完好");
    Check(dest.CanariesIntact(), "平面布局：目标金丝雀完好");
  }

  GuardedBuffer odd_source(needed + pitch, 0x80);
  GuardedBuffer odd_dest(static_cast<size_t>(width) * height * 4);
  Check(!ws_scrcpy::ConvertYuv420ToRgba(
            odd_source.data(), odd_source.size(),
            ws_scrcpy::Yuv420Layout::kI420, 15, width, height, false,
            odd_dest.data(), odd_dest.size()),
        "平面布局遇到奇数 pitch 必须拒绝");
  Check(odd_dest.CanariesIntact(), "奇数 pitch：目标金丝雀完好");
}

void TestBottomUp() {
  std::printf("7) 自下而上（负 stride 的等价情形）\n");
  const uint32_t width = 8;
  const uint32_t height = 4;
  const size_t pitch = 8;
  GuardedBuffer source(pitch * height + pitch * ((height + 1) / 2), 0x80);
  GuardedBuffer dest(static_cast<size_t>(width) * height * 4);
  Check(ws_scrcpy::ConvertYuv420ToRgba(source.data(), source.size(),
                                       ws_scrcpy::Yuv420Layout::kNv12, pitch,
                                       width, height, true, dest.data(),
                                       dest.size()),
        "自下而上应该换算成功");
  Check(source.CanariesIntact(), "自下而上：源金丝雀完好");
  Check(dest.CanariesIntact(), "自下而上：目标金丝雀完好");
}

void TestFuzz() {
  std::printf("8) 随机宽高/pitch（源缓冲按正确需求给足）\n");
  std::mt19937 generator(20261001);
  std::uniform_int_distribution<uint32_t> width_dist(1, 200);
  std::uniform_int_distribution<uint32_t> height_dist(1, 120);
  std::uniform_int_distribution<uint32_t> pad_dist(0, 64);

  int executed = 0;
  for (int iteration = 0; iteration < 400; ++iteration) {
    const uint32_t width = width_dist(generator);
    const uint32_t height = height_dist(generator);
    for (const auto layout :
         {ws_scrcpy::Yuv420Layout::kNv12, ws_scrcpy::Yuv420Layout::kI420,
          ws_scrcpy::Yuv420Layout::kYv12}) {
      for (const bool bottom_up : {false, true}) {
        const size_t base_pitch = width + pad_dist(generator);
        size_t pitch = std::max<size_t>(base_pitch, width);
        if (layout == ws_scrcpy::Yuv420Layout::kNv12) {
          // NV12 的交错 UV 需要放得下 ceil(width/2) 对，即偶数 pitch >= width。
          pitch = std::max<size_t>(pitch, (static_cast<size_t>(width) + 1) / 2 * 2);
        } else if (pitch % 2 != 0) {
          ++pitch;  // 平面布局的色度跨距是 pitch/2，必须偶数
        }
        // 这里只是"问需求大小"，所以给一个足够大的长度，让它不要因为长度被拒。
        const ws_scrcpy::Yuv420SourceInfo info = ws_scrcpy::ValidateYuv420Source(
            layout, pitch, width, height, static_cast<size_t>(-1));
        if (!info.ok) {
          continue;  // 该组合本身不合法（例如 pitch 连宽度都放不下）
        }
        GuardedBuffer source(info.required_bytes, 0x80);
        const size_t target_bytes = static_cast<size_t>(width) * height * 4;
        GuardedBuffer dest(target_bytes);
        const bool ok = ws_scrcpy::ConvertYuv420ToRgba(
            source.data(), source.size(), layout, pitch, width, height,
            bottom_up, dest.data(), dest.size());
        Check(ok, "随机组合应该换算成功");
        Check(source.CanariesIntact(), "随机组合：源金丝雀完好");
        Check(dest.CanariesIntact(), "随机组合：目标金丝雀完好");
        // 目标必须被完整写满（不能留黑洞）。
        bool filled = true;
        for (size_t index = 3; index < target_bytes; index += 4) {
          if (dest.data()[index] != 255) {
            filled = false;
            break;
          }
        }
        Check(filled, "随机组合：RGBA 的 alpha 必须整帧写满");
        ++executed;
      }
    }
  }
  std::printf("   实际执行组合数：%d\n", executed);
  // 空跑的测试等于没有测试，这里把它变成硬失败（第一版就因为传了 data_bytes=0
  // 让校验函数一直返回"缓冲不足"，400 轮循环一个组合都没跑到）。
  Check(executed > 1000, "fuzz 必须真的跑到足够多的组合");
}

}  // namespace

// ---------------------------------------------------------------------------
// 根因正向证明（只在 ASan 构建下跑，见 tools/run_yuv_test.cmd）
//
// 这段代码是**实机首跑崩溃的那段旧实现的复刻**（原文件
// windows/runner/scrcpy_video_decoder.cpp 的 ConvertAndPublish + 换算循环）：
// 旧实现用 `pitch * height * 3 / 2` 判断源缓冲够不够，奇数高度时整数除法把
// UV 的最后一行截掉了，于是最后一行的 UV 读越界。debug 下表现为 0xC0000005，
// release 下被 CRT 变成 fastfail。
//
// 预期结果：ASan 报 heap-buffer-overflow。这不是"失败的测试"，而是证据。
int ReproduceOldOutOfBoundsRead() {
  const uint32_t width = 1920;
  const uint32_t height = 853;  // 用户实机日志里的窗口高度（奇数）
  const size_t pitch = 1920;
  const size_t naive_bytes = pitch * height * 3 / 2;  // 旧实现的判断依据
  const size_t chroma_rows = (static_cast<size_t>(height) + 1) / 2;
  const size_t available_chroma_rows = (naive_bytes - pitch * height) / pitch;

  std::printf("复刻旧实现：%ux%u pitch=%zu\n", width, height, pitch);
  std::printf("  旧判据给的源缓冲 %zu 字节 → UV 只有 %zu 行\n", naive_bytes,
              available_chroma_rows);
  std::printf("  真实需要 UV %zu 行（奇数高度要向上取整）\n", chroma_rows);

  std::vector<uint8_t> source(naive_bytes, 0x80);
  std::vector<uint8_t> dest(static_cast<size_t>(width) * height * 4, 0);
  const uint8_t* u_plane = source.data() + pitch * height;
  const uint8_t* v_plane = u_plane + 1;

  for (uint32_t row = 0; row < height; ++row) {
    const uint8_t* u_line = u_plane + static_cast<size_t>(row / 2) * pitch;
    const uint8_t* v_line = v_plane + static_cast<size_t>(row / 2) * pitch;
    uint8_t* out = dest.data() + static_cast<size_t>(row) * width * 4;
    for (uint32_t column = 0; column < width; ++column) {
      // 旧实现在这里读 u_line[column / 2] / v_line[column / 2]：
      // 高度为奇数时最后一行的这两次读已经越过缓冲末尾。
      const uint8_t u = u_line[(column / 2) * 2];
      const uint8_t v = v_line[(column / 2) * 2];
      out[0] = u;
      out[1] = v;
      out[2] = 0;
      out[3] = 255;
    }
  }
  std::printf("  没有崩：ASan 没抓到越界（说明复刻得不准确）\n");
  return 0;
}

/// 解码器协商输出类型时用的"需要多大输出缓冲"的算法（等价于
/// `scrcpy_video_decoder.cpp` 里的 `WsRequiredOutputBytes`：拿纯函数的 required_bytes，
/// 再和 MFT 的 cbSize 取大者；这里 cbSize 传 0 等价于只看布局需求）。
///
/// 为什么要在这里测：以前解码器自己手写 `stride * height * 3 / 2`，那是**偶数高度的
/// 巧合值**，奇数高度会少算半行（853 就是奇数）——同一族错误在换算侧崩过一次
/// （见 AGENTS §12.6 / §12.3）。现在两处共用这一个纯函数，就必须把它的结果钉住。
size_t OutputBufferBytesFor(ws_scrcpy::Yuv420Layout layout, size_t stride,
                            uint32_t width, uint32_t height) {
  return ws_scrcpy::ValidateYuv420Source(layout, stride, width, height,
                                         static_cast<size_t>(-1))
      .required_bytes;
}

/// 输出缓冲容量必须按 ceil(height/2) 算，且"刚好够"要被接受、"少一个字节"要被拒绝。
void TestOutputBufferSizing() {
  std::printf("输出缓冲容量（协商输出类型用）\n");

  // 偶数高度：与朴素公式一致，方便对照。
  Check(OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 1280, 1280, 720) ==
            1280u * 720 * 3 / 2,
        "NV12 1280x720 stride=1280：容量等于 3/2 帧");
  // 奇数高度：真实需求必须比朴素公式**多**（多出来的正是最后那半行 UV）。
  const size_t odd_nv12 =
      OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 1920, 1898, 853);
  const size_t naive_nv12 = 1920u * 853 * 3 / 2;
  Check(odd_nv12 == 1920u * 853 + 1920u * 427,
        "NV12 1898x853 stride=1920：容量 = Y(pitch*h) + UV(pitch*ceil(h/2))");
  Check(odd_nv12 > naive_nv12,
        "NV12 奇数高度 853：真实需求比 stride*h*3/2 更大（朴素公式会少算半行）");

  // 平面布局（I420/YV12）：两个色度平面各 pitch/2 * ceil(h/2)。
  Check(OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kI420, 1920, 1898, 853) ==
            1920u * 853 + (1920u / 2) * 427 * 2,
        "I420 1898x853 stride=1920：容量含两个色度平面");
  Check(OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kYv12, 992, 992, 560) ==
            992u * 560 + (992u / 2) * 280 * 2,
        "YV12 992x560 stride=992：容量含两个色度平面");

  // 宽高互换（设备旋转）：不能复用旧值，必须按新宽高重算。
  const size_t landscape =
      OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 1280, 1280, 720);
  const size_t portrait =
      OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 1280, 720, 1280);
  Check(landscape != portrait, "宽高互换后容量必须变化（旋转后要重建输出样本）");

  // 1x1 与最小奇数：不能算出 0，也不能少算。
  //
  // 注意 NV12 的色度是**交错对**，所以 pitch 必须 >= ceil(width/2)*2：
  // 宽度为 1 时一行 UV 也要 2 字节。这不是限制不合理，而是"必须拒绝"的约束
  // （解码器不会给出这种 pitch，但纯函数必须挡住它，否则按 width 索引就会越界）。
  Check(OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 2, 1, 1) ==
            2u * 1 + 2u * 1,
        "NV12 1x1 stride=2：容量 = 2 + 2（ceil(1/2)=1 行 UV）");
  Check(OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 1, 1, 1) == 0,
        "NV12 1x1 stride=1：拒绝（交错色度一行就要 2 字节）");
  Check(OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 4, 3, 3) ==
            4u * 3 + 4u * 2,
        "NV12 3x3 stride=4：容量 = 12 + 8（ceil(3/2)=2 行 UV）");
  Check(OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 3, 3, 3) == 0,
        "NV12 3x3 stride=3：拒绝（pitch 装不下一行交错色度）");

  // 关键行为："刚好够"要接受、"少一个字节"要拒绝——这条保证我们不会像
  // 0x80004005 那次一样把太小的缓冲交给解码器。
  const size_t required =
      OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 16, 6, 5);
  Check(required == 16u * 5 + 16u * 3, "NV12 6x5 stride=16：容量按 pitch 对齐算");
  Check(ws_scrcpy::ValidateYuv420Source(ws_scrcpy::Yuv420Layout::kNv12, 16, 6, 5,
                                        required)
            .ok,
        "容量刚好等于需求：接受");
  Check(!ws_scrcpy::ValidateYuv420Source(ws_scrcpy::Yuv420Layout::kNv12, 16, 6, 5,
                                         required - 1)
             .ok,
        "容量比需求少 1 字节：拒绝（不许硬写）");

  // 非法输入必须返回 0（调用方据此跳过这个候选类型），而不是一个"看起来能用"的值。
  Check(OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 0, 6, 5) == 0,
        "跨距为 0：需求为 0（跳过该类型）");
  Check(OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kNv12, 16, 0, 5) == 0,
        "宽度为 0：需求为 0");
  Check(OutputBufferBytesFor(ws_scrcpy::Yuv420Layout::kI420, 15, 14, 8) == 0,
        "平面布局遇到奇数 pitch：需求为 0（纯函数拒绝，调用方走保守兜底）");
}

int main(int argc, char** argv) {
  if (argc > 1 && std::strcmp(argv[1], "--reproduce-old-bug") == 0) {
    return ReproduceOldOutOfBoundsRead();
  }

  std::printf("NV12/I420/YV12 -> RGBA 边界自测\n\n");
  TestPaddedPitchSucceeds();
  TestOddHeightShortBufferIsRejected();
  TestSmallSizes();
  TestHalfUvPlaneIsRejected();
  TestDestinationCapacity();
  TestPlanarLayouts();
  TestBottomUp();
  TestFuzz();
  TestOutputBufferSizing();

  std::printf("\n检查项 %d，失败 %d\n", g_checks, g_failures);
  if (g_failures != 0) {
    std::printf("结果：FAIL\n");
    return 1;
  }
  std::printf("结果：PASS\n");
  return 0;
}
