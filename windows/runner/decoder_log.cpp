#include "decoder_log.h"

#include <windows.h>

#include <chrono>
#include <cstdio>
#include <io.h>
#include <mutex>
#include <string>
#include <vector>

namespace ws_scrcpy {
namespace {

// 日志文件上限：超过就就地截断重开，避免长时间投流把磁盘写爆。
constexpr long kLogFileMaxBytes = 2 * 1024 * 1024;

// 相对时间基准：进程内第一次写日志的时刻（≈ 解码器模块启动）。
//
// 为什么必须有时间：**"卡死"和"崩溃"、"慢"和"死"分不出来**。壁钟 + 相对耗时
// 能一眼看出某一步花了多久（例如 MFT 创建 3 秒），以及"崩在启动后第几毫秒"。
const std::chrono::steady_clock::time_point& LogTimeBase() {
  static const std::chrono::steady_clock::time_point base =
      std::chrono::steady_clock::now();
  return base;
}

// 日志前缀：`[壁钟时间.毫秒 | +相对启动毫秒 | pid=进程号] `。
//
// **pid 是必须的**：日志文件是**追加**写的，Android Studio 重新运行时会与前一个
// 实例的记录混在同一个文件里；没有 pid，"上一个进程的 OnDestroy 出现在本进程
// OnCreate 之前"这种交错会被误读成"同一进程里先销毁后创建"。
std::string LogPrefix() {
  SYSTEMTIME now;
  ::GetLocalTime(&now);
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - LogTimeBase());
  char prefix[128];
  std::snprintf(prefix, sizeof(prefix),
                "[%04d-%02d-%02d %02d:%02d:%02d.%03d | +%lldms | pid=%lu] ",
                now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
                now.wSecond, now.wMilliseconds,
                static_cast<long long>(elapsed.count()),
                static_cast<unsigned long>(::GetCurrentProcessId()));
  return std::string(prefix);
}

// 超过上限就截断（走已打开的句柄，不必再解析一次路径）。
void RotateLogFileIfTooBig(std::FILE* file) {
  if (file == nullptr || std::ftell(file) <= kLogFileMaxBytes) {
    return;
  }
  if (::_chsize_s(::_fileno(file), 0) == 0) {
    std::fseek(file, 0, SEEK_SET);
    const std::string marker =
        LogPrefix() + "ScrcpyLog: 日志超过上限，已截断重开\n";
    std::fputs(marker.c_str(), file);
    std::fflush(file);
  }
}

// 尝试按给定路径以追加方式打开日志文件；失败返回 nullptr。
std::FILE* TryOpen(const std::string& path) {
  // **必须允许别人在运行中读**（`_SH_DENYNO`）。
  //
  // 为什么（踩过）：原来用 `fopen_s(path, "ab")`，它在 UCRT 下拿的是**独占**共享模式，
  // 于是排障时想读一份正在写的日志（`Get-Content`、`[System.IO.File]::Open(..., FileShare.ReadWrite)`）
  // 全部报"正由另一进程使用"——**只能让用户先关掉程序**，一来一回就浪费一轮真机验证。
  // 日志是排查工具，它自己绝不能成为排查的障碍。
  //
  // `_fsopen` 被 MSVC 标成 C4996（"不安全"），但它是**唯一**能指定共享模式的 CRT 打开函数；
  // 换成 `fopen_s` 就又回到独占模式了，所以这里显式压制这条警告并说明原因。
#pragma warning(push)
#pragma warning(disable : 4996)
  std::FILE* file = ::_fsopen(path.c_str(), "ab", _SH_DENYNO);
#pragma warning(pop)
  if (file != nullptr) {
    return file;
  }
  return nullptr;
}

// 解析日志文件路径并打开：优先 **exe 同目录** 的 `scrcpy_decoder.log`
// （好找、构建目录通常可写），失败再退 `%TEMP%\scrcpy_decoder.log`。
std::FILE* OpenLogFile(std::string* resolved_path) {
  std::vector<char> module_path(MAX_PATH);
  const DWORD length = ::GetModuleFileNameA(
      nullptr, module_path.data(), static_cast<DWORD>(module_path.size()));
  if (length > 0 && length < module_path.size()) {
    const std::string path(module_path.data(), length);
    const size_t slash = path.find_last_of("\\/");
    if (slash != std::string::npos) {
      const std::string candidate =
          path.substr(0, slash + 1) + "scrcpy_decoder.log";
      if (std::FILE* file = TryOpen(candidate)) {
        *resolved_path = candidate;
        return file;
      }
    }
  }
  std::vector<char> temp_path(MAX_PATH);
  if (::GetTempPathA(static_cast<DWORD>(temp_path.size()), temp_path.data()) >
      0) {
    const std::string candidate =
        std::string(temp_path.data()) + "scrcpy_decoder.log";
    if (std::FILE* file = TryOpen(candidate)) {
      *resolved_path = candidate;
      return file;
    }
  }
  return nullptr;
}

struct LogState {
  std::mutex mutex;
  std::string module_name = "ScrcpyLog";
  std::string file_path;
  std::FILE* file = nullptr;
  bool opened = false;
  /// `WS_SCRCPY_LOG=0/off/false` 时**只走 OutputDebugStringA**：不写文件、不写 stderr。
  ///
  /// **为什么需要这个开关（2026-10-01 真机现象）**：用户报告"网页端早就操作完了，
  /// Flutter 端时不时卡几秒才显示"。日志每条都 `fflush` 到盘 + 写 stderr，
  /// 而 **stderr 在 IDE/调试器下可能因为没人读管道而阻塞**——写日志的那个线程
  /// （解码线程或 platform 线程）就会跟着卡住，表现正是"画面卡几秒"。
  /// 有了这个开关，一分钟就能把这个嫌疑 A/B 掉（关掉后不卡 → 就是日志 I/O 的锅）。
  bool disabled = false;
};

// 是否显式关闭了日志 I/O（环境变量只读一次）。
bool LogDisabledByEnvironment() {
  char buffer[16] = {};
  const DWORD length = ::GetEnvironmentVariableA("WS_SCRCPY_LOG", buffer,
                                                 static_cast<DWORD>(sizeof(buffer)));
  if (length == 0 || length >= sizeof(buffer)) {
    return false;
  }
  std::string value(buffer, length);
  for (char& character : value) {
    if (character >= 'A' && character <= 'Z') {
      character = static_cast<char>(character - 'A' + 'a');
    }
  }
  return value == "0" || value == "off" || value == "false" || value == "no";
}

LogState& State() {
  static LogState state;
  return state;
}

// 自测用的路径覆盖（见头文件注释）；未设置时为空串。
std::string& OverriddenPath() {
  static std::string path;
  return path;
}

// stderr 写之前必须确认它是可用的。
//
// **为什么（真机踩过，2026-10-01）**：从 Visual Studio 以 "Windows (desktop)" 启动时进程
// **没有控制台**，`stderr` 本来就不可用；此时任何 `fputs(…, stderr)` 在 Debug 版
// 都会直接命中 CRT 断言：
//   `Debug Assertion Failed! ... lowio\write.cpp(50)
//    Expression: (fh >= 0 && (unsigned)fh < (unsigned)_nhandle)`
// 表现就是"应用一启动就弹断言框"。日志是排查手段，**绝不能因为它把进程搞崩**：
// 控制台不可用就只走 `OutputDebugStringA` 与文件（两者都不依赖 stderr）。
//
// **不要用 `_get_osfhandle`/`_fileno` 判断**：自测（`tools\run_stderr_redirect_test.cmd`
// 的 `handle-guard` 用例）证明它们本身在 Debug CRT 下就会断言。`GetStdHandle` 永不断言。
bool StderrWritable() {
  const HANDLE handle = ::GetStdHandle(STD_ERROR_HANDLE);
  return handle != nullptr && handle != INVALID_HANDLE_VALUE;
}

}  // namespace

