// 诊断工具：量 NV12→RGBA 的换算耗时，回答"实机上很卡到底是不是纯 CPU 换算拖的"。
//
// 与旧版的区别（旧版有 bug，**不要**回退）：
//  1) 旧版把换算逻辑**照抄**了一份，于是它跑的是"没有边界校验的老逻辑"，而它自己按
//     `w*h*3/2` 申请缓冲——奇数高度时这个整数除法会少算一行 UV，1898x853 直接读越界，
//     进程以 0xC0000005 退出，且 printf 的块缓冲把已算出的结果一起丢了（表现为"没有输出"）。
//     现在改为**直接链接** `windows/runner/yuv_to_rgba.cpp` 的真实实现：它自带校验，
//     缓冲不够只会返回 false，不会再崩。
//  2) 缓冲按 `pitch * (height + 1) / 2` 的色度行数申请，奇数高度也放得下。
//  3) 每行都 `fflush`，即使后面崩了也留得下已经测到的数据。
//  4) 额外量一次"整帧 memcpy"——那是 raster 回调里为了交缓冲给引擎而做的一次拷贝，
//     用来判断"去掉这次拷贝"值不值得。
//
// 编译与运行：`tools\run_nv12_bench.cmd`（/Od 与 /O2 各一遍）。

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "../windows/runner/yuv_to_rgba.h"

namespace {

double NowMs() {
  static LARGE_INTEGER frequency = [] {
    LARGE_INTEGER value = {};
    ::QueryPerformanceFrequency(&value);
    return value;
  }();
  LARGE_INTEGER counter = {};
  ::QueryPerformanceCounter(&counter);
  return static_cast<double>(counter.QuadPart) * 1000.0 /
         static_cast<double>(frequency.QuadPart);
}

/// NV12 源缓冲：Y 平面按 pitch 排布，色度平面按 ceil(height/2) 行（奇数高度也够）。
std::vector<uint8_t> MakeNv12(uint32_t width, uint32_t height, size_t pitch,
                              size_t* chroma_offset) {
  const size_t chroma_rows = (static_cast<size_t>(height) + 1) / 2;
  const size_t y_bytes = pitch * height;
  std::vector<uint8_t> buffer(y_bytes + pitch * chroma_rows, 128);
  for (uint32_t row = 0; row < height; ++row) {
    for (uint32_t column = 0; column < width; ++column) {
      buffer[static_cast<size_t>(row) * pitch + column] =
          static_cast<uint8_t>((row * 3 + column) & 0xFF);
    }
  }
  *chroma_offset = y_bytes;
  return buffer;
}

void Bench(uint32_t width, uint32_t height, int frames) {
  // pitch 取 16 对齐，贴近解码器真实给的对齐跨距（故意**不**等于宽度）。
  const size_t pitch = ((static_cast<size_t>(width) + 15) / 16) * 16;
  size_t chroma_offset = 0;
  std::vector<uint8_t> nv12 = MakeNv12(width, height, pitch, &chroma_offset);
  std::vector<uint8_t> rgba(static_cast<size_t>(width) * height * 4, 0);

  // 先校验一次：真实实现必须接受这块源（不接受就是本基准的缓冲算错了）。
  const ws_scrcpy::Yuv420SourceInfo info = ws_scrcpy::ValidateYuv420Source(
      ws_scrcpy::Yuv420Layout::kNv12, pitch, width, height, nv12.size());
  if (!info.ok) {
    std::printf("%4ux%-5u [基准自身错误] 源校验失败：%s（需要 %zu 字节，实给 %zu）\n",
                width, height, info.reason, info.required_bytes, nv12.size());
    std::fflush(stdout);
    return;
  }

  const bool first = ws_scrcpy::ConvertYuv420ToRgba(
      nv12.data(), nv12.size(), ws_scrcpy::Yuv420Layout::kNv12, pitch, width,
      height, false, rgba.data(), rgba.size());
  if (!first) {
    std::printf("%4ux%-5u [基准自身错误] 首次换算被拒绝\n", width, height);
    std::fflush(stdout);
    return;
  }

  const double start = NowMs();
  for (int index = 0; index < frames; ++index) {
    ws_scrcpy::ConvertYuv420ToRgba(nv12.data(), nv12.size(),
                                   ws_scrcpy::Yuv420Layout::kNv12, pitch,
                                   width, height, false, rgba.data(),
                                   rgba.size());
  }
  const double per_frame = (NowMs() - start) / frames;

  // 整帧 memcpy：raster 回调里"把最新一帧拷进交给引擎的缓冲"的那次拷贝。
  //
  // 注意源缓冲必须和目的**一样大**：旧版这里写的是 `memcpy(rgba.data(),
  // nv12.data(), rgba.size())`，而 NV12 只有 RGBA 的 3/8 大 → 每次多读 2 MB 越界，
  // 整个基准以 0xC0000005 退出且不打印任何结果（块缓冲把已算出的行也丢了）。
  std::vector<uint8_t> copy_source(rgba.size(), 7);
  const double copy_start = NowMs();
  for (int index = 0; index < frames; ++index) {
    std::memcpy(rgba.data(), copy_source.data(), rgba.size());
  }
  const double copy_per_frame = (NowMs() - copy_start) / frames;

  const double total = per_frame + copy_per_frame;
  std::printf(
      "%4ux%-5u 换算 %8.2f ms/帧   memcpy %5.2f ms/帧   合计 %8.2f ms/帧"
      "   → 30fps 需 %5.1f%% 单核；按此速度最多 %5.1f fps\n",
      width, height, per_frame, copy_per_frame, total, total / 33.3 * 100.0,
      1000.0 / (total <= 0 ? 1e-9 : total));
  std::fflush(stdout);
}

}  // namespace

int main(int argc, char** argv) {
  // 构建配置由调用方用 argv 传进来：/Od 与 /O2 都不定义 _DEBUG，
  // 靠宏判断会得到"两次都显示 Release"的假信息。
  const char* config = argc > 1 ? argv[1] : "未知（未传构建配置）";
  std::printf("NV12->RGBA 基准（直接调用 windows/runner/yuv_to_rgba.cpp 的真实实现）\n");
  std::printf("构建配置：%s\n\n", config);
  std::fflush(stdout);
  Bench(1280, 720, 60);   // 实机解码输出尺寸（服务端不下采样时会保持源分辨率）
  Bench(1898, 853, 30);   // 用户日志里下发的窗口 bounds（奇数高度，旧基准就崩在这里）
  Bench(1920, 1080, 30);
  return 0;
}
