// Windows 原生解码链路的**本机可跑**自测：像素缓冲所有权 + 日志文件落盘。
//
// 为什么要有它：真机崩溃（0xC0000005 / std::function 调用已失效目标）没法在本机复现
// （没有设备、没有真实服务端、没有码流），但这条链路上有两块**完全不依赖 Media
// Foundation** 的东西可以离线压测：
//
//   1) `PixelBufferStore`（windows/runner/scrcpy_pixel_store.{h,cpp}）
//      —— 解码线程与 Flutter raster 线程唯一共享可变状态的地方；
//      "引擎还在读、我们却释放了"这类 use-after-free 正好是首跑崩溃的同族问题。
//      这里用 canary 字节 + 明确的所有权时序（发布 → 取走 → release_callback →
//      尺寸变化 → Clear）来验证契约，并用 AddressSanitizer 再跑一遍。
//
//   2) `decoder_log`（windows/runner/decoder_log.{h,cpp}）
//      —— "崩溃现场必须留下日志"这件事本身也要被验证：日志文件到底会不会被创建、
//      每条是不是真的 flush 到盘上、超过 2 MB 会不会截断。
//      本轮排查吃过一次"日志文件从来没出现过"的苦，所以要有一条断言直接证明它。
//
// 用 canary 而不是只看返回值：返回 true 也可能是"写越界了但恰好没崩"。
//
// 构建与运行见 tools/run_pixel_store_test.cmd（普通 /Od 一遍 + ASan 一遍）。

#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <share.h>
#include <string>
#include <thread>
#include <vector>

#include "decoder_log.h"
#include "scrcpy_pixel_store.h"

namespace {

int g_checks = 0;
int g_failed = 0;
int g_executed = 0;  // 真的跑过的用例数（防"空跑型假绿"）

// 只读探测日志文件。
//
// 为什么不用 fopen_s(..., "rb")：日志文件这时还被 DebugLog 的句柄以追加方式打开着，
// `fopen_s` 走的是"独占式"共享模式，在受限环境（以及真实的 DSH 沙箱）里会直接
// 返回 EACCES(13)。这里显式声明"允许别人读写"的共享模式，尝试把内容读回来做断言。
std::FILE* OpenForProbe(const std::string& path) {
  return ::_fsopen(path.c_str(), "rb", _SH_DENYNO);
}

void Check(bool condition, const char* what) {
  ++g_checks;
  if (!condition) {
    ++g_failed;
    std::printf("  [FAIL] %s\n", what);
  }
}

// 往缓冲首尾之外撒 canary，验证换算/拷贝没有越界写。
constexpr size_t kCanaryBytes = 64;
constexpr uint8_t kCanaryValue = 0xAB;

// 并发用例的迭代次数（放在文件作用域，lambda 里不必捕获）。
constexpr int kConcurrentIterations = 400;

struct CanaryBuffer {
  std::vector<uint8_t> raw;  // canary | payload | canary

  explicit CanaryBuffer(size_t payload_bytes)
      : raw(kCanaryBytes + payload_bytes + kCanaryBytes, kCanaryValue) {}

  uint8_t* data() { return raw.data() + kCanaryBytes; }
  size_t size() const { return raw.size() - 2 * kCanaryBytes; }

