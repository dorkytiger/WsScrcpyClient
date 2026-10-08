#include "flutter_window.h"

#include <flutter/method_call.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <atomic>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "decoder_log.h"
#include "d3d11_video_presenter.h"
#include "flutter/generated_plugin_registrant.h"

namespace {

// 通道名与 Dart 侧
// （lib/feature/stream/data/remote/native_video_decoder.dart）严格一致。
constexpr char kVideoChannelName[] = "ws_scrcpy/video";

// 日志模块名（与解码器的前缀区分开，好看出是 platform thread 还是解码线程写的）。
constexpr char kModuleName[] = "FlutterWindow";

// 日志出口（实现见 windows/runner/decoder_log.cpp）。
using ws_scrcpy::DebugLog;
using ws_scrcpy::LogOnce;

// 相对模块首次写日志的毫秒数（未初始化时是 -1）。
long long NowMs() { return ws_scrcpy::LogElapsedMs(); }

// 组"当前尺寸"回执：`{"width":w,"height":h}`。
//
// 为什么用回执/拉取而不是反向 `onSizeChanged` 推送：见 AGENTS.md §12 与
// scrcpy_video_decoder.h 的注释——投递到 platform thread 的任务活过了它捕获的状态，
// 就是 0x58CA5 那个崩溃。
flutter::EncodableMap SizePayload(ws_scrcpy::DecoderSize size) {
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<int32_t>(size.width));
  payload[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<int32_t>(size.height));
  return payload;
}

// 与 Flutter 插件同款的取法：先向引擎要一个具名 plugin registrar，再从它拿纹理注册器。
// （FlutterEngine 自己就是 PluginRegistry，但 TextureRegistrar 封装在 PluginRegistrar 里，
// 而这个名字必须是全应用唯一的，因此 runner 自己也占一个名字。）
flutter::TextureRegistrar* TextureRegistrarFor(flutter::FlutterEngine* engine) {
  if (engine == nullptr) {
    return nullptr;
  }
  FlutterDesktopPluginRegistrarRef registrar_ref =
      engine->GetRegistrarForPlugin("ScrcpyVideoDecoder");
  if (registrar_ref == nullptr) {
    return nullptr;
  }
  flutter::PluginRegistrar* registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrar>(registrar_ref);
  if (registrar == nullptr) {
    return nullptr;
  }
  return registrar->texture_registrar();
}

// 宽字符 → UTF-8（适配器名进日志；与 d3d11_video_presenter.cpp 里那份同样的做法，
// 但只用于日志，不值得为它把两个编译单元耦在一起）。
std::string Utf8FromWideAdapterName(const wchar_t* text) {
  if (text == nullptr) {
    return {};
  }
  const int bytes = ::WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0,
                                          nullptr, nullptr);
  if (bytes <= 1) {
    return {};
  }
  std::vector<char> buffer(static_cast<size_t>(bytes), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text, -1, buffer.data(), bytes, nullptr,
                        nullptr);
  return std::string(buffer.data());
}

