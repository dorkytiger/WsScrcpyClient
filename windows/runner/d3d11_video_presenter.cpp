#include "d3d11_video_presenter.h"

#include "decoder_log.h"
#include "yuv_to_rgba.h"

// windows.h 默认定义 min/max 宏，会把 std::min 打坏（runner 的 CMake 里有 NOMINMAX，
// 但本文件也要能被独立编译的自测（tools/d3d11_present_test.cpp）直接用，所以在这里也定义）。
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <d3d11.h>
#include <dxgi.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

// DXBC 字节码由 tools\build_shader.cmd 用 fxc 离线编译（改着色器后必须重跑）。
// 为什么不用运行期 D3DCompile：不给运行期加 d3dcompiler_47.dll 依赖，也不在 create
// 阶段花几十毫秒编译；产物进仓库，可 diff、可复查。
#include "shaders/generated/ps_nv12_to_bgra.h"
#include "shaders/generated/vs_nv12_to_bgra.h"

using Microsoft::WRL::ComPtr;

namespace ws_scrcpy {
namespace {

// 日志前缀（模块名由 decoder_log 统一持有，这里只加自己的标识，避免动全局状态）。
constexpr char kTag[] = "GPU 呈现：";

// keyed mutex 的等待上限：取不到就丢这一帧，绝不能把解码线程堵在这里。
constexpr DWORD kAcquireTimeoutMs = 100;

// 换尺寸后保留的旧纹理数：引擎"打开句柄"可能晚于下一次回调，旧句柄在打开前必须有效
// （flutter_texture_registrar.h 的明确要求）。保留几张的开销可忽略，换尺寸也很少发生。
constexpr size_t kMaxRetiredTextures = 3;

constexpr UINT kShaderResourceCount = 2;  // t0=Y、t1=UV
constexpr UINT kFullscreenVertexCount = 3;

// 小写化的环境变量值；不存在时返回空串。
std::string EnvString(const char* name) {
  char buffer[32] = {};
  const DWORD length = ::GetEnvironmentVariableA(name, buffer,
                                                 static_cast<DWORD>(sizeof(buffer)));
  if (length == 0 || length >= sizeof(buffer)) {
    return {};
  }
  std::string value(buffer, length);
  for (char& character : value) {
    if (character >= 'A' && character <= 'Z') {
      character = static_cast<char>(character - 'A' + 'a');
    }
  }
  return value;
}

// 小写化（适配器名子串匹配用；环境变量的值在 EnvString 里已经小写化）。
std::string ToLower(std::string text) {
  for (char& character : text) {
    if (character >= 'A' && character <= 'Z') {
      character = static_cast<char>(character - 'A' + 'a');
    }
  }
  return text;
}

// 三态解析。**默认是 kForceOff（CPU 路）**：GPU 路在 2026-10-08 那次"同适配器 + 引擎正常取帧
// 也照样全黑"之后，必须先在屏幕上见过画面才敢当默认（`已发布 N 帧` ≠ 上屏，§12.8 教训①）。
//   WS_SCRCPY_GPU 未设 / =0  → kForceOff（默认，CPU 像素缓冲）
//   WS_SCRCPY_GPU=auto       → kAuto（只在能证明与引擎同适配器时才建 GPU 路）
//   WS_SCRCPY_GPU=1          → kForceOn（强制；跨适配器也可建）
// 不认识的值一律按 kForceOff（稳妥优先）。
PresenterOptions::Mode ModeFromEnvironment(const char* name) {
  const std::string value = EnvString(name);
  if (value == "auto") {
    return PresenterOptions::Mode::kAuto;
  }
  if (value == "1" || value == "on" || value == "true" || value == "yes") {
    return PresenterOptions::Mode::kForceOn;
  }
  return PresenterOptions::Mode::kForceOff;
}

std::string Utf8FromWide(const wchar_t* text) {
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

std::string HresultText(HRESULT result) {
  char buffer[16] = {};
  std::snprintf(buffer, sizeof(buffer), "0x%08lX",
                static_cast<unsigned long>(result));
  return buffer;
}

std::string HandleText(uint64_t handle) {
  char buffer[32] = {};
  std::snprintf(buffer, sizeof(buffer), "0x%llX",
                static_cast<unsigned long long>(handle));
  return buffer;
}

}  // namespace

PresenterOptions PresenterOptions::FromEnvironment() {
  PresenterOptions options;
  // **默认 kForceOff（CPU 路）**：GPU 共享纹理路有一次"同适配器、引擎也在正常取帧、
  // 但屏幕全黑"的记录（2026-10-08，证据见 AGENTS.md §12.8 的 2026-10-08 小节），
  // 所以它退回到"要显式要才建"的地位：
  //   WS_SCRCPY_GPU=0/未设 → CPU 像素缓冲（默认，已知可靠）
  //   WS_SCRCPY_GPU=auto    → 能证明"与引擎同一块适配器"时才建（LUID 比对）
  //   WS_SCRCPY_GPU=1       → 强制建（排障/A-B 用）
  // 这样"屏幕上有没有画面"这件事不会因为一次没验过的优化而回退。
  options.mode = ModeFromEnvironment("WS_SCRCPY_GPU");
  // 默认按 ANGLE 共享句柄路径的约定用 keyed mutex；WS_SCRCPY_GPU_SYNC=none 关掉它。
  const std::string sync = EnvString("WS_SCRCPY_GPU_SYNC");
  options.keyed_mutex = sync != "none" && sync != "off" && sync != "false" &&
                        sync != "0";
  const std::string handle = EnvString("WS_SCRCPY_GPU_HANDLE");
  options.nth_handle = handle == "nth" || handle == "nthandle" ||
                       handle == "create";
  // 选适配器（双显卡笔记本上决定"能不能上屏"）：默认 auto = 先按引擎适配器匹配。
  const std::string adapter = EnvString("WS_SCRCPY_GPU_ADAPTER");
  options.adapter_hint = adapter.empty() ? "auto" : adapter;
  return options;
}

class D3d11VideoPresenter::Impl {
 public:
  ~Impl() { Release(); }

  bool Create(uint32_t width, uint32_t height,
              const PresenterOptions& options);
  bool Resize(uint32_t width, uint32_t height);
  bool PublishNv12(const Nv12Frame& frame);
  void Release();

