#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <cstdint>
#include <memory>

#include "scrcpy_video_decoder.h"
#include "win32_window.h"
// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 窗口是否已经开始销毁。
  //
  // 通道 handler 捕获的是 `this`：如果引擎在 OnDestroy 之后还派发一次调用
  // （实测崩溃栈里就有 `Win32Window::MessageHandler` 这一帧），lambda 碰到的就是
  // 已经析构的 FlutterWindow。这个标记让 handler 第一行就能安全地短路——
  // **它必须是第一个成员**，保证在任何可能触发回调的成员之前构造、在最后销毁。
  std::atomic<bool> destroying_{false};

  // 处理 ws_scrcpy/video 上的调用：create / pushFrame / release / getSize。
  // 与 Android 的 MainActivity.kt 保持同一份契约（见 AGENTS.md §11、§12）。
  void HandleVideoMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 当前解码尺寸（可能还是占位尺寸）；通道层用它组回执。
  ws_scrcpy::DecoderSize CurrentDecoderSize() const;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 原生投流解码通道与解码器（Windows 实现见 scrcpy_video_decoder.cpp）。
  //
  // 注意：这里**没有**共享状态 / `alive` 标记了。原来那套是为了让
  // `PostPlatformThreadTask` 投递出去、但窗口已销毁的任务不去碰旧引擎；
  // 现在尺寸是 Dart 主动拉（create / pushFrame 的回执 + getSize），跨线程投递
  // 这条路径整体消失，也就不再需要它（见 AGENTS.md §12）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> video_channel_;
  std::unique_ptr<ScrcpyVideoDecoder> video_decoder_;

  // 通道 handler 是否装上了（OnDestroy 里据此决定要不要显式摘掉）。
  bool channel_registered_ = false;

  // 注册通道方法的耗时（毫秒，相对模块首次写日志）；create 时传给解码器，
  // 由解码线程在启动阶段汇总里一并打出来。
  long long channel_register_ms_ = -1;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
