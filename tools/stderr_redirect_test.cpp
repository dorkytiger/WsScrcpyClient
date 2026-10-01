// 回归自测：**无控制台/无有效 stderr** 时写 stderr 会怎样、以及修复后的重定向是否安全。
//
// 背景（真机踩过，2026-10-01）：为了抓 Flutter 引擎的报错，`main.cpp` 原本用
// `SetStdHandle` + `_wfreopen_s(stderr, ...)` 重定向。从 Visual Studio 以
// "Windows (desktop)" 启动时进程没有控制台；重定向一旦失败，之后任何一句 stderr 写
// 在 Debug 版都会命中 CRT 断言、弹断言框：
//   Debug Assertion Failed! ... lowio\write.cpp(50)
//   Expression: (fh >= 0 && (unsigned)fh < (unsigned)_nhandle)
//
// 本自测按 GUI 子系统链接（`/SUBSYSTEM:WINDOWS`，与真机启动方式一致），并且**结果只写
// 独立文件**：不可靠的那条出口（stderr）绝不用来报告结果，否则自测自己就会挂。
// 每个探针跑在独立进程里（断言会 abort 整个进程）。
//
//   --probe handle-guard            只用 GetStdHandle 判断：必须**永不**断言（守卫要安全）
//   --probe freopen-fail-then-write 复刻旧写法的失败分支：Debug **预期断言**（根因）
//   --probe naive-write             直接写 stderr（不重定向）：记录实际行为
//   --probe redirect-then-write     重定向后写 ASCII 标记：必须不挂，标记要落进文件

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <fcntl.h>
#include <io.h>

#include <cstdio>
#include <cstring>
#include <string>

namespace {

// 与 windows/runner/main.cpp 里的实现逐句一致（改那边就要同步这里）。
bool RedirectStderrTo(const std::wstring& path) {
  const HANDLE file = ::CreateFileW(path.c_str(), FILE_APPEND_DATA,
                                    FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  const int fd =
      _open_osfhandle(reinterpret_cast<intptr_t>(file), _O_APPEND | _O_TEXT);
  if (fd < 0) {
    ::CloseHandle(file);
    return false;
  }
  if (_dup2(fd, 2) != 0) {
    _close(fd);
    return false;
  }
  ::SetStdHandle(STD_ERROR_HANDLE, file);
  _close(fd);
  return true;
}

std::wstring TempDir() {
  wchar_t directory[MAX_PATH] = {};
  ::GetTempPathW(MAX_PATH, directory);
  return directory;
}

// 结果只落文件（stdout/stderr 都可能不可用）。
void AppendResult(const char* name, const std::string& text) {
  const std::wstring path = TempDir() + L"ws_scrcpy_stderr_probe.txt";
  FILE* file = nullptr;
  if (_wfopen_s(&file, path.c_str(), L"ab") != 0 || file == nullptr) {
    return;
  }
  const std::string line = std::string(name) + "=" + text + "\n";
  std::fwrite(line.data(), 1, line.size(), file);
  std::fclose(file);
}

}  // namespace

int main(int argc, char** argv) {
  std::string probe;
  for (int index = 1; index < argc; ++index) {
    if (std::strcmp(argv[index], "--probe") == 0 && index + 1 < argc) {
      probe = argv[index + 1];
    }
  }
  if (probe.empty()) {
    return 2;
  }
  const std::wstring target = TempDir() + L"ws_scrcpy_stderr_target.log";

  if (probe == "handle-guard") {
    // 守卫必须绝对安全：GetStdHandle 是 Win32 API，不会断言。
    // （反面教材：`_get_osfhandle`/`_fileno` 对失效 fd 在 Debug CRT 下自己就会断言。）
    const HANDLE handle = ::GetStdHandle(STD_ERROR_HANDLE);
    const bool usable = handle != nullptr && handle != INVALID_HANDLE_VALUE;
    AppendResult("handle-guard", usable ? "usable=1" : "usable=0");
    return 0;
  }

  if (probe == "freopen-fail-then-write") {
    // 复刻**旧写法的失败分支**：对不存在的路径做 `_wfreopen_s(stderr, ...)`。
    // 失败之后 stderr 这个流就废了，随后任何写都会命中 write.cpp(50) 的断言
    // —— 这正是真机上弹出的那个框（Debug 版；Release 版没有断言，只是静默丢字）。
    FILE* stream = nullptr;
    const errno_t result = _wfreopen_s(
        &stream, L"Z:\\ws_scrcpy_missing_dir\\stderr.log", L"a", stderr);
    AppendResult("freopen-fail-then-write",
                 std::string("freopen_s=") + std::to_string(result));
    std::fputs("this write is expected to trip the CRT assert on the debug CRT\n",
               stderr);
    std::fflush(stderr);
    return 0;
  }

  if (probe == "naive-write") {
    std::fputs("naive stderr write without any redirection\n", stderr);
    std::fflush(stderr);
    AppendResult("naive-write", "done");
    return 0;
  }

  if (probe == "redirect-then-write") {
    ::DeleteFileW(target.c_str());
    if (!RedirectStderrTo(target)) {
      AppendResult("redirect-then-write", "redirected=0");
      return 1;
    }
    // 只用 ASCII 标记：.cmd 里的 findstr 校验不能依赖中文编码。
    std::fputs("STDERR-REDIRECT-OK\n", stderr);
    std::fflush(stderr);
    AppendResult("redirect-then-write", "redirected=1");
    return 0;
  }

  AppendResult("unknown", probe);
  return 2;
}