void OverrideLogFilePathForTesting(const std::string& path) {
  OverriddenPath() = path;
}

const std::string& InitializeLog(const char* module_name) {
  LogState& state = State();
  std::lock_guard<std::mutex> lock(state.mutex);
  if (!state.opened) {
    state.opened = true;
    if (module_name != nullptr && module_name[0] != '\0') {
      state.module_name = module_name;
    }
    state.disabled = LogDisabledByEnvironment();
    if (state.disabled) {
      // 只打一条（走调试器），把"为什么没有文件日志"说清楚，免得后面误判成"日志坏了"。
      const std::string notice =
          LogPrefix() + state.module_name +
          ": WS_SCRCPY_LOG 已关闭文件与 stderr 输出（只走调试器）\n";
      ::OutputDebugStringA(notice.c_str());
      return state.file_path;
    }
    const std::string& overridden = OverriddenPath();
    if (!overridden.empty()) {
      state.file = TryOpen(overridden);
      state.file_path = state.file != nullptr ? overridden : std::string();
    } else {
      state.file = OpenLogFile(&state.file_path);
    }
    const std::string banner =
        LogPrefix() + state.module_name + ": 日志启动，文件=" +
        (state.file_path.empty() ? std::string("<无，仅 stderr/调试器>")
                                 : state.file_path) +
        "\n";
    ::OutputDebugStringA(banner.c_str());
    if (StderrWritable()) {
      std::fputs(banner.c_str(), stderr);
      std::fflush(stderr);
    }
    if (state.file != nullptr) {
      std::fputs(banner.c_str(), state.file);
      std::fflush(state.file);
    }
  }
  return state.file_path;
}

void DebugLog(const std::string& message) {
  LogState& state = State();
  const std::string body = LogPrefix() + message + "\n";
  std::lock_guard<std::mutex> lock(state.mutex);
  // 模块名与文件句柄都在锁内读：InitializeLog 可能在并发的第一次调用里改它们。
  const std::string line = state.module_name + ": " + body;
  ::OutputDebugStringA(line.c_str());
  if (state.disabled) {
    return;  // 见 LogState::disabled 的说明：关掉文件与 stderr，只留调试器输出。
  }
  if (StderrWritable()) {
    std::fputs(line.c_str(), stderr);
    std::fflush(stderr);
  }
  if (state.file != nullptr) {
    RotateLogFileIfTooBig(state.file);
    std::fputs(line.c_str(), state.file);
    std::fflush(state.file);
  }
}

bool LogOnce(const char* key, const std::string& message) {
  static std::mutex mutex;
  static std::vector<std::string> seen;
  std::lock_guard<std::mutex> lock(mutex);
  for (const std::string& item : seen) {
    if (item == key) {
      return false;
    }
  }
  seen.emplace_back(key);
  DebugLog(message);
  return true;
}

long long LogElapsedMs() {
  LogState& state = State();
  if (!state.opened) {
    return -1;
  }
  return static_cast<long long>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - LogTimeBase())
          .count());
}

std::string LogFilePath() {
  LogState& state = State();
  std::lock_guard<std::mutex> lock(state.mutex);
  return state.file_path;
}

}  // namespace ws_scrcpy