  const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor();

  bool ready() const { return ready_.load(); }
  // 尺寸类访问器都从快照读（加锁）：它们会被别的线程（日志/自测）调用，
  // 不能直接读只有解码线程改的那几个成员。
  uint32_t physical_width() const { return snapshot_copy().physical_w; }
  uint32_t physical_height() const { return snapshot_copy().physical_h; }
  uint32_t visible_width() const { return snapshot_copy().visible_w; }
  uint32_t visible_height() const { return snapshot_copy().visible_h; }
  std::string device_name() const { return device_name_; }
  bool engine_adapter_matched() const { return engine_matched_; }
  std::string engine_adapter_name() const { return engine_adapter_name_; }
  uint64_t device_adapter_luid() const { return device_luid_; }
  uint64_t present_latency_samples() const { return latency_.samples(); }
  uint64_t present_latency_sum_us() const { return latency_.sum_us(); }
  std::string LastError() const;
  bool keyed_mutex_enabled() const { return options_.keyed_mutex; }
  bool nth_handle_enabled() const { return options_.nth_handle; }
  uint64_t shared_handle_value() const;
  uint64_t descriptor_callbacks() const { return descriptor_callbacks_.load(); }
  bool ReadbackForTest(std::vector<uint8_t>* out);
  std::string FirstFrameContentReport();

 private:
  // 给光栅线程读的一份快照：只有句柄与尺寸，不暴露任何 D3D11 对象。
  struct Snapshot {
    HANDLE handle = nullptr;
    uint32_t physical_w = 0;
    uint32_t physical_h = 0;
    uint32_t visible_w = 0;
    uint32_t visible_h = 0;
    bool ready = false;
  };

  bool CreateDevice(std::string* error);
  bool CreateShaders(std::string* error);
  bool CreateTextures(uint32_t width, uint32_t height, std::string* error);
  void Draw();
  void RetireCurrentTexture();
  void ReleaseDeviceObjects();
  void SetError(const std::string& message);

  /// 取一份加锁的快照（供不持有 render_mutex_ 的调用者读尺寸/句柄）。
  Snapshot snapshot_copy() const {
    std::lock_guard<std::mutex> lock(descriptor_mutex_);
    return snapshot_;
  }

  // 串行化 Create/Resize/Publish/Release（都在解码线程上；D3D11 即时上下文非线程安全）。
  // mutable：LastError() 之类的 const 查询也要能取锁。
  mutable std::mutex render_mutex_;
  // 只保护给光栅线程看的那份快照，与 render_mutex_ 不嵌套获取（避免光栅线程被 D3D 慢操作拖住）。
  mutable std::mutex descriptor_mutex_;

  ComPtr<ID3D11Device> device_;
  ComPtr<ID3D11DeviceContext> context_;
  ComPtr<ID3D11VertexShader> vertex_shader_;
  ComPtr<ID3D11PixelShader> pixel_shader_;
  ComPtr<ID3D11Texture2D> nv12_texture_;
  ComPtr<ID3D11ShaderResourceView> y_view_;
  ComPtr<ID3D11ShaderResourceView> uv_view_;
  ComPtr<ID3D11Texture2D> output_texture_;
  ComPtr<ID3D11RenderTargetView> output_render_target_;
  ComPtr<IDXGIKeyedMutex> keyed_mutex_;
  ComPtr<ID3D11Texture2D> staging_texture_;  // 仅自测用

  std::vector<uint8_t> packed_;
  // 旧纹理 + 旧句柄：引擎还没打开就被释放的话，句柄会失效。
  std::vector<std::pair<ComPtr<ID3D11Texture2D>, HANDLE>> retired_;

  Snapshot snapshot_;
  PresenterOptions options_;
  std::atomic<bool> ready_{false};
  std::atomic<uint64_t> descriptor_callbacks_{0};  // 引擎来取描述符的次数
  uint32_t physical_width_ = 0;
  uint32_t physical_height_ = 0;
  uint32_t visible_width_ = 0;
  uint32_t visible_height_ = 0;
  std::string device_name_;
  // 我们实际用的适配器 LUID 与"是否就是引擎那块"：kAuto 的决策依据，也是黑屏时
  // 第一个要看的两个字段（见 PresenterOptions::Mode 的注释）。
  uint64_t device_luid_ = 0;
  bool engine_matched_ = false;
  std::string engine_adapter_name_;
  // "发布 → 引擎取走"的延迟（与 CPU 像素缓冲路共用同一份实现，见 present_latency.h）。
  PresentLatencyMeter latency_;
  std::string last_error_;
};

bool D3d11VideoPresenter::Impl::Create(uint32_t width, uint32_t height,
                                       const PresenterOptions& options) {
  std::lock_guard<std::mutex> lock(render_mutex_);
  if (ready_.load()) {
    return true;
  }
  options_ = options;
  std::string error;
  if (!CreateDevice(&error)) {
    SetError(error);
    return false;
  }
  if (!CreateShaders(&error)) {
    SetError(error);
    return false;
  }
  if (!CreateTextures(width, height, &error)) {
    SetError(error);
    return false;
  }
  ready_.store(true);
  DebugLog(std::string(kTag) + "初始化完成：适配器=" +
           (device_name_.empty() ? std::string("<未知>") : device_name_) +
           "（LUID " + HandleText(device_luid_) + "，引擎匹配=" +
           (engine_matched_ ? "是" : "否") + "），物理尺寸=" +
           std::to_string(physical_width_) + "x" +
           std::to_string(physical_height_) + "，可见尺寸=" +
           std::to_string(visible_width_) + "x" +
           std::to_string(visible_height_) + "，共享句柄=" +
           HandleText(shared_handle_value()) + "，同步=" + (options_.keyed_mutex ? "keyed-mutex(key 0)" : "无") +
           "，句柄类型=" + (options_.nth_handle ? "NTHANDLE" : "传统 GetSharedHandle"));
  // 这条是"GPU 路到底走没走通"的**验收锚点**（与 AGENTS.md §12.8 的判据对齐）：
  //   - 引擎匹配=是 + 之后心跳里 已发布 ≈ 光栅回调 → 这才算"同适配器共享纹理可用"；
  //   - 匹配=否（只有 WS_SCRCPY_GPU=1 才会走到）→ 真机大概率全黑，别急着当成功。
  if (!engine_matched_) {
    DebugLog(std::string(kTag) +
             "WARNING 本次是**强制** GPU 路，但两边不在同一块适配器上："
             "传统 DXGI 共享句柄不能跨适配器打开（实测同适配器 3/3、跨适配器 0/6），"
             "引擎侧多半拿不到纹理 → 画面可能全黑（AGENTS §12.8 真机第三次）。"
             "要回稳妥路线请去掉 WS_SCRCPY_GPU=1。");
  }
  return true;
}

bool D3d11VideoPresenter::Impl::CreateDevice(std::string* error) {
  // BGRA_SUPPORT 只是一个能力位（渲染目标现在是 RGBA8）；留着不影响，也方便以后换格式。
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  const D3D_FEATURE_LEVEL levels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0};
  D3D_FEATURE_LEVEL obtained = D3D_FEATURE_LEVEL_10_0;

