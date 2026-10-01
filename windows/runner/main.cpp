#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>
#include <fcntl.h>  // _O_APPEND / _O_TEXT（_open_osfhandle 的标志）
#include <io.h>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

/// 把引擎的 stderr 落一份到 exe 同目录的 `engine_stderr.log`。
///
/// **为什么必须这么做（2026-10-01 的教训）**：Flutter 引擎只在 stderr 上说话——
/// `[ERROR:flutter/shell/platform/embedder/embedder_external_texture_gl.cc(170)]
/// Could not create external texture` 这行就是"GPU 共享纹理上屏失败"的直接原因，
/// 而它只出现在 IDE 控制台里：**离线读不到，于是只能靠猜**（我因此把"已发布 67 帧"
/// 误当成"上屏成功"，害得真机黑屏没人发现）。
///
/// **踩过的坑（务必不要再写成那样）**：第一版用 `SetStdHandle` + `_wfreopen_s(stderr)`，
/// 结果在**没有控制台**的启动方式下（VS 的 "Windows (desktop)"）直接把进程搞崩：
///   `Debug Assertion Failed! ... lowio\write.cpp(50)
///    Expression: (fh >= 0 && (unsigned)fh < (unsigned)_nhandle)`
/// ——没有控制台时 `stderr` 的 fd 本来就是无效的，重定向一旦没接上，之后**任何**一句
/// stderr 写（包括原有 `DebugLog` 的 stderr 输出）都会撞上这个断言。
/// 正确做法有两条铁律：
///   ① 用 CRT 层面的 `_open_osfhandle` + `_dup2(fd, 2)`（`stderr` 绑定就是 fd 2），
///      这样 fd 2 一定指向一个**有效**句柄，断言不可能再触发；
///   ② **任何一步失败就立刻什么都不改**（`stderr` 保持原样），绝不留下半残状态。
void RedirectEngineStderrToFile() {
  wchar_t module_path[MAX_PATH] = {};
  if (::GetModuleFileNameW(nullptr, module_path, MAX_PATH) == 0) {
    return;
  }
  std::wstring path(module_path);
  const size_t slash = path.find_last_of(L"\\/");
  path = slash == std::wstring::npos ? std::wstring()
                                     : path.substr(0, slash + 1);
  path += L"engine_stderr.log";
  const HANDLE file =
      ::CreateFileW(path.c_str(), FILE_APPEND_DATA,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;  // 打不开就保持原样
  }
  const int fd = _open_osfhandle(reinterpret_cast<intptr_t>(file),
                                 _O_APPEND | _O_TEXT);
  if (fd < 0) {
    ::CloseHandle(file);
    return;
  }
  // _dup2 成功之后 fd 2 指向这个文件；失败则原来的 fd 2 不受影响。
  if (_dup2(fd, 2) != 0) {
    _close(fd);
    return;
  }
  // 有些组件不认 CRT 的 fd，而是直接 WriteFile(GetStdHandle(STD_ERROR_HANDLE))。
  ::SetStdHandle(STD_ERROR_HANDLE, file);
  _close(fd);  // fd 2 已经持有它（_dup2 内部复制了句柄）
}

/// stderr 是否真的可用（重定向失败时**不要**再往里写，否则就是上面那个断言）。
///
/// **注意不要用 `_get_osfhandle`/`_fileno` 做这个判断**：自测证明它们本身在 Debug CRT 下
/// 就会断言（`tools\run_stderr_redirect_test.cmd` 的 `handle-guard` 用例）。
/// `GetStdHandle` 是纯 Win32 调用，永远不会断言。
bool StderrUsable() {
  const HANDLE handle = ::GetStdHandle(STD_ERROR_HANDLE);
  return handle != nullptr && handle != INVALID_HANDLE_VALUE;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // 引擎的报错要能离线读到（见函数注释；真机"黑屏"就是靠它定性的）。
  RedirectEngineStderrToFile();
  if (StderrUsable()) {
    std::fprintf(stderr, "\n==== 进程启动 pid=%lu ====\n",
                 static_cast<unsigned long>(::GetCurrentProcessId()));
    std::fflush(stderr);
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ws_scrcpy_client", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