// 问引擎"你渲染用的是哪块 DXGI 适配器"，打包成 LUID 交给解码器。
//
// 为什么必须问：GPU 呈现路（共享纹理句柄 → 引擎）只有在**两边同一块适配器**上才可能成功
// —— 传统 DXGI 共享句柄不能跨适配器打开（tools\run_d3d11_adapter_probe.cmd 实测：
// 同适配器 3/3、跨适配器 0/6），真机第三次"已发布 67 帧但全黑"就是这个原因
// （AGENTS.md §12.8）。以前只能按厂商猜核显（`VendorId == 0x8086`），猜错就是黑屏；
// `FlutterDesktopPluginRegistrarGetGraphicsAdapter` 是引擎自己报的，不需要猜。
//
// 拿不到就返回 known=false —— 解码器据此**不启用 GPU 路**（宁可 CPU 忙，也不要黑屏）。
ws_scrcpy::EngineRenderingAdapter QueryEngineRenderingAdapter(
    flutter::FlutterEngine* engine) {
  ws_scrcpy::EngineRenderingAdapter adapter;
  if (engine == nullptr) {
    return adapter;
  }
  FlutterDesktopPluginRegistrarRef registrar_ref =
      engine->GetRegistrarForPlugin("ScrcpyVideoDecoder");
  if (registrar_ref == nullptr) {
    DebugLog("引擎渲染适配器：拿不到 plugin registrar，按未知处理");
    return adapter;
  }
  IDXGIAdapter* raw_adapter = nullptr;
  if (!FlutterDesktopPluginRegistrarGetGraphicsAdapter(registrar_ref,
                                                       &raw_adapter) ||
      raw_adapter == nullptr) {
    DebugLog("引擎渲染适配器：FlutterDesktopPluginRegistrarGetGraphicsAdapter 失败");
    return adapter;
  }
  // 引擎把适配器交给我们，引用计数归我们（头文件明写"caller is responsible for
  // releasing"），所以这里必须自己 Release 一次。
  DXGI_ADAPTER_DESC description = {};
  if (SUCCEEDED(raw_adapter->GetDesc(&description))) {
    adapter.known = true;
    adapter.luid = ws_scrcpy::PresenterOptions::PackLuid(
        description.AdapterLuid.LowPart, description.AdapterLuid.HighPart);
    adapter.name = Utf8FromWideAdapterName(description.Description);
  }
  raw_adapter->Release();
  return adapter;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {
  // 日志要在**最早的构造阶段**就立起来：`Win32Window::Create()` 的第一句是
  // `Destroy()` → `OnDestroy()`（模板行为，见 OnCreate/OnDestroy 的注释），
  // 那条"创建之前的收尾"日志也应当带上正确的模块名，而不是落到默认的 ScrcpyLog。
  ws_scrcpy::InitializeLog(kModuleName);
  DebugLog("FlutterWindow 构造完成（日志已就绪，等待 Create / OnCreate）");
}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  // **必须先清掉 destroying_**：`Win32Window::Create()` 会先调一次 `Destroy()`
  // → 我们的 `OnDestroy()`，而那时窗口/引擎/通道都还不存在。如果那次调用把
  // `destroying_` 一置到底不复位，之后**每一次通道调用都会被判成"窗口正在销毁"**
  // ——这就是"点投流立刻提示'创建原生解码器失败：窗口正在销毁'、窗口却活得好好的"
  // 那个 bug（见 AGENTS.md §12.4）。这里清一次既是修根因，也是给
  // "同进程内销毁后重建窗口"留的安全网。
  if (destroying_.exchange(false)) {
    DebugLog("OnCreate：已清除 Create 前置清理遗留的 destroying_ 标记");
  }

  // **第一行就把日志系统立起来**：这是整条链路上最早能落盘的日志。
  //
  // 为什么这么靠前（用户明确要求）：上一轮排查时"日志文件从来没被创建过"，
  // 而当时的两版二进制里其实**根本没有**这些日志调用（已用 dumpbin 逐条核对），
  // 所以"没有日志"并不能说明崩溃点靠前。现在改成：只要窗口走到这一步，盘上
  // 一定有 `模块已加载`；下次运行就能一刀切开
  //   「连 module loaded 都没有」= exe 根本没跑到这里
  //   「有 module loaded 但没有 create 入口」= 崩在 Dart 侧或通道派发前
  //   「有 create 入口但没有首帧」= 崩在解码器内部
  ws_scrcpy::InitializeLog(kModuleName);
  const std::string log_path = ws_scrcpy::LogFilePath();
  DebugLog("模块已加载（FlutterWindow::OnCreate 入口）：日志文件=" +
           (log_path.empty() ? std::string("<无，仅 stderr/调试器>") : log_path));

  if (!Win32Window::OnCreate()) {
    DebugLog("Win32Window::OnCreate 失败，窗口不创建");
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 原生投流解码通道：Dart 侧只做平台分支判断，实现全在这里。
  //
  // 注册顺序有讲究：**先装 handler，最后再挂 SetNextFrameCallback**。
  // 原因见 AGENTS.md §12：`SetNextFrameCallback` 的回调是引擎持有的
  // `std::function<void()>`，它一旦被回调就会 `self->next_frame_callback_ = nullptr`；
  // 排到最后可以把"回调触发"和"通道还没就绪"这两件事彻底解耦。
  DebugLog("阶段：开始注册 ws_scrcpy/video 通道方法");
  const long long channel_begin_ms = NowMs();
  video_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kVideoChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  video_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleVideoMethodCall(call, std::move(result)); });
  DebugLog("阶段：ws_scrcpy/video 已注册（create / pushFrame / release / getSize），耗时 " +
           std::to_string(NowMs() - channel_begin_ms) + "ms");
  channel_registered_ = true;
  channel_register_ms_ = NowMs() - channel_begin_ms;

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // `Win32Window::Create()` 的第一句是 `Destroy()`（模板行为：确保窗口尚未创建），
  // 所以窗口**真正创建之前**这里会被调用一次。那次"收尾"没有任何东西可收，
  // 必须在**不动 destroying_** 的前提下直接返回：
  // 它既不能留下"已销毁"的假象（原来会打一句"引擎已销毁"，而引擎那时根本不存在，
  // 排查时误导了整整一轮），也不能把 `destroying_` 一置到底（那会让之后所有通道
  // 调用都被判成"窗口正在销毁"，见 AGENTS.md §12.4）。
  const bool has_anything_to_teardown = flutter_controller_ != nullptr ||
                                        video_decoder_ != nullptr ||
                                        video_channel_ != nullptr;
  if (!has_anything_to_teardown) {
    DebugLog("OnDestroy：窗口尚未完成创建（Create 的前置清理），无收尾动作");
    Win32Window::OnDestroy();
    return;
  }

  // 顺序很关键：
  // 1) 先置 destroying_ 标记——handler 之后一律短路（捕获的是 this，窗口正在析构）；
  // 2) 再停解码线程并注销纹理；
  // 3) 然后显式摘掉通道 handler（**没有**待执行的投递任务了：尺寸改由 Dart 拉取）；
  // 4) 最后才销毁 controller（引擎）。
  destroying_.store(true);
  DebugLog("OnDestroy：开始收尾（停解码线程 + 注销纹理 → 摘通道 handler → 销毁引擎）");
  if (video_decoder_) {
    video_decoder_->Release();
    video_decoder_.reset();
  }
  DebugLog("OnDestroy：解码器已释放、纹理已请求注销");
  if (video_channel_) {
    // 显式摘掉 handler：API 文档明确要求"handler 不再有效时由调用方自己摘"
    // （method_channel.h 的注释）。留着它等引擎析构才清，等于让一个捕获 `this`
    // 的 std::function 活过窗口。
    if (channel_registered_) {
      video_channel_->SetMethodCallHandler(nullptr);
      channel_registered_ = false;
      DebugLog("OnDestroy：通道 handler 已摘掉");
    }
    video_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  DebugLog("OnDestroy：引擎已销毁（收尾完成）");

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleVideoMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (destroying_.load()) {
    // 窗口已在析构：绝不再碰 video_decoder_ / flutter_controller_。
    // 这条日志只写一次，避免关窗瞬间刷屏。
    LogOnce("call-after-destroy", "窗口销毁后仍收到通道调用（已安全忽略）");
    result->Error("window_destroyed", "窗口正在销毁");
    return;
  }
  if (flutter_controller_ == nullptr) {
    // 与"正在销毁"区分开：窗口还没建好（引擎尚未创建）。
    // 这两种情况原来共用一句"窗口正在销毁"，把一次排查带偏了整整一轮，
    // 所以错误码与文案都必须能区分（见 AGENTS.md §12.4）。
    LogOnce("call-before-create", "窗口尚未就绪（引擎未创建）就收到通道调用（已拒绝）");
    result->Error("window_not_ready", "窗口尚未就绪（引擎未创建），请稍后重试");
    return;
  }
  const std::string& method = call.method_name();

  if (method == "create") {
    const long long create_begin_ms = NowMs();
    DebugLog("通道入口：create");
    flutter::FlutterEngine* engine =
        flutter_controller_ ? flutter_controller_->engine() : nullptr;
    flutter::TextureRegistrar* texture_registrar = TextureRegistrarFor(engine);
    if (texture_registrar == nullptr) {
      result->Error("decoder_unavailable", "拿不到 Flutter 纹理注册器");
      return;
    }
    // 重复 create（Dart 侧的重试入口）：先把上一个干净地释放掉，避免纹理泄漏。
    if (video_decoder_) {
      video_decoder_->Release();
      video_decoder_.reset();
    }
    DebugLog("create：texture_registrar 就绪，准备创建解码器");
    // 通道层测出来的两步耗时（注册通道方法 / 注册纹理）一并带下去，
    // 由解码线程在启动时统一打一条阶段汇总。
    ws_scrcpy::DecoderStartupTimings startup;
    startup.register_channel_ms = channel_register_ms_;
    // 引擎渲染适配器：GPU 呈现路能不能开就看这一条（见 QueryEngineRenderingAdapter）。
    const ws_scrcpy::EngineRenderingAdapter engine_adapter =
        QueryEngineRenderingAdapter(engine);
    video_decoder_ = std::make_unique<ScrcpyVideoDecoder>(texture_registrar,
                                                          startup,
                                                          engine_adapter);
    const int64_t texture_id = video_decoder_->Start();
    startup.register_texture_ms = NowMs() - create_begin_ms;
    if (texture_id < 0) {
      const std::string message = video_decoder_->LastError();
      video_decoder_.reset();
      result->Error("decoder_create_failed",
                    message.empty() ? "创建原生 H.264 解码器失败" : message);
      return;
    }
    const ws_scrcpy::DecoderSize size = CurrentDecoderSize();
    DebugLog("create 完成：textureId=" + std::to_string(texture_id) + "，尺寸 " +
             std::to_string(size.width) + "x" + std::to_string(size.height) +
             "，耗时 " + std::to_string(NowMs() - create_begin_ms) + "ms");
    // 回执里带上尺寸，Dart 侧不用再单独问一次。
    flutter::EncodableMap payload = SizePayload(size);
    payload[flutter::EncodableValue("textureId")] =
        flutter::EncodableValue(texture_id);
    result->Success(flutter::EncodableValue(payload));
    return;
  }

  if (method == "pushFrame") {
    // Windows 上 Uint8List 解码成 std::vector<uint8_t>。
    const auto* bytes = std::get_if<std::vector<uint8_t>>(call.arguments());
    if (bytes == nullptr) {
      result->Error("bad_arguments", "pushFrame 需要一个 Uint8List");
      return;
    }
    if (!video_decoder_) {
      result->Error("decoder_not_ready", "解码器尚未创建");
      return;
    }
    // 只入队不等待：解码/色彩转换都在解码线程上做，platform thread 不做重活。
    video_decoder_->PushFrame(bytes->data(), bytes->size());
    // 入口日志按节流写：每 30 帧一条，既能证明"帧确实到了平台通道"，
    // 又不会把 2 MB 的日志文件在几秒内写满（30fps 下约每秒一条）。
    static std::atomic<uint64_t> push_count{0};
    const uint64_t index = push_count.fetch_add(1) + 1;
    if (index == 1 || index % 30 == 0) {
      DebugLog("通道入口：pushFrame 第 " + std::to_string(index) + " 帧，长度 " +
               std::to_string(bytes->size()) + " 字节");
    }
    // **回执**带上当前尺寸：解码线程改了尺寸也不用"反向通知"（那正是崩溃来源），
    // Dart 侧在喂帧的回执里顺手拿到最新值。
    const ws_scrcpy::DecoderSize size = CurrentDecoderSize();
    result->Success(flutter::EncodableValue(SizePayload(size)));
    return;
  }

  if (method == "getSize") {
    DebugLog("通道入口：getSize");
    // Dart 主动拉取（例如重建解码器之后、或 UI 需要立刻知道尺寸时）。
    // 即使解码器还没创建也返回 0x0，让 Dart 侧保留它已有的尺寸，不要清空 UI。
    result->Success(flutter::EncodableValue(SizePayload(CurrentDecoderSize())));
    return;
  }

  if (method == "release") {
    DebugLog("通道入口：release");
    if (video_decoder_) {
      video_decoder_->Release();
      video_decoder_.reset();
    }
    DebugLog("release 完成：解码器与纹理已释放（可重复调用）");
    result->Success();
    return;
  }

  DebugLog("通道入口：未实现的方法 " + method);
  result->NotImplemented();
}

ws_scrcpy::DecoderSize FlutterWindow::CurrentDecoderSize() const {
  if (!video_decoder_) {
    return ws_scrcpy::DecoderSize{};
  }
  // 纯拉取：解码器内部加锁，platform thread 直接读，没有任何跨线程投递。
  return video_decoder_->CurrentSize();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