  // ---- 选适配器（双显卡笔记本上这一步决定"能不能上屏"，见头文件注释）----
  //
  // 优先级（2026-10-08 起）：
  //   ① 显式指定（WS_SCRCPY_GPU_ADAPTER=0/1/intel/…）——A/B 与排障用，永远最高优先；
  //   ② **与引擎渲染适配器同一块**（按 LUID 比对）——kAuto 唯一接受的选择；
  //   ③ 核显启发式（旧行为，只在 kForceOn 且 ①② 都没命中时用）；
  //   ④ 第 0 块。
  // ②是这次改动的核心：传统共享句柄只在同适配器可打开，而"引擎在哪块"以前只能猜。
  ComPtr<IDXGIAdapter1> chosen_adapter;
  std::string adapter_list;
  int chosen = -1;
  std::string strategy;
  {
    ComPtr<IDXGIFactory1> factory;
    if (SUCCEEDED(::CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
      std::vector<ComPtr<IDXGIAdapter1>> adapters;
      for (UINT index = 0;; ++index) {
        IDXGIAdapter1* raw_adapter = nullptr;
        if (factory->EnumAdapters1(index, &raw_adapter) != S_OK ||
            raw_adapter == nullptr) {
          break;
        }
        ComPtr<IDXGIAdapter1> adapter;
        adapter.Attach(raw_adapter);
        DXGI_ADAPTER_DESC1 description = {};
        if (SUCCEEDED(adapter->GetDesc1(&description))) {
          if (!adapter_list.empty()) {
            adapter_list += "，";
          }
          adapter_list += "[" + std::to_string(index) + "]" +
                          Utf8FromWide(description.Description) + "(LUID " +
                          HandleText(PresenterOptions::PackLuid(
                              description.AdapterLuid.LowPart,
                              description.AdapterLuid.HighPart)) +
                          ")";
        }
        adapters.push_back(adapter);
      }
      if (!adapters.empty()) {
        const std::string hint = ToLower(options_.adapter_hint);
        if (hint != "auto" && !hint.empty()) {
          // 数字 = 索引；否则按名字子串（intel / amd / nvidia）。
          const bool numeric = hint.find_first_not_of("0123456789") ==
                               std::string::npos;
          if (numeric) {
            const int index = std::atoi(hint.c_str());
            if (index >= 0 && index < static_cast<int>(adapters.size())) {
              chosen = index;
              strategy = "显式索引(" + options_.adapter_hint + ")";
            }
          } else {
            for (size_t index = 0; index < adapters.size(); ++index) {
              DXGI_ADAPTER_DESC1 description = {};
              if (SUCCEEDED(adapters[index]->GetDesc1(&description)) &&
                  ToLower(Utf8FromWide(description.Description))
                          .find(hint) != std::string::npos) {
                chosen = static_cast<int>(index);
                strategy = "显式名字(" + options_.adapter_hint + ")";
                break;
              }
            }
          }
          if (chosen < 0) {
            DebugLog(std::string(kTag) + "WS_SCRCPY_GPU_ADAPTER=" +
                     options_.adapter_hint + " 没匹配到适配器，回落到自动选择");
          }
        }
        // ② 引擎适配器（按 LUID 精确比对，不按名字/厂商猜）。
        if (chosen < 0 && options_.have_engine_adapter) {
          for (size_t index = 0; index < adapters.size(); ++index) {
            DXGI_ADAPTER_DESC1 description = {};
            if (FAILED(adapters[index]->GetDesc1(&description))) {
              continue;
            }
            const uint64_t luid =
                PresenterOptions::PackLuid(description.AdapterLuid.LowPart,
                                           description.AdapterLuid.HighPart);
            if (luid == options_.engine_adapter_luid) {
              chosen = static_cast<int>(index);
              engine_matched_ = true;
              engine_adapter_name_ = Utf8FromWide(description.Description);
              strategy = "引擎渲染适配器（LUID 匹配）";
              break;
            }
          }
        }
        // kAuto：证明不了"同适配器"就不建 GPU 路——真机第三次的黑屏就是跨适配器导致的，
        // 而"已发布 N 帧"在那次完全正常，日志上根本看不出问题（AGENTS §12.8 的教训①）。
        if (options_.mode == PresenterOptions::Mode::kAuto && !engine_matched_) {
          *error =
              std::string("auto 模式下无法证明与引擎同一块适配器") +
              (options_.have_engine_adapter ? "（引擎 LUID " +
                                                  HandleText(options_.engine_adapter_luid) +
                                                  " 不在列表里）"
                                            : "（没拿到引擎的渲染适配器）") +
              "，按默认策略回落 CPU 像素缓冲路；要强制用 GPU 路设 WS_SCRCPY_GPU=1";
          DebugLog(std::string(kTag) + "适配器列表：" +
                   (adapter_list.empty() ? std::string("<空>") : adapter_list) +
                   "；" + *error);
          return false;
        }
        if (chosen < 0 && options_.mode == PresenterOptions::Mode::kForceOn) {
          // ③ 核显启发式（旧行为，仅强制模式下的兜底）：混合显卡笔记本上 ANGLE 常常在核显，
          // 而 D3D11CreateDevice(nullptr) 经常给独显 —— 两边错开就是黑屏。
          for (size_t index = 0; index < adapters.size(); ++index) {
            DXGI_ADAPTER_DESC1 description = {};
            if (SUCCEEDED(adapters[index]->GetDesc1(&description)) &&
                (description.VendorId == 0x8086 || description.VendorId == 0x1002 ||
                 description.VendorId == 0x1022)) {
              chosen = static_cast<int>(index);
              strategy = "核显启发式（强制模式兜底）";
              break;
            }
          }
        }
        if (chosen < 0) {
          chosen = 0;  // ④ 没有核显（或枚举信息不全）就用第 0 块
          strategy = "第 0 块（兜底）";
        }
        chosen_adapter = adapters[static_cast<size_t>(chosen)];
        DebugLog(std::string(kTag) + "适配器列表：" +
                 (adapter_list.empty() ? std::string("<空>") : adapter_list) +
                 "；本次选用 [" + std::to_string(chosen) + "]（策略=" + strategy +
                 "，引擎匹配=" + (engine_matched_ ? "是" : "否") + "）");
      }
    }
  }

  HRESULT result = ::D3D11CreateDevice(
      chosen_adapter.Get(),
      chosen_adapter != nullptr ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE,
      nullptr, flags, levels, static_cast<UINT>(ARRAYSIZE(levels)),
      D3D11_SDK_VERSION, &device_, &obtained, &context_);
  if (result == E_INVALIDARG) {
    // 运行期不支持 11_1 时的标准重试（11_1 需要额外的运行期支持）。
    result = ::D3D11CreateDevice(
        chosen_adapter.Get(),
        chosen_adapter != nullptr ? D3D_DRIVER_TYPE_UNKNOWN
                                  : D3D_DRIVER_TYPE_HARDWARE,
        nullptr, flags, levels + 1,
        static_cast<UINT>(ARRAYSIZE(levels) - 1), D3D11_SDK_VERSION, &device_,
        &obtained, &context_);
  }
  if (FAILED(result) || device_ == nullptr || context_ == nullptr) {
    *error = "创建 D3D11 设备失败：" + HresultText(result);
    return false;
  }
  if (obtained < D3D_FEATURE_LEVEL_10_0) {
    *error = "D3D11 特性级别过低（需要 10_0 及以上）";
    return false;
  }

  // 适配器名只用于日志：多显卡机器上能一眼看出用的是哪块 GPU
  // （共享句柄要求两侧在同一适配器上，出问题时这条日志是第一个要看的）。
  //
  // **这里是"引擎匹配"的最终复核**：上面第 ② 步是按 LUID 选的，但显式指定 / 兜底 /
  // 系统回落都可能让我们最后拿到另一块——所以以**设备自己的 LUID** 为准重新判一次。
  // kAuto 下复核不通过就整个放弃 GPU 路（宁可 CPU 忙，也不要一块黑屏）。
  ComPtr<IDXGIDevice> dxgi_device;
  if (SUCCEEDED(device_.As(&dxgi_device))) {
    ComPtr<IDXGIAdapter> adapter;
    if (SUCCEEDED(dxgi_device->GetAdapter(&adapter))) {
      DXGI_ADAPTER_DESC description = {};
      if (SUCCEEDED(adapter->GetDesc(&description))) {
        device_name_ = Utf8FromWide(description.Description);
        device_luid_ = PresenterOptions::PackLuid(description.AdapterLuid.LowPart,
                                                  description.AdapterLuid.HighPart);
      }
    }
  }
  if (options_.have_engine_adapter) {
    engine_matched_ = device_luid_ == options_.engine_adapter_luid;
  } else {
    engine_matched_ = false;
  }
  if (options_.mode == PresenterOptions::Mode::kAuto && !engine_matched_) {
    ReleaseDeviceObjects();
    *error = "auto 模式下建出来的设备不在引擎那块适配器上（本设备 LUID " +
             HandleText(device_luid_) + "，引擎 LUID " +
             HandleText(options_.engine_adapter_luid) +
             "），按默认策略回落 CPU 像素缓冲路；要强制用 GPU 路设 WS_SCRCPY_GPU=1";
    return false;
  }
  DebugLog(std::string(kTag) + "D3D11 设备已创建：适配器=" +
           (device_name_.empty() ? std::string("<未知>") : device_name_) +
           "（LUID " + HandleText(device_luid_) + "），特性级别=" +
           std::to_string(static_cast<int>(obtained)) + "，引擎匹配=" +
           (engine_matched_ ? "是" : "否") +
           (engine_adapter_name_.empty()
                ? std::string()
                : "（引擎那块=" + engine_adapter_name_ + "）"));
  return true;
}

bool D3d11VideoPresenter::Impl::CreateShaders(std::string* error) {
  HRESULT result = device_->CreateVertexShader(
      g_nv12_to_bgra_vs_bytecode, sizeof(g_nv12_to_bgra_vs_bytecode), nullptr,
      &vertex_shader_);
  if (FAILED(result)) {
    *error = "创建顶点着色器失败：" + HresultText(result);
    return false;
  }
  result = device_->CreatePixelShader(g_nv12_to_bgra_ps_bytecode,
                                      sizeof(g_nv12_to_bgra_ps_bytecode), nullptr,
                                      &pixel_shader_);
  if (FAILED(result)) {
    *error = "创建像素着色器失败：" + HresultText(result);
    return false;
  }
  return true;
}

bool D3d11VideoPresenter::Impl::CreateTextures(uint32_t width, uint32_t height,
                                               std::string* error) {
  if (width == 0 || height == 0) {
    *error = "尺寸为 0，无法创建纹理";
    return false;
  }
  // NV12 纹理要求偶数宽高（DXGI 的 4:2:0 格式），真实尺寸可能是奇数（例如 1898x853）：
  // 向上对齐到偶数，真实尺寸通过描述符的 visible_width/visible_height 告诉引擎。
  const uint32_t padded_width = (width + 1) & ~1u;
  const uint32_t padded_height = (height + 1) & ~1u;

  D3D11_TEXTURE2D_DESC nv12_description = {};
  nv12_description.Width = padded_width;
  nv12_description.Height = padded_height;
  nv12_description.MipLevels = 1;
  nv12_description.ArraySize = 1;
  nv12_description.Format = DXGI_FORMAT_NV12;
  nv12_description.SampleDesc.Count = 1;
  nv12_description.Usage = D3D11_USAGE_DEFAULT;
  nv12_description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  HRESULT result = device_->CreateTexture2D(&nv12_description, nullptr,
                                            &nv12_texture_);
  if (FAILED(result)) {
    *error = "创建 NV12 纹理失败：" + HresultText(result);
    return false;
  }

  // NV12 的两个平面视图：Y=R8、UV=R8G8（D3D11 的标准用法，着色器按整型坐标取）。
  D3D11_SHADER_RESOURCE_VIEW_DESC plane_description = {};
  plane_description.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
  plane_description.Texture2D.MostDetailedMip = 0;
  plane_description.Texture2D.MipLevels = 1;
  plane_description.Format = DXGI_FORMAT_R8_UNORM;
  result = device_->CreateShaderResourceView(nv12_texture_.Get(),
                                             &plane_description, &y_view_);
  if (FAILED(result)) {
    *error = "创建 Y 平面视图失败：" + HresultText(result);
    return false;
  }
  plane_description.Format = DXGI_FORMAT_R8G8_UNORM;
  result = device_->CreateShaderResourceView(nv12_texture_.Get(),
                                             &plane_description, &uv_view_);
  if (FAILED(result)) {
    *error = "创建 UV 平面视图失败：" + HresultText(result);
    return false;
  }

  // 共享输出纹理：GPU 写、引擎读。MiscFlags 按"同步方式 × 句柄类型"组合
  // （SHARED 与 SHARED_NTHANDLE 互斥，不能同时设）。
  //
  // **格式必须用 R8G8B8A8_UNORM（RGBA8888），不能用 BGRA8888**：真机实测引擎直接拒收——
  //   [ERROR:embedder_external_texture_gl.cc(170)] Could not create external texture->
  //   Only support GL_RGBA8 format now
  // （引擎 DLL 里那两行紧挨着的字符串就是这条检查）。着色器本来就把 (R,G,B,A) 写进
  // SV_Target，所以对 RGBA8 目标而言字节序天然正确，换算数值不需要任何改动。
  D3D11_TEXTURE2D_DESC output_description = {};
  output_description.Width = padded_width;
  output_description.Height = padded_height;
  output_description.MipLevels = 1;
  output_description.ArraySize = 1;
  output_description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  output_description.SampleDesc.Count = 1;
  output_description.Usage = D3D11_USAGE_DEFAULT;
  output_description.BindFlags =
      D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  if (options_.nth_handle) {
    output_description.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
    if (options_.keyed_mutex) {
      output_description.MiscFlags |= D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
    }
  } else if (options_.keyed_mutex) {
    output_description.MiscFlags = D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
  } else {
    output_description.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  }
  result = device_->CreateTexture2D(&output_description, nullptr,
                                    &output_texture_);
  if (FAILED(result)) {
    *error = "创建共享输出纹理失败：" + HresultText(result);
    return false;
  }
  result = device_->CreateRenderTargetView(output_texture_.Get(), nullptr,
                                           &output_render_target_);
  if (FAILED(result)) {
    *error = "创建渲染目标视图失败：" + HresultText(result);
    return false;
  }
  if (options_.keyed_mutex) {
    result = output_texture_.As(&keyed_mutex_);
    if (FAILED(result) || keyed_mutex_ == nullptr) {
      *error = "共享纹理没有 keyed mutex（驱动不支持？）：" + HresultText(result);
      return false;
    }
  }

  HANDLE handle = nullptr;
  if (options_.nth_handle) {
    ComPtr<IDXGIResource1> resource;
    result = output_texture_.As(&resource);
    if (SUCCEEDED(result)) {
      result = resource->CreateSharedHandle(
          nullptr, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
          nullptr, &handle);
    }
  } else {
    ComPtr<IDXGIResource> resource;
    result = output_texture_.As(&resource);
    if (SUCCEEDED(result)) {
      result = resource->GetSharedHandle(&handle);
    }
  }
  if (FAILED(result) || handle == nullptr) {
    *error = "取共享句柄失败：" + HresultText(result) +
             "（可试 WS_SCRCPY_GPU_HANDLE_NTH=1 或 WS_SCRCPY_GPU=0）";
    return false;
  }

  physical_width_ = padded_width;
  physical_height_ = padded_height;
  visible_width_ = width;
  visible_height_ = height;
  packed_.assign(static_cast<size_t>(padded_width) * padded_height * 3 / 2, 0);
  staging_texture_.Reset();
  {
    std::lock_guard<std::mutex> snapshot_lock(descriptor_mutex_);
    snapshot_.handle = handle;
    snapshot_.physical_w = padded_width;
    snapshot_.physical_h = padded_height;
    snapshot_.visible_w = width;
    snapshot_.visible_h = height;
    snapshot_.ready = true;
  }
  return true;
}

bool D3d11VideoPresenter::Impl::Resize(uint32_t width, uint32_t height) {
  std::lock_guard<std::mutex> lock(render_mutex_);
  if (!ready_.load()) {
    return false;
  }
  if (width == visible_width_ && height == visible_height_) {
    return true;
  }
  if (width == 0 || height == 0) {
    SetError("尺寸为 0，忽略本次重建");
    return false;
  }
  const uint32_t previous_physical_width = physical_width_;
  const uint32_t previous_physical_height = physical_height_;
  const uint32_t previous_visible_width = visible_width_;
  const uint32_t previous_visible_height = visible_height_;

  // 旧资源先挂到 retired_：引擎可能还没打开旧句柄（见 kMaxRetiredTextures 注释）。
  RetireCurrentTexture();

  std::string error;
  // 先把新尺寸记下来，CreateTextures 失败时状态仍然自洽（下一次 Resize 会重试）。
  visible_width_ = 0;
  visible_height_ = 0;
  if (!CreateTextures(width, height, &error)) {
    // 回滚到旧尺寸的记录（纹理已失效，下一次 publish 会被尺寸检查挡住并报错）。
    visible_width_ = previous_visible_width;
    visible_height_ = previous_visible_height;
    physical_width_ = previous_physical_width;
    physical_height_ = previous_physical_height;
    SetError(error);
    DebugLog(std::string(kTag) + "重建纹理失败：" + error);
    return false;
  }

  {
    std::lock_guard<std::mutex> snapshot_lock(descriptor_mutex_);
    snapshot_.ready = true;
  }
  DebugLog(std::string(kTag) + "纹理已重建：" + std::to_string(previous_visible_width) +
           "x" + std::to_string(previous_visible_height) + " → " +
           std::to_string(width) + "x" + std::to_string(height) +
           "（物理 " + std::to_string(physical_width_) + "x" +
           std::to_string(physical_height_) + "，新共享句柄=" +
           HandleText(shared_handle_value()) + "）");
  return true;
}

void D3d11VideoPresenter::Impl::RetireCurrentTexture() {
  if (output_texture_ == nullptr) {
    return;
  }
  HANDLE handle = nullptr;
  {
    std::lock_guard<std::mutex> snapshot_lock(descriptor_mutex_);
    handle = snapshot_.handle;
    snapshot_.ready = false;
  }
  // 通过 IDXGIResource 再取一次句柄：snapshot_ 里的那个就是它，但直接复用更省事。
  retired_.emplace_back(output_texture_, handle);
  while (retired_.size() > kMaxRetiredTextures) {
    retired_.erase(retired_.begin());
  }
  output_texture_.Reset();
  output_render_target_.Reset();
  nv12_texture_.Reset();
  y_view_.Reset();
  uv_view_.Reset();
  keyed_mutex_.Reset();
  staging_texture_.Reset();
}

bool D3d11VideoPresenter::Impl::PublishNv12(const Nv12Frame& frame) {
  std::lock_guard<std::mutex> lock(render_mutex_);
  if (!ready_.load() || nv12_texture_ == nullptr || output_texture_ == nullptr) {
    SetError("呈现器尚未就绪");
    return false;
  }
  if (frame.width != visible_width_ || frame.height != visible_height_) {
    SetError("帧尺寸 " + std::to_string(frame.width) + "x" +
             std::to_string(frame.height) + " 与当前纹理 " +
             std::to_string(visible_width_) + "x" +
             std::to_string(visible_height_) + " 不一致（应先 Resize）");
    return false;
  }
  if (!PackNv12(frame, physical_width_, physical_height_, &packed_)) {
    SetError("NV12 重排失败（跨距/长度不符或尺寸非法）");
    return false;
  }

  // 注意：D3D11 的 UpdateSubresource 不吃 D3D11_SUBRESOURCE_DATA，行跨距要单独传。
  // packed_ 的布局就是 D3D11 对 NV12 的约定：physical_width 字节一行，
  // Y 平面 physical_height 行之后紧接 UV 平面 physical_height/2 行。
  context_->UpdateSubresource(nv12_texture_.Get(), 0, nullptr, packed_.data(),
                              static_cast<UINT>(physical_width_), 0);

  bool acquired = false;
  if (keyed_mutex_ != nullptr) {
    const HRESULT result = keyed_mutex_->AcquireSync(0, kAcquireTimeoutMs);
    if (result != S_OK) {
      // 引擎正在读上一帧：这一帧直接丢，绝不等在这里把解码线程拖住。
      last_error_ = "keyed mutex 获取失败：" + HresultText(result);
      return false;
    }
    acquired = true;
  }
  Draw();
  if (acquired) {
    keyed_mutex_->ReleaseSync(0);
  }
  // 一帧真的写进共享纹理了：记一次"发布时刻"，等引擎来取时算延迟
  // （口径与 CPU 像素缓冲路共用，见 present_latency.h）。
  latency_.MarkPublished();
  return true;
}

void D3d11VideoPresenter::Impl::Draw() {
  ID3D11RenderTargetView* render_target = output_render_target_.Get();
  context_->OMSetRenderTargets(1, &render_target, nullptr);
  D3D11_VIEWPORT viewport = {};
  viewport.Width = static_cast<float>(physical_width_);
  viewport.Height = static_cast<float>(physical_height_);
  viewport.MinDepth = 0.0f;
  viewport.MaxDepth = 1.0f;
  context_->RSSetViewports(1, &viewport);
  context_->IASetInputLayout(nullptr);
  context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  context_->VSSetShader(vertex_shader_.Get(), nullptr, 0);
  ID3D11ShaderResourceView* views[kShaderResourceCount] = {y_view_.Get(),
                                                           uv_view_.Get()};
  context_->PSSetShaderResources(0, kShaderResourceCount, views);
  context_->PSSetShader(pixel_shader_.Get(), nullptr, 0);
  context_->Draw(kFullscreenVertexCount, 0);

  // 立刻解绑：下一帧要 UpdateSubresource 写 NV12 纹理，绑着会被驱动告警（内部重命名）。
  ID3D11ShaderResourceView* no_views[kShaderResourceCount] = {nullptr, nullptr};
  context_->PSSetShaderResources(0, kShaderResourceCount, no_views);
  ID3D11RenderTargetView* no_target = nullptr;
  context_->OMSetRenderTargets(1, &no_target, nullptr);
}

void D3d11VideoPresenter::Impl::Release() {
  std::lock_guard<std::mutex> lock(render_mutex_);
  if (!ready_.load() && device_ == nullptr) {
    return;  // 可重复调用
  }
  ready_.store(false);
  {
    std::lock_guard<std::mutex> snapshot_lock(descriptor_mutex_);
    snapshot_ = Snapshot();
  }
  ReleaseDeviceObjects();
  DebugLog(std::string(kTag) + "已释放（设备、纹理、共享句柄）");
}

void D3d11VideoPresenter::Impl::ReleaseDeviceObjects() {
  // 引擎若已打开共享纹理，它自己持有引用，我们释放不会让内存失效（DXGI 计数）。
  retired_.clear();
  staging_texture_.Reset();
  keyed_mutex_.Reset();
  output_render_target_.Reset();
  output_texture_.Reset();
  y_view_.Reset();
  uv_view_.Reset();
  nv12_texture_.Reset();
  pixel_shader_.Reset();
  vertex_shader_.Reset();
  context_.Reset();
  device_.Reset();
  packed_.clear();
  physical_width_ = 0;
  physical_height_ = 0;
  visible_width_ = 0;
  visible_height_ = 0;
  device_luid_ = 0;
  engine_matched_ = false;
  engine_adapter_name_.clear();
  latency_.Reset();
}

const FlutterDesktopGpuSurfaceDescriptor*
D3d11VideoPresenter::Impl::ObtainDescriptor() {
  descriptor_callbacks_.fetch_add(1);
  Snapshot snapshot;
  {
    std::lock_guard<std::mutex> lock(descriptor_mutex_);
    snapshot = snapshot_;
  }
  if (!snapshot.ready || snapshot.handle == nullptr) {
    return nullptr;  // 引擎会跳过这一帧（回调返回空是允许的）
  }
  // 引擎把这一帧取走了：记一次延迟样本（没有新帧的空取不计，见 present_latency.h）。
  latency_.MarkPickedUp();
  // 每次回调一份描述符：引擎打开句柄后会调 release_callback，我们在那里回收。
  struct DescriptorHolder {
    FlutterDesktopGpuSurfaceDescriptor descriptor = {};
  };
  DescriptorHolder* holder = new DescriptorHolder();
  holder->descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  holder->descriptor.handle = snapshot.handle;
  holder->descriptor.width = snapshot.physical_w;
  holder->descriptor.height = snapshot.physical_h;
  holder->descriptor.visible_width = snapshot.visible_w;
  holder->descriptor.visible_height = snapshot.visible_h;
  holder->descriptor.format = kFlutterDesktopPixelFormatRGBA8888;  // 引擎只接受 GL_RGBA8
  holder->descriptor.release_callback = [](void* context) {
    delete static_cast<DescriptorHolder*>(context);
  };
  holder->descriptor.release_context = holder;
  return &holder->descriptor;
}

bool D3d11VideoPresenter::Impl::ReadbackForTest(std::vector<uint8_t>* out) {  if (out == nullptr) {
    return false;
  }
  std::lock_guard<std::mutex> lock(render_mutex_);
  if (!ready_.load() || output_texture_ == nullptr) {
    return false;
  }
  if (staging_texture_ == nullptr) {
    D3D11_TEXTURE2D_DESC description = {};
    output_texture_->GetDesc(&description);
    description.Usage = D3D11_USAGE_STAGING;
    description.BindFlags = 0;
    description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    description.MiscFlags = 0;
    if (FAILED(device_->CreateTexture2D(&description, nullptr,
                                        &staging_texture_))) {
      return false;
    }
  }
  bool acquired = false;
  if (keyed_mutex_ != nullptr) {
    if (keyed_mutex_->AcquireSync(0, kAcquireTimeoutMs) != S_OK) {
      return false;
    }
    acquired = true;
  }
  context_->CopyResource(staging_texture_.Get(), output_texture_.Get());
  if (acquired) {
    keyed_mutex_->ReleaseSync(0);
  }

  D3D11_MAPPED_SUBRESOURCE mapped = {};
  if (FAILED(context_->Map(staging_texture_.Get(), 0, D3D11_MAP_READ, 0,
                           &mapped))) {
    return false;
  }
  const size_t row_bytes = static_cast<size_t>(physical_width_) * 4;
  out->resize(row_bytes * physical_height_);
  for (uint32_t row = 0; row < physical_height_; ++row) {
    std::memcpy(out->data() + static_cast<size_t>(row) * row_bytes,
                static_cast<const uint8_t*>(mapped.pData) +
                    static_cast<size_t>(row) * mapped.RowPitch,
                row_bytes);
  }
  context_->Unmap(staging_texture_.Get(), 0);
  return true;
}

std::string D3d11VideoPresenter::Impl::FirstFrameContentReport() {
  std::vector<uint8_t> pixels;
  if (!ReadbackForTest(&pixels)) {
    return "回读失败（拿不到 staging 纹理 / keyed mutex 超时 / 呈现器未就绪）";
  }
  const size_t row_bytes = static_cast<size_t>(physical_width_) * 4;
  if (row_bytes == 0 || pixels.size() < row_bytes * physical_height_) {
    return "回读缓冲大小不符（物理 " + std::to_string(physical_width_) + "x" +
           std::to_string(physical_height_) + "，实际 " +
           std::to_string(pixels.size()) + " 字节）";
  }
  // 采样：每 16 行取每 16 个像素一个，够判"有没有画面"，也不拖慢首帧。
  uint64_t samples = 0;
  uint64_t non_black = 0;   // 亮度 > 8 的像素
  uint64_t luma_sum = 0;
  for (uint32_t row = 0; row < physical_height_; row += 16) {
    const uint8_t* line = pixels.data() + static_cast<size_t>(row) * row_bytes;
    for (uint32_t column = 0; column < physical_width_; column += 16) {
      const uint8_t* pixel = line + static_cast<size_t>(column) * 4;
      const uint32_t luma = (static_cast<uint32_t>(pixel[0]) + pixel[1] + pixel[2]) / 3;
      ++samples;
      luma_sum += luma;
      if (luma > 8) {
        ++non_black;
      }
    }
  }
  if (samples == 0) {
    return "采样数为 0（尺寸异常）";
  }
  char text[160] = {};
  std::snprintf(text, sizeof(text),
                "非黑像素 %.1f%%，平均亮度 %llu/255（采样 %llu 点，物理 %ux%u）",
                static_cast<double>(non_black) * 100.0 / static_cast<double>(samples),
                static_cast<unsigned long long>(luma_sum / samples),
                static_cast<unsigned long long>(samples), physical_width_,
                physical_height_);
  return text;
}

void D3d11VideoPresenter::Impl::SetError(const std::string& message) {
  last_error_ = message;
}

std::string D3d11VideoPresenter::Impl::LastError() const {
  std::lock_guard<std::mutex> lock(render_mutex_);
  return last_error_;
}

uint64_t D3d11VideoPresenter::Impl::shared_handle_value() const {
  std::lock_guard<std::mutex> lock(descriptor_mutex_);
  return reinterpret_cast<uint64_t>(snapshot_.handle);
}

// ---------------------------------------------------------------------------
// 对外包装：只做转发，实现细节留在 Impl（与 ScrcpyVideoDecoder 的做法一致）。
// ---------------------------------------------------------------------------

D3d11VideoPresenter::D3d11VideoPresenter() : impl_(std::make_unique<Impl>()) {}

D3d11VideoPresenter::~D3d11VideoPresenter() = default;

bool D3d11VideoPresenter::Create(uint32_t width, uint32_t height,
                                 const PresenterOptions& options) {
  return impl_->Create(width, height, options);
}

bool D3d11VideoPresenter::Resize(uint32_t width, uint32_t height) {
  return impl_->Resize(width, height);
}

bool D3d11VideoPresenter::PublishNv12(const Nv12Frame& frame) {
  return impl_->PublishNv12(frame);
}

void D3d11VideoPresenter::Release() { impl_->Release(); }

bool D3d11VideoPresenter::ready() const { return impl_->ready(); }

uint32_t D3d11VideoPresenter::physical_width() const {
  return impl_->physical_width();
}

uint32_t D3d11VideoPresenter::physical_height() const {
  return impl_->physical_height();
}

uint32_t D3d11VideoPresenter::visible_width() const {
  return impl_->visible_width();
}

uint32_t D3d11VideoPresenter::visible_height() const {
  return impl_->visible_height();
}

std::string D3d11VideoPresenter::device_name() const {
  return impl_->device_name();
}

bool D3d11VideoPresenter::engine_adapter_matched() const {
  return impl_->engine_adapter_matched();
}

std::string D3d11VideoPresenter::engine_adapter_name() const {
  return impl_->engine_adapter_name();
}

uint64_t D3d11VideoPresenter::device_adapter_luid() const {
  return impl_->device_adapter_luid();
}

uint64_t D3d11VideoPresenter::present_latency_samples() const {
  return impl_->present_latency_samples();
}

uint64_t D3d11VideoPresenter::present_latency_sum_us() const {
  return impl_->present_latency_sum_us();
}

std::string D3d11VideoPresenter::LastError() const { return impl_->LastError(); }

bool D3d11VideoPresenter::keyed_mutex_enabled() const {
  return impl_->keyed_mutex_enabled();
}

bool D3d11VideoPresenter::nth_handle_enabled() const {
  return impl_->nth_handle_enabled();
}

uint64_t D3d11VideoPresenter::shared_handle_value() const {
  return impl_->shared_handle_value();
}

uint64_t D3d11VideoPresenter::descriptor_callbacks() const {
  return impl_->descriptor_callbacks();
}

const FlutterDesktopGpuSurfaceDescriptor*
D3d11VideoPresenter::ObtainDescriptor() {
  return impl_->ObtainDescriptor();
}

FlutterDesktopGpuSurfaceTextureConfig D3d11VideoPresenter::Config() {
  FlutterDesktopGpuSurfaceTextureConfig config = {};
  config.struct_size = sizeof(FlutterDesktopGpuSurfaceTextureConfig);
  config.type = kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle;
  config.callback = [](size_t width, size_t height, void* user_data) {
    static_cast<void>(width);
    static_cast<void>(height);
    auto* presenter = static_cast<D3d11VideoPresenter*>(user_data);
    return presenter == nullptr ? nullptr : presenter->ObtainDescriptor();
  };
  config.user_data = this;
  return config;
}

bool D3d11VideoPresenter::ReadbackForTest(std::vector<uint8_t>* out) {
  return impl_->ReadbackForTest(out);
}

std::string D3d11VideoPresenter::FirstFrameContentReport() {
  return impl_->FirstFrameContentReport();
}

bool D3d11VideoPresenter::PackNv12(const Nv12Frame& frame,
                                   uint32_t physical_width,
                                   uint32_t physical_height,
                                   std::vector<uint8_t>* out) {
  if (out == nullptr || frame.data == nullptr) {
    return false;
  }
  // D3D11 的 4:2:0 纹理要求偶数宽高（调用方按此对齐）。
  if (physical_width == 0 || physical_height == 0 ||
      (physical_width % 2) != 0 || (physical_height % 2) != 0) {
    return false;
  }
  if (frame.width == 0 || frame.height == 0 ||
      frame.width > physical_width || frame.height > physical_height) {
    return false;
  }
  // 复用换算层那份校验（跨距、平面布局、长度）：不维护第二份业务逻辑。
  const Yuv420SourceInfo info = ValidateYuv420Source(
      Yuv420Layout::kNv12, frame.pitch, frame.width, frame.height,
      frame.data_bytes);
  if (!info.ok) {
    return false;
  }

  out->assign(static_cast<size_t>(physical_width) * physical_height * 3 / 2, 0);
  const size_t y_row_bytes =
      std::min<size_t>(physical_width, static_cast<size_t>(frame.width));
  for (uint32_t row = 0; row < physical_height; ++row) {
    // 物理高度大于真实高度（奇数高）时复制最后一行：多出来的行在可见区域外。
    const uint32_t source_row = std::min(row, frame.height - 1);
    std::memcpy(out->data() + static_cast<size_t>(row) * physical_width,
                frame.data + static_cast<size_t>(source_row) * frame.pitch,
                y_row_bytes);
  }

  // NV12 的 UV 平面紧跟在 Y 平面之后，行跨距同样是 pitch。
  const uint8_t* uv_source =
      frame.data + frame.pitch * static_cast<size_t>(frame.height);
  const size_t chroma_rows = (static_cast<size_t>(frame.height) + 1) / 2;
  // 只复制"格式真正需要"的字节：交错色度一行是 ceil(width/2)*2（偶数宽就是 width，
  // 奇数宽是 width+1）。物理宽多出来的 padding 保持 0 —— 与 Y 平面一致，
  // 免得边缘（缩放/双线性取样）取到源行 padding 的颜色。
  const size_t chroma_row_bytes = std::min<size_t>(
      (static_cast<size_t>(frame.width) + 1) / 2 * 2, physical_width);
  uint8_t* uv_destination =
      out->data() + static_cast<size_t>(physical_width) * physical_height;
  for (uint32_t row = 0; row < physical_height / 2; ++row) {
    const size_t source_row = std::min<size_t>(row, chroma_rows - 1);
    std::memcpy(uv_destination + static_cast<size_t>(row) * physical_width,
                uv_source + source_row * frame.pitch, chroma_row_bytes);
  }
  return true;
}

}  // namespace ws_scrcpy