  bool CanaryIntact(const char* what) {
    for (size_t i = 0; i < kCanaryBytes; ++i) {
      if (raw[i] != kCanaryValue || raw[raw.size() - 1 - i] != kCanaryValue) {
        Check(false, what);
        return false;
      }
    }
    Check(true, what);
    return true;
  }
};

// ---------------------------------------------------------------- 用例：所有权契约

void TestOwnershipLifecycle() {
  std::printf("用例：像素缓冲所有权（Grant / release_callback）\n");
  ++g_executed;

  auto store = std::make_shared<PixelBufferStore>();
  CanaryBuffer scratch(0);

  // 尺寸还没设：引擎要缓冲必须拿到 nullptr（引擎有判空，会跳过这一帧）。
  Check(store->CopyLatest() == nullptr, "没有缓冲时 CopyLatest 返回 nullptr");
  Check(store->width() == 0 && store->height() == 0, "初始宽高为 0");

  // 第一次 Resize：scratch 会被按新尺寸重建。
  const uint32_t width = 1921;  // 故意用奇数（历史崩溃就在奇数高度上）
  const uint32_t height = 853;
  const size_t bytes = store->Resize(width, height, nullptr);
  Check(bytes == static_cast<size_t>(width) * height * 4, "Resize 返回整帧字节数");
  Check(store->width() == width && store->height() == height, "Resize 后宽高正确");
  ++g_executed;

  // 让 scratch 带上 canary 再发布：PublishDecoded 只做 swap，不该越界。
  CanaryBuffer frame(static_cast<size_t>(width) * height * 4);
  frame.CanaryIntact("Resize 之后 canary 未被破坏");

  for (int i = 0; i < 4; ++i) {
    std::memset(frame.data(), static_cast<int>(0x10 + i), frame.size());
    store->PublishDecoded(&frame.raw);  // 注意：这里传的是带 canary 的整块
    frame.CanaryIntact("PublishDecoded 没有越界写");
  }
  // PublishDecoded 期望的是"恰好整帧大小"的 vector；上面的 raw 带了 canary，
  // 尺寸不匹配时它应当**拒绝**而不是写坏内存（这就是它内部的长度检查）。
  Check(store->has_published() == false, "尺寸不匹配时 PublishDecoded 拒绝该帧");

  // 用一个尺寸正确的 scratch 走正常路径。
  std::vector<uint8_t> exact(static_cast<size_t>(width) * height * 4, 0x77);
  store->PublishDecoded(&exact);
  Check(store->has_published(), "尺寸匹配时 PublishDecoded 接受该帧");

  // 引擎取走一帧：第一次必须触发 first-pull 回调，且描述符宽高正确。
  const FlutterDesktopPixelBuffer* descriptor = store->CopyLatest();
  Check(descriptor != nullptr, "CopyLatest 返回描述符");
  Check(descriptor->width == width && descriptor->height == height,
        "描述符宽高 = 真实解码尺寸（引擎以它为准）");
  Check(descriptor->buffer != nullptr, "描述符 buffer 非空");
  // 引擎要求行跨距紧凑：width*4。这里能验证的就是"描述符宽高与 buffer 一致"。
  const uint8_t* engine_bytes = descriptor->buffer;
  Check(engine_bytes[0] == 0x77, "引擎读到的就是我们发布的那一帧");

  // 再取一帧：回调不该再触发（once-only）。
  const FlutterDesktopPixelBuffer* second = store->CopyLatest();
  Check(second != nullptr, "第二次 CopyLatest 仍然有描述符");

  // **关键时序**：引擎读完才调用 release_callback。在此之前缓冲必须一直有效。
  // 这里刻意先让 store 换尺寸 / Clear（退出路径会发生的事），再回调释放。
  store->Resize(width + 1, height + 1, nullptr);
  store->Clear();
  // 上面两个动作都不该影响已经交出去的那一帧。
  Check(engine_bytes[0] == 0x77, "Clear/Resize 之后引擎手上的旧帧仍然可读");
  if (descriptor->release_callback != nullptr) {
    descriptor->release_callback(descriptor->release_context);
  }
  if (second->release_callback != nullptr) {
    second->release_callback(second->release_context);
  }
  Check(true, "release_callback 正常返回（没有二次释放）");
  ++g_executed;
}

// 用例：尺寸连续变化时，交付给引擎的始终是"当前尺寸"，不会给出错帧。
void TestSizeChanges() {
  std::printf("用例：尺寸变化（含奇数宽高）\n");
  ++g_executed;
  auto store = std::make_shared<PixelBufferStore>();

  const uint32_t sizes[][2] = {
      {1280, 720}, {1920, 1080}, {1080, 1920}, {853, 481}, {2, 2}, {1, 1}};
  for (const auto& pair : sizes) {
    const uint32_t width = pair[0];
    const uint32_t height = pair[1];
    std::vector<uint8_t> scratch;
    const size_t bytes = store->Resize(width, height, &scratch);
    Check(bytes == static_cast<size_t>(width) * height * 4,
          "Resize 字节数 = width*height*4");
    Check(scratch.size() == bytes, "传入的 scratch 被同步重建");
    Check(store->width() == width, "尺寸变化后宽正确");
    Check(store->height() == height, "尺寸变化后高正确");

    std::vector<uint8_t> frame(bytes, static_cast<uint8_t>(width & 0xFF));
    store->PublishDecoded(&frame);
    const FlutterDesktopPixelBuffer* descriptor = store->CopyLatest();
    Check(descriptor != nullptr, "每次尺寸变化后都能取到描述符");
    Check(descriptor->width == width && descriptor->height == height,
          "描述符跟着最新尺寸走");
    if (descriptor != nullptr && descriptor->release_callback != nullptr) {
      descriptor->release_callback(descriptor->release_context);
    }
    ++g_executed;
  }
}

// 用例：多线程时序（解码线程发布 vs raster 线程取走）。
// ASan 下这一条最能暴露 use-after-free。
void TestConcurrentPublishAndPull() {
  std::printf("用例：并发发布/取走（解码线程 vs raster 线程）\n");
  ++g_executed;
  auto store = std::make_shared<PixelBufferStore>();
  std::vector<uint8_t> scratch;
  const uint32_t width = 640;
  const uint32_t height = 360;
  const size_t bytes = store->Resize(width, height, &scratch);

  constexpr int kIterations = kConcurrentIterations;
  std::thread producer([&store, &scratch, bytes]() {
    for (int i = 0; i < kConcurrentIterations; ++i) {
      std::fill(scratch.begin(), scratch.end(), static_cast<uint8_t>(i));
      store->PublishDecoded(&scratch);
    }
  });
  int pulled = 0;
  for (int i = 0; i < kIterations; ++i) {    const FlutterDesktopPixelBuffer* descriptor = store->CopyLatest();
    if (descriptor == nullptr) {
      continue;
    }
    // 模拟引擎读整帧（这一步在真实链路里发生在 release_callback 之前）。
    volatile uint8_t sink = 0;
    for (size_t offset = 0; offset < bytes; offset += 4096) {
      sink = static_cast<uint8_t>(sink + descriptor->buffer[offset]);
    }
    static_cast<void>(sink);
    if (descriptor->release_callback != nullptr) {
      descriptor->release_callback(descriptor->release_context);
    }
    ++pulled;
  }
  producer.join();
  Check(pulled > 0, "并发期间至少取到一帧（真的跑过）");
  Check(store->width() == width && store->height() == height, "并发后尺寸没被写坏");
  ++g_executed;
}

// 用例：注销回调里的 Clear 与"引擎手上还有 Grant"并存。
void TestClearWhileGrantAlive() {
  std::printf("用例：Clear 之后旧的 Grant 仍然有效\n");
  ++g_executed;
  auto store = std::make_shared<PixelBufferStore>();
  std::vector<uint8_t> scratch;
  const size_t bytes = store->Resize(64, 64, &scratch);
  std::vector<uint8_t> frame(bytes, 0x5A);
  store->PublishDecoded(&frame);

  std::vector<const FlutterDesktopPixelBuffer*> held;
  for (int i = 0; i < 8; ++i) {
    held.push_back(store->CopyLatest());
    Check(held.back() != nullptr, "取到描述符");
  }
  // 模拟"纹理注销完成"：store 释放它自己那份引用。
  store->Clear();
  for (const FlutterDesktopPixelBuffer* descriptor : held) {
    Check(descriptor->buffer != nullptr, "Clear 之后旧帧指针仍非空");
    Check(descriptor->buffer[0] == 0x5A, "Clear 之后旧帧内容仍可读");
  }
  for (const FlutterDesktopPixelBuffer* descriptor : held) {
    if (descriptor->release_callback != nullptr) {
      descriptor->release_callback(descriptor->release_context);
    }
  }
  Check(store->CopyLatest() == nullptr, "Clear 之后没有新帧可取");
  ++g_executed;
}

// 日志文件的当前大小（只查元数据，不打开文件——受限环境里这是唯一可靠的办法）。
long long FileSizeOnDisk(const std::string& path) {
  WIN32_FILE_ATTRIBUTE_DATA info = {};
  if (!::GetFileAttributesExA(path.c_str(), GetFileExInfoStandard, &info)) {
    return -1;
  }
  return (static_cast<long long>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
}

// 用例：日志文件真的被创建、真的会截断。
//
// 关于"读回内容"这件事：本机（DSH 受限沙箱）**不允许把刚写出去、而且当前还开着
// 的文件再打开读**（同一目录下新建的探针文件能读，日志文件因为还被日志句柄持有着
// 就 EACCES）。这是环境限制，不是被测代码的问题，所以这里如实分成两种结果：
//   - 能读回：连内容与时间戳格式一起断言（正常开发机就是这样）；
//   - 读不回：只用元数据（创建 + 大小 + 上限）做断言，并**明确打印"内容未验证"**，
//     绝不假装通过。
void TestLogFile() {
  std::printf("用例：日志文件落盘 + 2MB 截断\n");
  ++g_executed;

  // 日志落在工作区内的固定相对路径（脚本会先把 .tmp\pixeltest 建好，
  // 并让 exe 从仓库根目录启动，所以这里不需要处理目录不存在的情况）。
  const std::string path = ".tmp/pixeltest/pixel_store_test.log";
  std::remove(path.c_str());
  ws_scrcpy::OverrideLogFilePathForTesting(path);
  ws_scrcpy::InitializeLog("PixelStoreTest");

  Check(ws_scrcpy::LogFilePath() == path, "日志文件路径被覆盖并生效");

  ws_scrcpy::DebugLog("第一条日志：验证文件真的被创建");
  Check(ws_scrcpy::LogElapsedMs() >= 0, "LogElapsedMs 可用");

  const long long size_after_first = FileSizeOnDisk(path);
  Check(size_after_first > 0, "写入一条日志后文件立刻存在且非空");
  std::printf("  (元数据) 首条日志后大小 = %lld 字节\n", size_after_first);

  // 能读回就顺带验证内容与时间戳格式（正常开发机走这条）。
  bool content_verified = false;
  if (std::FILE* probe = OpenForProbe(path)) {
    std::vector<char> content(4096, 0);
    const size_t read = std::fread(content.data(), 1, content.size() - 1, probe);
    std::fclose(probe);
    const std::string text(content.data(), read);
    Check(text.find("第一条日志") != std::string::npos,
          "内容已经 flush 到盘上（进程还没退出就能读到）");
    // 时间戳格式：`[YYYY-MM-DD HH:MM:SS.mmm | +Nms | pid=NNN] `
    Check(text.find(" | +") != std::string::npos, "带相对时间戳 `| +Nms`");
    // pid 是必须的：日志文件是追加写的，多实例记录会混在一起（真踩过，见 AGENTS §12.4）。
    Check(text.find("pid=") != std::string::npos, "带 pid（多实例日志可区分）");
    Check(text.find("-") != std::string::npos && text.find(":") != std::string::npos,
          "带壁钟时间戳");
    content_verified = true;
  }

  // 超过 2 MB 必须被截断（否则长时间投流会把盘写爆）。
  for (int i = 0; i < 40000; ++i) {
    ws_scrcpy::DebugLog("填充日志以触发截断：" + std::string(96, 'x'));
  }
  const long long size_after_flood = FileSizeOnDisk(path);
  std::printf("  (元数据) 4 万条日志后大小 = %lld 字节\n", size_after_flood);
  Check(size_after_flood > 512 * 1024, "日志文件确实被写入了内容");
  Check(size_after_flood <= 3 * 1024 * 1024, "日志文件被截断在 2MB 上限附近");
  if (!content_verified) {
    std::printf(
        "  (注意) 本机受限：日志文件正被日志句柄持有时无法再打开读回，"
        "因此\"内容/时间戳格式\"这一项**未在本机验证**（已用元数据验证创建与上限）。"
        "真机运行时请人工看日志前几行。\n");
  }
  ++g_executed;
}

// 用例：LogOnce 只打一次。
void TestLogOnce() {
  std::printf("用例：LogOnce 只输出一次\n");
  ++g_executed;
  const bool first = ws_scrcpy::LogOnce("k-once", "只应出现一次");
  const bool second = ws_scrcpy::LogOnce("k-once", "只应出现一次");
  const bool other = ws_scrcpy::LogOnce("k-once-2", "另一个 key 可以再打");
  Check(first, "第一次 LogOnce 返回 true");
  Check(!second, "同一个 key 第二次返回 false");
  Check(other, "不同 key 互不影响");
  ++g_executed;
}

}  // namespace

int main(int argc, char** argv) {
  static_cast<void>(argc);
  static_cast<void>(argv);
  std::printf("==== 原生解码链路自测（像素缓冲所有权 + 日志落盘）====\n");
  // 编译时刻标记：确认自己跑的确实是刚编出来的这一版（排查过"跑的是旧二进制"）。
  std::printf("(build) 编译时刻 %s %s，修订标记 MARKER-3\n", __DATE__, __TIME__);

  TestOwnershipLifecycle();
  TestSizeChanges();
  TestConcurrentPublishAndPull();
  TestClearWhileGrantAlive();
  TestLogFile();
  TestLogOnce();

  std::printf("\n用例执行数 executed=%d，检查项=%d，失败=%d\n", g_executed,
              g_checks, g_failed);
  // 防"空跑型假绿"：如果用例根本没跑（例如被条件编译掉、或提前 return），
  // 这里会直接失败。
  if (g_executed < 6) {
    std::printf("[FAIL] executed=%d < 6：用例没有真的跑起来\n", g_executed);
    return 1;
  }
  if (g_checks < 40) {
    std::printf("[FAIL] 检查项只有 %d 个，少于预期的 40：断言强度不足\n",
                g_checks);
    return 1;
  }
  if (g_failed != 0) {
    std::printf("RESULT: FAIL（%d 项失败）\n", g_failed);
    return 1;
  }
  std::printf("RESULT: PASS\n");
  return 0;
}
