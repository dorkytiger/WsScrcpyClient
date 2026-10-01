#include "scrcpy_video_decoder.h"

#include "d3d11_video_presenter.h"
#include "decoder_log.h"
#include "scrcpy_pixel_store.h"
#include "yuv_to_rgba.h"

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wmcodecdsp.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

// 换算实现放在 ws_scrcpy 命名空间里（好让它能被本机自测单独链接）；
// 这里引入到文件作用域，避免每处调用都写前缀。
using ws_scrcpy::ConvertYuv420ToRgba;
using ws_scrcpy::DebugLog;
using ws_scrcpy::LogOnce;
using ws_scrcpy::Yuv420Layout;

// Windows 端原生解码（M2 路线 A，对应 Android 的 ScrcpyVideoDecoder.kt）。
//
// 为什么是这条链路：
// - 协议实测（docs/ws-scrcpy-protocol.md §4.4）：`sendFrameMeta=false` 时**一条 WS 消息 = 一帧
//   Annex-B**（`00 00 00 01` 起始码），SPS/PPS 单独一条先到。Media Foundation 的
//   `MFVideoFormat_H264` 输入类型恰好约定"每个样本一个完整压缩帧"（SDK mfapi.h 注释），
//   所以一消息一样本，不需要自己做流式切分。
// - 解码用系统内置的 H.264 解码器 MFT（`CLSID_CMSH264DecoderMFT`），输出 NV12；
//   再由 CPU 转成 RGBA 塞进 `flutter::PixelBufferTexture`。选 CPU 像素缓冲而不是 D3D11
//   共享纹理，是因为它简单可靠、不涉及设备/纹理生命周期与跨线程同步。
//
// 性能说明（为什么先走 CPU 路线）：每帧要做一次整帧 NV12 → RGBA 换算（1080p 约 200 万像素），
// 加上交给引擎前的一次 memcpy，30fps 下是可观但可接受的 CPU 开销。若以后它成为瓶颈，
// 升级路径是改用 GPU 表面纹理：
//   1) 给解码器 MFT 配 `IMFDXGIDeviceManager`，让它直接输出 D3D11 纹理（MF_MT_D3D11_*）；
//   2) 用 `flutter::GpuSurfaceTexture` + `kFlutterDesktopGpuSurfaceTypeD3d11Texture2D`
//      （或 `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`）把纹理交给引擎，
//      YUV→RGB 交给着色器，连 CPU 换算与 memcpy 一起省掉。
// 那条路要额外处理 D3D 设备丢失、纹理池与跨线程引用计数，风险高得多，本次**不实现**。

namespace {

// 单输入/单输出的解码器 MFT。
constexpr DWORD kInputStreamId = 0;
constexpr DWORD kOutputStreamId = 0;

// 等待解码的帧数上限。
//
// **这是延迟旋钮，不是吞吐旋钮**：队列里每积一帧，画面就晚一帧（30fps 下 33ms）。
// 原来是 60（约 2 秒）：一旦"产能 < 输入"（Windows 的 CPU 像素路实测就是），
// 延迟会一路涨到 2 秒，体感就是"又卡又迟钝"——这也是 Android 不卡而 Windows 卡的
// 第二个独立原因（第一个是像素路本身，见 AGENTS.md §12.8）。
// 现在收到 4 帧（约 130ms）：仍然吸收得住抖动与瞬时卡顿，但延迟有界。
// 丢帧策略没变（本来就是丢最旧的帧，靠下一个 IDR 重新同步），只是上限更小。
constexpr size_t kMaxPendingFrames = 4;

// 真实分辨率未知前的占位尺寸：纹理必须先给出一个可用大小（与 Android 的 1280x720 一致）。
constexpr uint32_t kInitialWidth = 1280;
constexpr uint32_t kInitialHeight = 720;

// 只用于给解码器一个单调时间戳（不参与显示时序：画面到了就画）。
constexpr LONGLONG kFrameDurationHns = 333333;  // 33.3ms

// 等解码线程把 COM / Media Foundation / 解码器 MFT 建起来的上限。
// 超时按失败处理，绝不无限期卡住 platform thread。
constexpr auto kInitTimeout = std::chrono::seconds(5);

// 喂够这么多帧还没协商出输出类型，就改用"把 SPS/PPS 写进输入类型"的兜底路径
// （约 0.4 秒 @30fps；正常情况下在第一帧 SPS/PPS 之后就已经协商好了）。
constexpr uint32_t kOutputTypeNegotiationFrames = 12;

// 前 N 帧做一次 NAL 类型诊断（一次性汇总，不刷屏）。
//
// 为什么需要它：scrcpy 的解码器**没有关键帧（IDR）就不会产出任何画面**，而且
// 这种情况下 ProcessInput/ProcessOutput 都不报错（一直 NEED_MORE_INPUT），
// 现象是"零错误但零输出"。以前日志里根本看不出"流里到底有没有 IDR"，
// 于是只能靠猜——所以这里把前 N 帧的 NAL 类型一次性统计出来（见 AGENTS §12.7）。
constexpr uint32_t kNalDiagnosticFrames = 40;

// 喂够这么多帧仍一帧都没解出来 → 打一条明确警告（同时带上 NAL 统计）。
// 取 90：1898x853@30fps 也就 3 秒，足够排除"首帧还在等 IDR"的正常情况。
constexpr uint32_t kNoOutputFramesBeforeWarning = 90;

// 每帧最多记录多少个 NAL 类型（够看清"只有切片没有参数集/关键帧"这类问题）。
constexpr size_t kMaxReportedNalTypes = 8;

// 连续这么多次 ProcessOutput 失败，就判定"当前输出类型与码流不符"并**强制重新协商**
// （FLUSH → 重写 SPS/PPS 到输入类型 → 重选输出类型）。
//
// 为什么需要它：输出类型是"协商"出来的，理论上可能与真实码流不一致（实测踩到过
// 默认 1920x1080 vs 真实 1280x720）。有了这条自愈路径，即使第一次协商选错，
// 解码器也能恢复，而不是像 0x80004005 那次一样一辈子卡在"一帧都解不出来"。
constexpr uint32_t kConsecutiveOutputFailuresBeforeRenegotiate = 5;

// ---------------------------------------------------------------------------
// 心跳 / 看门狗参数（**要调就调这里**，AGENTS.md §12 也指向这几个常量）。
//
// 用户的诉求原话是"要监控时间，不然卡死都不知道"：只打"第一帧解出"这类一次性日志
// 是不够的——卡死时日志里最后一条永远停在那，看不出"停了多久"。所以解码线程每秒
// 固定写一条心跳（含距上一帧的毫秒数），并在明显异常时升级成 WARNING。
// ---------------------------------------------------------------------------

// 心跳间隔：约 1 秒一条。
constexpr auto kHeartbeatInterval = std::chrono::seconds(1);

// 警告阈值一：距上一帧超过 5 秒（解码线程还活着但没产出）。
//
// 取 5 秒而不是 3 秒：scrcpy **只在画面变化时发帧**，静止时"没有帧"是完全正常的，
// 3 秒就开始喊 WARNING，用户点完按钮看到的第一条就是"服务端没给帧"，像个报错（真被问过）。
// 现在措辞也把"画面无变化（正常）"放在最前面。
constexpr long long kHeartbeatStallWarningMs = 5000;

// 警告阈值二：单帧（喂入 → 解出 → 换算 → 发布）超过 1 秒（典型是被抢占或解码器卡住）。
constexpr long long kHeartbeatSlowDecodeWarningMs = 1000;

// 心跳里"最近 N 帧平均解码耗时"的 N。
constexpr size_t kHeartbeatTimingWindow = 60;

// 警告日志的最小间隔：异常持续时避免每秒刷同样的警告。
constexpr long long kWarningRepeatMs = 2000;

// 抓帧上限：约 1 分钟 @30fps，足够离线复现，又不会让长会话把盘写满。
constexpr uint64_t kMaxCaptureFrames = 1800;

// 模块名（日志前缀里用；同时是 InitializeLog 的幂等入口）。
constexpr char kModuleName[] = "ScrcpyVideoDecoder";

std::string HresultText(HRESULT result) {
  char buffer[16] = {};
  std::snprintf(buffer, sizeof(buffer), "0x%08lX",
                static_cast<unsigned long>(result));
  return buffer;
}

// 相对模块首次写日志的毫秒数（初始化之前是 -1，日志里照原样显示）。
long long NowMs() { return ws_scrcpy::LogElapsedMs(); }

// 极简 COM 智能指针。
//
// 为什么不直接用 WRL(`wrl/client.h`)：本项目 runner 开着 `/W4 /WX`，为一个 .cpp
// 引入一套第三方头（WRL / C++/WinRT）会带来不可控的告警风险；这里用到的东西很少，
// 自己实现 20 行更稳。约定：只通过 `Attach` 接管已加过引用的裸指针。
template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  ~ComPtr() { Reset(); }

  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;

  ComPtr(ComPtr&& other) noexcept : pointer_(other.pointer_) {
    other.pointer_ = nullptr;
  }

  ComPtr& operator=(ComPtr&& other) noexcept {
    if (this != &other) {
      Reset();
      pointer_ = other.pointer_;
      other.pointer_ = nullptr;
    }
    return *this;
  }

  T* Get() const { return pointer_; }
  T* operator->() const { return pointer_; }
  explicit operator bool() const { return pointer_ != nullptr; }

  void Attach(T* pointer) {
    Reset();
    pointer_ = pointer;
  }

  void Reset() {
    if (pointer_ != nullptr) {
      pointer_->Release();
      pointer_ = nullptr;
    }
  }

 private:
  T* pointer_ = nullptr;
};

// 一帧 Annex-B 里扫出来的信息。
struct NalScan {
  bool has_vcl = false;          // 是否含图像数据（1 = 非 IDR 片、5 = IDR 片）
  bool has_idr = false;          // 是否含 IDR 片（type 5）——**没有它解码器不会出画面**
  bool has_sps = false;          // 是否含 SPS（type 7）
  bool has_pps = false;          // 是否含 PPS（type 8）
  bool has_sei = false;          // 是否含 SEI（type 6）
  int vcl_count = 0;             // 本条消息里的图像片数量
  // 按出现顺序记录的 NAL 类型（最多 kMaxReportedNalTypes 个），用于诊断打印。
  std::vector<uint8_t> types;
  std::vector<uint8_t> sps_pps;  // 抽出来的 SPS(7)/PPS(8)，各自带起始码
};

// 一个 NAL 单元在帧缓冲里的位置（offset 指向起始码本身）。
struct NalUnit {
  uint8_t type = 0;
  size_t offset = 0;
  size_t size = 0;
};

// 按起始码切分 NAL。
//
// 只认 4 字节起始码也够用（scrcpy 实测都是 `00 00 00 01`），但顺手支持 3 字节形式；
// 载荷里不可能出现 `00 00 00 01`（H.264 的防竞争字节规则），所以这样切是安全的。
std::vector<NalUnit> SplitAnnexB(const uint8_t* data, size_t size) {
  std::vector<NalUnit> units;
  if (data == nullptr) {
    return units;
  }
  size_t index = 0;
  size_t unit_start = 0;
  size_t unit_header = 0;
  bool in_unit = false;
  while (index < size) {
    size_t start_code_length = 0;
    if (index + 4 <= size && data[index] == 0 && data[index + 1] == 0 &&
        data[index + 2] == 0 && data[index + 3] == 1) {
      start_code_length = 4;
    } else if (index + 3 <= size && data[index] == 0 &&
               data[index + 1] == 0 && data[index + 2] == 1) {
      start_code_length = 3;
    }
    if (start_code_length == 0) {
      ++index;
      continue;
    }
    if (in_unit) {
      units.push_back(NalUnit{static_cast<uint8_t>(data[unit_header] & 0x1F),
                             unit_start, index - unit_start});
    }
    unit_start = index;
    unit_header = index + start_code_length;
    in_unit = unit_header < size;
    index += start_code_length;
  }
  if (in_unit) {
    units.push_back(
        NalUnit{static_cast<uint8_t>(data[unit_header] & 0x1F), unit_start,
                size - unit_start});
  }
  return units;
}

NalScan ScanAnnexB(const std::vector<uint8_t>& frame) {
  NalScan scan;
  for (const NalUnit& unit : SplitAnnexB(frame.data(), frame.size())) {
    if (scan.types.size() < kMaxReportedNalTypes) {
      scan.types.push_back(unit.type);
    }
    switch (unit.type) {
      case 1:
        scan.has_vcl = true;
        ++scan.vcl_count;
        break;
      case 5:
        scan.has_vcl = true;
        scan.has_idr = true;
        ++scan.vcl_count;
        break;
      case 6:
        scan.has_sei = true;
        break;
      case 7:
        scan.has_sps = true;
        break;
      case 8:
        scan.has_pps = true;
        break;
      default:
        break;
    }
    if (unit.type == 7 || unit.type == 8) {
      const size_t end = unit.offset + unit.size;
      scan.sps_pps.insert(scan.sps_pps.end(), frame.begin() + unit.offset,
                          frame.begin() + end);
    }
  }
  return scan;
}

// YUV→RGBA 的换算已经抽到 windows/runner/yuv_to_rgba.{h,cpp}：那里是**不依赖
// Media Foundation 的纯函数**，因此能在本机用带 padding 的 pitch、奇数宽高、
// 1x1、半个 UV 平面等边界输入自测（tools/run_yuv_test.cmd + AddressSanitizer）。
//
// 为什么必须抽出去：实机首跑崩在越界（debug = 0xC0000005，release = CRT fastfail），
// 而"源缓冲长度够不够"这件事只能靠真实 pitch 与真实长度算出来——原来这里按
// `pitch * height * 3 / 2` 估算，奇数高度时整数除法会把 UV 最后一行截掉，
// 于是最后一行的 UV 读越界。现在改成：调用方给出 (data, length, pitch, 宽高)，
// 由纯函数自己校验并拒绝不合格的帧。

// YUV420（NV12 / I420 / IYUV / YV12）→ RGBA8888 的实现见 yuv_to_rgba.cpp。
//
// 这里只留一句备忘：为什么目标是 RGBA 而不是 BGRA——Windows embedder 的像素缓冲纹理
// 固定按 `GL_RGBA` + `GL_UNSIGNED_BYTE` 上传（Flutter 引擎
// shell/platform/windows/external_texture_pixelbuffer.cc），字节序必须是 R、G、B、A。
// 色彩空间固定按 BT.601 视频范围处理（Android 编码器默认档位）；SPS VUI 里的其它
// 色彩空间/范围暂未解析，若实机发现偏色再补。

// 尺寸变化的中间状态：解码线程写，**任何线程**读（通道层在 create / pushFrame 回执里读）。
//
// 为什么不再用回调：原来这里是 `std::function<void(uint32_t,uint32_t)>`，由解码线程
// 触发、通道层再 `PostPlatformThreadTask` 投递到 platform thread 发通道。实机崩溃
// （偏移 0x58CA5 / 0x5AAE5，落在 `std::_Func_class<void>::operator()` 内部）就是
// "调用一个已经被销毁的 std::function 目标"——投递出去的任务活过了它捕获的状态。
// 改成"通道层主动拉"之后，跨线程投递这条路径整体消失（见 AGENTS.md §12）。
class SizeState {
 public:
  void Set(uint32_t width, uint32_t height) {
    std::lock_guard<std::mutex> lock(mutex_);
    size_.width = width;
    size_.height = height;
  }

  ws_scrcpy::DecoderSize Get() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return size_;
  }

 private:
  mutable std::mutex mutex_;
  ws_scrcpy::DecoderSize size_{};
};

// 实现类必须定义在**文件作用域**（匿名命名空间之外）：头文件里是
// `class Impl;` 的嵌套前置声明，只有作用域对得上才能定义它。

// 解码器输出子类型 → 4:2:0 平面布局。
//
// 为什么抽出来：输出缓冲容量的计算（TrySelectOutputType）与换算（ConvertAndPublish）
// 必须用**同一个布局判定**，否则"按 NV12 分配、按 I420 读取"这类不一致会表现为
// 莫名其妙的 E_FAIL 或花屏。未知类型返回 kI420（调用方只在已确认三种类型后才用）。
Yuv420Layout WsLayoutForSubtype(const GUID& subtype) {
  if (IsEqualGUID(subtype, MFVideoFormat_NV12)) {
    return Yuv420Layout::kNv12;
  }
  if (IsEqualGUID(subtype, MFVideoFormat_YV12)) {
    return Yuv420Layout::kYv12;
  }
  return Yuv420Layout::kI420;
}

// 给定时长/跨距的输出缓冲需求（字节）。
//
// **不要**退回 `stride * height * 3 / 2`：那是"高度为偶数"时的巧合值，奇数高度会
// 少算半行（853 就是奇数）。这里直接复用换算侧的纯函数（它按 ceil(height/2) 算），
// 并在平面布局拿不到合法值时给出保守的兜底值。
size_t WsRequiredOutputBytes(Yuv420Layout layout, size_t stride, uint32_t width,
                             uint32_t height, DWORD mft_cb_size) {
  const ws_scrcpy::Yuv420SourceInfo info = ws_scrcpy::ValidateYuv420Source(
      layout, stride, width, height, static_cast<size_t>(-1));
  size_t bytes = info.required_bytes;
  if (bytes == 0) {
    // 例如平面布局遇到奇数 pitch：纯函数会拒绝，这里给"整数 3/2 + 一整行"的保守值。
    bytes = stride * height * 3 / 2 + stride;
  }
  return std::max<size_t>(bytes, static_cast<size_t>(mft_cb_size));
}

}  // namespace

class ScrcpyVideoDecoder::Impl {
 public:
  Impl(flutter::TextureRegistrar* texture_registrar,
       ws_scrcpy::DecoderStartupTimings startup)
      : texture_registrar_(texture_registrar),
        startup_(startup),
        pixel_store_(std::make_shared<PixelBufferStore>()) {}

  ~Impl() { Release(); }

  int64_t Start();
  void PushFrame(const uint8_t* data, size_t size);
  void Release();
  ws_scrcpy::DecoderSize CurrentSize() const { return size_state_.Get(); }
  std::string LastError() const;

 private:
  void DecodeThreadMain();
  bool CreateDecoder();
  bool TrySelectOutputType();
  // 对已经选中的输出类型做落地：算容量、记状态、打日志。
  // 抽出来是为了让 TrySelectOutputType 能做"两趟扫描"（优先挑与初始头期望尺寸一致的
  // 那个类型），而不用把这段落地逻辑写两遍。
  bool ApplyOutputStreamType(IMFMediaType* type, uint32_t width, uint32_t height,
                             bool size_mismatch);
  void ReinitializeInputType(const std::vector<uint8_t>& sequence_header);
  void NotifyStreamingStarted();
  void LogStartupStages();
  void MaybeLogHeartbeat(bool stopping);
  void RecordDecoded();
  size_t QueueDepth() const;
  bool FeedFrame(const std::vector<uint8_t>& frame, LONGLONG timestamp);
  bool DrainOutput();
  void PresentOutput(const ComPtr<IMFSample>& sample);
  void ConvertAndPublish(const uint8_t* data, size_t length);
  // 两条呈现路径的公共收尾（计数 + "首帧"锚点日志 + MarkTextureFrameAvailable）。
  void FinalizePublish(bool gpu_path);
  // 造一个**干净**的输出样本（每次 ProcessOutput 都新造，见 §12.6 的根因）。
  ComPtr<IMFSample> MakeOutputSample(DWORD bytes) const;
  // 强制重新协商输出类型（连续失败时的自愈路径）。
  void ForceRenegotiate();
  // 同类失败限流：前 3 次逐条打，之后每 100 次汇总一条（防止刷屏把日志写满）。
  void LogFailureThrottled(const std::string& key, const std::string& message);
  void ApplySize(uint32_t width, uint32_t height);
  void SetError(const std::string& message);
  // 一次性打出"解码器当前能给出哪些输出类型"（判断参数集有没有被认出来，见 §12.8）。
  void LogAvailableOutputTypesOnce();
  // 把进入解码器的帧按 "uint32 长度 + 字节" 追加写入 WS_CAPTURE_FRAMES 指定的文件
  // （离线复现用；不解析、不改动帧，纯 dump）。
  void CaptureFrameIfRequested(const uint8_t* data, size_t size);

  flutter::TextureRegistrar* texture_registrar_ = nullptr;
  ws_scrcpy::DecoderStartupTimings startup_;
  SizeState size_state_;
  std::shared_ptr<PixelBufferStore> pixel_store_;

  // GPU 呈现路（D3D11 共享纹理）。为空或 gpu_path_ 为假时走 CPU 像素缓冲路。
  //
  // 两条路对 Dart 侧的契约**完全一样**（textureId + 尺寸回执 + 同一套控制消息），
  // 所以走哪条只影响本文件内部：选路在 Start() 里一次决定，建不起来就回落 CPU。
  std::shared_ptr<ws_scrcpy::D3d11VideoPresenter> presenter_;
  bool gpu_path_ = false;
  // 非 NV12 / 自下而上的输出只能走 CPU 换算，这条一次性日志避免每帧刷屏。
  bool gpu_layout_fallback_logged_ = false;

  // 纹理对象必须活到注销完成（引擎持有指向它的指针）。
  std::shared_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;

  std::thread thread_;
  mutable std::mutex init_mutex_;
  std::condition_variable init_cv_;
  bool init_done_ = false;
  bool init_succeeded_ = false;
  std::string last_error_;

  // mutable：QueueDepth() 是 const 成员（心跳/看门狗要在 const 上下文里读队列深度）。
  mutable std::mutex queue_mutex_;
  std::condition_variable queue_cv_;
  std::deque<std::vector<uint8_t>> queue_;
  // 与 queue_ 一一对应的入队时刻：用来量"真正的排队延迟"（入队 → 出队）。
  // 只看队列深度看不出延迟有多大：深度 1 在 30fps 下就是 33ms，在 5fps 下是 200ms。
  std::deque<std::chrono::steady_clock::time_point> queue_enqueued_at_;
  bool stopping_ = false;
  std::atomic<bool> released_{false};

  // ------------------------------------------------ 心跳 / 看门狗用的计数器
  //
  // 全部是原子：解码线程写，platform thread 只读（通道层不需要，但保持"可观测"
  // 这件事不依赖单线程假设更安全）。
  std::atomic<uint64_t> received_frames_{0};   // 进入队列的帧
  std::atomic<uint64_t> fed_frames_{0};        // 真正喂进解码器的帧
  std::atomic<uint64_t> published_frames_{0};  // 换算成功并交给纹理的帧
  std::atomic<uint64_t> dropped_frames_{0};    // 丢弃的帧（队列溢出 + 喂帧/换算失败）

  // 看门狗状态只由解码线程读写。
  std::chrono::steady_clock::time_point next_heartbeat_{};
  std::chrono::steady_clock::time_point last_decoded_at_{};
  bool has_decoded_at_ = false;
  // 最近 N 帧的"喂入 → 换算完成"耗时（微秒），用来算平均值。
  std::deque<long long> decode_times_us_;
  long long last_slow_warning_at_ms_ = -1;
  long long last_stall_warning_at_ms_ = -1;

  // 每帧耗时的拆分（微秒）。只由解码线程读写——心跳也在解码线程上打，所以不加锁。
  //
  // 为什么要把"帧间隔"和"处理耗时"分开：原来的"平均解码"记的是**两次发布之间的间隔**，
  // 30fps 时它天然就是 33ms，看不出任何东西；真正的瓶颈判据是"帧间隔 >> 处理耗时"
  // （说明是**流没给帧**，不是我们慢）。这里两个都记，并拆出 MFT 解码与换算两部分。
  long long last_process_us_ = 0;   // 出队 → 发布（整帧处理）
  long long last_convert_us_ = 0;   // 其中 YUV→RGBA 换算（CPU 路；GPU 路恒为 0）
  long long last_upload_us_ = 0;    // GPU 路：NV12 重排 + 上传 + 画 的耗时
  std::deque<long long> process_times_us_;
  std::deque<long long> convert_times_us_;
  std::deque<long long> upload_times_us_;
  std::deque<long long> queue_wait_us_;  // 入队 → 出队（排队延迟）

  // 引擎侧节奏（光栅线程）：上一秒的累计值，心跳里算"本秒 +N"。
  // 比较它与"已发布"的增速就能定位瓶颈在我们这侧还是引擎侧（判据见 AGENTS.md §12.8）。
  uint64_t previous_raster_callbacks_ = 0;
  // 停摆检测用：上一秒的"已发布"累计值 + 连续停摆秒数 + 上次报警时刻。
  uint64_t previous_published_frames_ = 0;
  int engine_stall_seconds_ = 0;
  long long last_engine_stall_warning_ms_ = 0;

  // 诊断（只由解码线程读写）
  bool logged_available_types_ = false;         // "解码器可用输出类型"只打一次
  uint64_t process_output_need_more_input_ = 0; // ProcessOutput 返回 NEED_MORE_INPUT 的次数

  // 抓帧（WS_CAPTURE_FRAMES=<路径>）：PushFrame 在 platform thread 上调用，所以要加锁。
  std::mutex capture_mutex_;
  FILE* capture_file_ = nullptr;
  bool capture_open_attempted_ = false;
  uint64_t capture_frames_ = 0;

  // 以下几项只由解码线程读写（Release 会先 join 再动它们）。
  ComPtr<IMFTransform> decoder_;
  // **不保存可复用的输出样本**：这是 0x80004005 洪水那个 bug 的根因（见 AGENTS §12.6）。
  // 既然后果是"只有一个样本能成功"，就只记协商出来的容量，每次 ProcessOutput
  // 现造一个**干净的**样本（与首次协商成功时那条路径完全一致）。
  DWORD output_buffer_bytes_ = 0;
  bool streaming_started_ = false;
  bool streaming_notify_logged_ = false;
  bool output_type_set_ = false;
  GUID output_subtype_{};
  uint32_t output_width_ = 0;
  uint32_t output_height_ = 0;
  size_t output_stride_ = 0;
  bool output_bottom_up_ = false;
  std::vector<uint8_t> sequence_header_;      // 最近一次看到的 SPS/PPS
  std::vector<uint8_t> last_header_attempt_;  // 已经写进输入类型的那份
  uint32_t attempted_frames_ = 0;
  std::vector<uint8_t> scratch_;
  uint32_t current_width_ = 0;
  uint32_t current_height_ = 0;
  // "初始头期望尺寸"：来自 Dart 侧初始信息头（displayInfo），**只由 Start 设定**。
  // 协商输出类型时用它来挑"跟真实码流一致"的那个类型；它不会被协商结果覆盖，
  // 所以心跳里可以永远拿它跟"输出类型"对照（含糊过一次，见 AGENTS §12.5/§12.7）。
  uint32_t expected_width_ = 0;
  uint32_t expected_height_ = 0;
  LONGLONG frame_timestamp_ = 0;

  // ---- 流内容诊断（都是解码线程私有） ----
  //
  // scrcpy 的编码器**没有 IDR 就不会产出可解码画面**，而且此时 ProcessInput /
  // ProcessOutput 都不报错（一直 NEED_MORE_INPUT）——现象正是"零错误 + 零输出"。
  // 以前日志里看不出"流里有没有 IDR"，只能靠猜；这几个计数 + 一次性汇总就是为此。
  uint64_t idr_frames_ = 0;        // 含 IDR(5) 的帧数
  uint64_t vcl_frames_ = 0;        // 含图像片(1/5) 的帧数
  uint64_t sps_pps_frames_ = 0;    // 含 SPS(7)/PPS(8) 的帧数
  bool first_idr_logged_ = false;
  bool nal_diagnostic_logged_ = false;
  std::vector<uint8_t> first_frame_nal_types_;
  bool no_output_warning_logged_ = false;

  // ---- 失败可观测性（都是解码线程私有，不需要加锁） ----
  //
  // 为什么要计数 + 限流：修这个 bug 时，日志里 `ProcessOutput 失败：0x80004005`
  // 刷了几千行，把 2 MB 上限写满、反而把有用信息挤掉了。任何"每帧都可能出现"的
  // 失败路径都必须：同类只打前几次 + 每 100 次汇总一条，并在心跳里带累计数。
  uint64_t process_output_failures_ = 0;
  uint64_t process_input_failures_ = 0;
  uint64_t stream_change_count_ = 0;
  // "不报错但也不出帧"的三条路径**必须各自计数**：它们正是"零错误 + 零输出"的全部
  // 可能来源，以前一条都没统计，所以日志上看不出解码器到底卡在哪一步。
  uint64_t needs_more_input_count_ = 0;   // ProcessOutput 说"还要更多输入"（等关键帧等）
  uint64_t incomplete_output_count_ = 0;  // S_OK 但 dwStatus=INCOMPLETE（空样本）
  uint64_t empty_output_count_ = 0;       // S_OK 且样本里没有可用数据
  uint32_t consecutive_process_output_failures_ = 0;
  uint64_t forced_renegotiations_ = 0;
  HRESULT last_process_output_result_ = S_OK;
  DWORD last_output_status_ = 0;
  std::unordered_map<std::string, uint64_t> throttled_log_counts_;
  bool output_type_negotiated_once_ = false;  // 区分"首次协商"与"中途重新协商"的措辞
  bool output_type_mismatch_logged_ = false;  // "输出类型与初始头期望不符"只提醒一次
};

// 下面的成员函数定义都写在**全局作用域**（限定名 ScrcpyVideoDecoder::Impl::...）：
// 它们是上面这个类的成员，而类本身在全局作用域，因此定义也必须在这里。
// 匿名命名空间里的常量与辅助函数在文件作用域依然可见，所以这里照旧能用
// kMaxPendingFrames / ScanAnnexB / ComPtr 等。
int64_t ScrcpyVideoDecoder::Impl::Start() {
  // 日志是幂等的：解码线程起来后会再调一次；这里先调是为了让 Start 里
  // 万一提前失败也能落盘（也保证时间基准取的是"模块最早"那一刻）。
  ws_scrcpy::InitializeLog(kModuleName);
  if (released_.load()) {
    SetError("解码器已释放，无法重复启动");
    return -1;
  }
  if (thread_.joinable()) {
    SetError("解码器已经在运行");
    return -1;
  }
  if (texture_registrar_ == nullptr) {
    SetError("拿不到 Flutter 纹理注册器（platform 视图未就绪）");
    return -1;
  }

  // 先把纹理按占位尺寸准备好：Dart 侧要立刻拿到 textureId 才能渲染 Texture。
  // 这个尺寸同时也是"初始头期望尺寸"：协商输出类型时用它来挑正确的类型。
  expected_width_ = kInitialWidth;
  expected_height_ = kInitialHeight;

  // ---- 呈现路径选择：GPU（D3D11 共享纹理）优先，建不起来回落 CPU 像素缓冲 ----
  //
  // 为什么优先 GPU：CPU 路每帧要把整帧 NV12 转成 RGBA 再交给引擎上传（720p 3.7MB/帧，
  // 1080p 8.3MB/帧），而 Android（SurfaceProducer）与网页端（GPU 解码 + GPU 合成）都不做
  // 这件事——这就是 Windows 端"又卡又延迟"的结构性差距（AGENTS.md §12.8）。
  // 回落路径必须保留：D3D11 设备/共享纹理在某些环境（远程桌面、驱动异常、多显卡）
  // 会建不起来，那时宁可回到"能用但 CPU 忙"的老路，也不能黑屏。
  const ws_scrcpy::PresenterOptions presenter_options =
      ws_scrcpy::PresenterOptions::FromEnvironment();
  if (presenter_options.enabled) {
    auto presenter = std::make_shared<ws_scrcpy::D3d11VideoPresenter>();
    if (presenter->Create(kInitialWidth, kInitialHeight, presenter_options)) {
      presenter_ = presenter;
      gpu_path_ = true;
      DebugLog("呈现路径：GPU 共享纹理（D3D11 → RGBA → DXGI 共享句柄），适配器=" +
               (presenter->device_name().empty() ? std::string("<未知>")
                                                 : presenter->device_name()));
    } else {
      DebugLog("呈现路径：CPU 像素缓冲（GPU 路不可用：" + presenter->LastError() +
               "；默认本来就是 CPU 路，设 WS_SCRCPY_GPU=1 才会试 GPU 路）");
    }
  } else {
    DebugLog("呈现路径：CPU 像素缓冲（GPU 共享纹理路默认关闭：真机上全黑，见 AGENTS §12.8；"
             "设 WS_SCRCPY_GPU=1 可显式启用）");
  }

  ApplySize(kInitialWidth, kInitialHeight);

  std::shared_ptr<flutter::TextureVariant> texture;
  if (gpu_path_) {
    const std::shared_ptr<ws_scrcpy::D3d11VideoPresenter> presenter = presenter_;
    texture = std::make_shared<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
        kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
        [presenter](size_t width, size_t height) {
          // 引擎给的 width/height 是"期望尺寸"，我们以真实解码尺寸为准
          // （引擎用返回描述符里的 physical/visible 宽高）。
          static_cast<void>(width);
          static_cast<void>(height);
          return presenter->ObtainDescriptor();
        }));
  } else {
    const std::shared_ptr<PixelBufferStore> store = pixel_store_;
    texture = std::make_shared<flutter::TextureVariant>(
        flutter::PixelBufferTexture([store](size_t width, size_t height) {
          // 同上：忽略入参，用真实解码尺寸。
          static_cast<void>(width);
          static_cast<void>(height);
          return store->CopyLatest();
        }));
  }
  texture_ = texture;
  const bool registering_gpu_texture = gpu_path_;
  const long long register_begin_ms = NowMs();
  texture_id_ = texture_registrar_->RegisterTexture(texture.get());
  if (texture_id_ < 0) {
    texture_.reset();
    presenter_.reset();
    gpu_path_ = false;
    SetError(registering_gpu_texture ? "注册 GPU 共享纹理失败"
                                    : "注册像素缓冲纹理失败");
    return -1;
  }
  DebugLog(std::string("阶段：注册") +
           (gpu_path_ ? "GPU 共享纹理" : "像素缓冲纹理") + "完成 textureId=" +
           std::to_string(texture_id_) + "，耗时 " +
           std::to_string(NowMs() - register_begin_ms) + "ms");

  thread_ = std::thread([this]() { DecodeThreadMain(); });

  // 等解码线程把 COM / Media Foundation / 解码器 MFT 建起来：重活都在那个线程上，
  // platform thread 只等一个结果。这样"建不起来"能变成 Dart 侧可读的错误 + 重试入口，
  // 而不是注册了纹理却永远黑屏。
  std::unique_lock<std::mutex> lock(init_mutex_);
  const bool finished =
      init_cv_.wait_for(lock, kInitTimeout, [this]() { return init_done_; });
  const bool succeeded = finished && init_succeeded_;
  lock.unlock();

  if (!succeeded) {
    if (!finished) {
      SetError("启动原生解码器超时");
    }
    Release();
    return -1;
  }
  LogOnce("decoder-ready",
          "解码器就绪：textureId=" + std::to_string(texture_id_) + "，真实尺寸 " +
              std::to_string(CurrentSize().width) + "x" +
              std::to_string(CurrentSize().height) + "（等待首帧）");
  return texture_id_;
}

void ScrcpyVideoDecoder::Impl::PushFrame(const uint8_t* data, size_t size) {
  if (data == nullptr || size == 0 || released_.load()) {
    return;
  }
  LogOnce("first-push-frame",
          "首个 pushFrame 到达：长度 " + std::to_string(size) + " 字节");
  // 抓帧（若设了 WS_CAPTURE_FRAMES）：必须在入队之前 dump，且只 dump 真正喂进解码器的帧。
  CaptureFrameIfRequested(data, size);
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    if (stopping_) {
      return;
    }
    // 解码跟不上时丢**最旧**的帧（上限见 kMaxPendingFrames 的注释）：
    // 内存不会无界增长，延迟有界，画面靠下一个关键帧（编码侧定期给 IDR）重新同步。
    while (queue_.size() >= kMaxPendingFrames) {
      queue_.pop_front();
      if (!queue_enqueued_at_.empty()) {
        queue_enqueued_at_.pop_front();
      }
      dropped_frames_.fetch_add(1);
    }
    queue_.emplace_back(data, data + size);
    queue_enqueued_at_.push_back(std::chrono::steady_clock::now());
  }
  received_frames_.fetch_add(1);
  queue_cv_.notify_one();
}

size_t ScrcpyVideoDecoder::Impl::QueueDepth() const {
  std::lock_guard<std::mutex> lock(queue_mutex_);
  return queue_.size();
}

void ScrcpyVideoDecoder::Impl::Release() {
  if (released_.exchange(true)) {
    return;  // 可重复调用
  }
  DebugLog("Release：停解码线程并清空队列");
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    stopping_ = true;
    queue_.clear();
    queue_enqueued_at_.clear();
  }
  queue_cv_.notify_all();
  if (thread_.joinable()) {
    thread_.join();
  }

  const int64_t texture_id = texture_id_;
  texture_id_ = -1;
  if (texture_id >= 0 && texture_registrar_ != nullptr) {
    // 注销是异步的：把纹理对象与像素缓冲/GPU 呈现器都挂在回调上，等引擎确认不再引用
    // 之后才真正释放（引擎要求注销完成前返回过的缓冲/句柄必须保持有效）。
    const std::shared_ptr<flutter::TextureVariant> texture = texture_;
    const std::shared_ptr<PixelBufferStore> store = pixel_store_;
    const std::shared_ptr<ws_scrcpy::D3d11VideoPresenter> presenter = presenter_;
    texture_registrar_->UnregisterTexture(texture_id, [texture, store, presenter]() {
      if (store) {
        store->Clear();
      }
      // presenter 由这个 lambda 持有：注销回调跑完（引擎不再取描述符）才析构。
      static_cast<void>(presenter);
    });
    DebugLog("Release：已请求注销纹理 " + std::to_string(texture_id));
  }
  if (presenter_ != nullptr) {
    presenter_->Release();
  }
  {
    // 抓帧文件收尾：pushFrame 可能还在另一个线程上调用，这里加锁关闭。
    std::lock_guard<std::mutex> capture_lock(capture_mutex_);
    if (capture_file_ != nullptr) {
      std::fflush(capture_file_);
      std::fclose(capture_file_);
      capture_file_ = nullptr;
      DebugLog("抓帧已关闭：共 " + std::to_string(capture_frames_) + " 帧");
    }
  }
  texture_.reset();
  decoder_.Reset();
  output_buffer_bytes_ = 0;
  output_type_set_ = false;
  DebugLog("Release 完成（可重复调用，本方法幂等）");
}

std::string ScrcpyVideoDecoder::Impl::LastError() const {
  std::lock_guard<std::mutex> lock(init_mutex_);
  return last_error_;
}

void ScrcpyVideoDecoder::Impl::LogStartupStages() {
  // 各阶段耗时都在日志前缀里（`+Nms`），这里再把"阶段名 → 耗时"显式写一遍，
  // 好让排查的人一眼看到到底慢在哪一步（用户要求：create 各阶段都要有时间戳）。
  const auto stage = [](const char* name, long long ms) {
    const std::string value =
        ms < 0 ? std::string("未执行") : std::to_string(ms) + "ms";
    return std::string(name) + "=" + value;
  };
  DebugLog("create 各阶段耗时（相对模块首次写日志）：" +
           stage("COM 初始化", startup_.com_ms) + "，" +
           stage("MFStartup", startup_.mf_ms) + "，" +
           stage("创建 MFT", startup_.create_mft_ms) + "，" +
           stage("configure", startup_.configure_ms) + "，" +
           stage("注册纹理", startup_.register_texture_ms) + "，" +
           stage("注册通道方法", startup_.register_channel_ms));
}

void ScrcpyVideoDecoder::Impl::DecodeThreadMain() {
  ws_scrcpy::InitializeLog(kModuleName);
  const long long thread_begin_ms = NowMs();

  // Media Foundation 要求 MTA；解码器 MFT 只在本线程上创建与使用。
  const long long com_begin_ms = NowMs();
  const bool com_initialized =
      SUCCEEDED(::CoInitializeEx(nullptr, COINIT_MULTITHREADED));
  const long long com_end_ms = NowMs();
  const long long mf_begin_ms = NowMs();
  const bool mf_initialized =
      com_initialized && SUCCEEDED(::MFStartup(MF_VERSION, MFSTARTUP_LITE));
  const long long mf_end_ms = NowMs();

  // 把通道层测到的阶段耗时与解码线程自己的阶段耗时合并后打一条汇总。
  startup_.com_ms = com_end_ms - com_begin_ms;
  startup_.mf_ms = mf_end_ms - mf_begin_ms;
  DebugLog("解码线程启动：线程内 COM 初始化耗时 " +
           std::to_string(startup_.com_ms) + "ms，MFStartup 耗时 " +
           std::to_string(startup_.mf_ms) + "ms");
  LogStartupStages();

  bool succeeded = false;
  if (!com_initialized) {
    SetError("COM 初始化失败（MTA）");
  } else if (!mf_initialized) {
    SetError("Media Foundation 初始化失败");
  } else {
    const long long create_begin_ms = NowMs();
    succeeded = CreateDecoder();
    startup_.create_mft_ms = NowMs() - create_begin_ms;
    DebugLog(std::string("阶段：创建解码器 MFT ") +
             (succeeded ? "成功" : "失败") + "，耗时 " +
             std::to_string(startup_.create_mft_ms) + "ms");
  }

  {
    std::lock_guard<std::mutex> lock(init_mutex_);
    init_succeeded_ = succeeded;
    init_done_ = true;
  }
  init_cv_.notify_all();
  DebugLog("解码线程初始化结束：platform thread 等待耗时约 " +
           std::to_string(NowMs() - thread_begin_ms) + "ms，结果=" +
           (succeeded ? "成功" : "失败"));

  if (!succeeded) {
    // 顺序很重要：先放掉 MF/COM 对象，再收尾 COM / Media Foundation。
    decoder_.Reset();
    if (mf_initialized) {
      DebugLog("阶段：MFShutdown（初始化失败路径）");
      ::MFShutdown();
    }
    if (com_initialized) {
      DebugLog("阶段：CoUninitialize（初始化失败路径）");
      ::CoUninitialize();
    }
    return;
  }

  // 看门狗：第一条心跳在启动后 kHeartbeatInterval 到来。此时如果一帧都还没解出来，
  // "距上一帧"按"解码器就绪至今"算，卡死会立刻被看见（而不是日志停在最后一条）。
  next_heartbeat_ = std::chrono::steady_clock::now() + kHeartbeatInterval;

  for (;;) {
    std::vector<uint8_t> frame;
    std::chrono::steady_clock::time_point enqueued_at;
    bool has_enqueued_at = false;
    {
      std::unique_lock<std::mutex> lock(queue_mutex_);
      // 为什么用带超时的 wait 而不是无限等：**空闲时必须还能出心跳**（用户要求
      // "要监控时间，不然卡死都不知道"）。超时只是醒来记一条心跳，没有帧就继续等。
      queue_cv_.wait_for(lock, kHeartbeatInterval, [this]() {
        return stopping_ || !queue_.empty();
      });
      if (stopping_) {
        break;
      }
      if (queue_.empty()) {
        lock.unlock();
        MaybeLogHeartbeat(false);
        continue;
      }
      frame = std::move(queue_.front());
      queue_.pop_front();
      if (!queue_enqueued_at_.empty()) {
        enqueued_at = queue_enqueued_at_.front();
        queue_enqueued_at_.pop_front();
        has_enqueued_at = true;
      }
    }
    // 计时从"真正拿到一帧"开始，**不包括**上面那段等队列的时间——否则"处理耗时"
    // 会被等待时间污染，等于又把帧间隔量了一遍。排队延迟单独量（见下）。
    const auto iteration_begin = std::chrono::steady_clock::now();
    if (has_enqueued_at) {
      queue_wait_us_.push_back(
          std::chrono::duration_cast<std::chrono::microseconds>(iteration_begin -
                                                               enqueued_at)
              .count());
      while (queue_wait_us_.size() > kHeartbeatTimingWindow) {
        queue_wait_us_.pop_front();
      }
    }

    // 先按"参数集在码流里"（Annex-B 的常规做法）走：把帧喂给解码器，
    // 让它自己解析 SPS/PPS 并给出输出类型（输出类型定下来后分辨率变化由
    // MF_E_TRANSFORM_STREAM_CHANGE 通知，见 DrainOutput）。
    const NalScan scan = ScanAnnexB(frame);
    if (!scan.sps_pps.empty()) {
      sequence_header_ = scan.sps_pps;
      // 一次性把参数集原样写进日志（hex）：真机上"解码器不认这条码流"时，这是唯一能
      // 离线核对的东西（喂给 MF 的序列头到底是什么）。只打前 64 字节，避免刷屏。
      std::string hex;
      for (size_t index = 0; index < scan.sps_pps.size() && index < 64; ++index) {
        char byte_text[4] = {};
        std::snprintf(byte_text, sizeof(byte_text), "%02X",
                      static_cast<unsigned int>(scan.sps_pps[index]));
        hex += byte_text;
      }
      LogOnce("first-sps-pps-hex",
              "首个 SPS/PPS（" + std::to_string(scan.sps_pps.size()) +
                  " 字节，hex）：" + hex);
    }
    ++attempted_frames_;

    // ---------------- 流内容诊断（前 N 帧一次性汇总） ----------------
    //
    // 目的只有一个：**把"流里有没有 IDR"变成一句日志**，而不是靠猜。
    // scrcpy 的编码器只发"画面变化"对应的帧；如果没有 IDR，解码器会一直
    // NEED_MORE_INPUT（不报错、不出帧），现象就是用户看到的"几分钟一张图"。
    if (scan.has_idr) {
      ++idr_frames_;
      if (!first_idr_logged_) {
        first_idr_logged_ = true;
        DebugLog("首次收到 IDR（第 " + std::to_string(attempted_frames_) +
                 " 帧，长度 " + std::to_string(frame.size()) + " 字节）");
      }
    }
    if (scan.has_vcl) {
      ++vcl_frames_;
    }
    if (!scan.sps_pps.empty()) {
      ++sps_pps_frames_;
    }
    if (first_frame_nal_types_.empty()) {
      first_frame_nal_types_ = scan.types;
    }
    if (!nal_diagnostic_logged_ &&
        (scan.has_idr || attempted_frames_ >= kNalDiagnosticFrames)) {
      nal_diagnostic_logged_ = true;
      std::string types_text;
      for (size_t index = 0; index < scan.types.size(); ++index) {
        types_text += (index == 0 ? "" : ",") + std::to_string(scan.types[index]);
      }
      std::string first_text;
      for (size_t index = 0; index < first_frame_nal_types_.size(); ++index) {
        first_text += (index == 0 ? "" : ",") +
                      std::to_string(first_frame_nal_types_[index]);
      }
      DebugLog("前 " + std::to_string(attempted_frames_) +
               " 帧 NAL 统计：IDR " + std::to_string(idr_frames_) +
               " 帧，含图像片 " + std::to_string(vcl_frames_) +
               " 帧，含 SPS/PPS " + std::to_string(sps_pps_frames_) +
               " 帧；首帧 NAL 类型=[" + first_text + "]，本帧 NAL 类型=[" +
               types_text + "]");
      if (idr_frames_ == 0) {
        // 这条就是定性结论：没有关键帧时，解码器**不可能**产出画面（这不是我们的 bug）。
        DebugLog("前 " + std::to_string(attempted_frames_) +
                 " 帧内没有 IDR（只有非 IDR 片）：解码器无法产出画面。"
                 "根因在流/编码器侧（关键帧被漏掉或编码器没发 IDR），"
                 "不是解码器：客户端侧能做的只有重新协商或等下一个 IDR。");
      }
    }
    // "喂了很多帧但一帧都没解出来"的定性结论（一次性）。
    //
    // 为什么值得单独一条：真机上出现过 `已喂入 13 / 已发布 0`，而 ProcessInput /
    // ProcessOutput **一个错误都不报**——只靠计数器看不出原因。这条把"协商到了什么类型"
    // 和"解码器认不认这条码流"直接写在一起（§12.8）。
    if (published_frames_.load() == 0 && attempted_frames_ == kNoOutputFramesBeforeWarning) {
      DebugLog(
          "WARNING 已喂入 " + std::to_string(attempted_frames_) +
          " 帧但一帧都没解出来：协商到的输出类型=" +
          std::to_string(output_width_) + "x" + std::to_string(output_height_) +
          "（" + (output_type_set_ ? "已选定" : "尚未选定") + "），可用类型见上面那条"
          "『解码器可用输出类型』；若它只有 1920x1080，说明**参数集没被解码器接受**"
          "（码流的 SPS/PPS 不合法或与帧不匹配），对比同一设备在网页端/Android 端是否正常");
    }
    LogOnce("first-sample-feed", "首个样本喂入解码器（长度 " +
                                     std::to_string(frame.size()) + " 字节）");

    // **不要**在喂入样本之前协商输出类型。
    //
    // 这是 0x80004005 那次的第二个缺陷（见 AGENTS §12.6）：那时解码器还没看到 SPS，
    // `GetOutputAvailableType` 会给出一个"默认类型"（实测是 1920x1080），我们把它
    // SetOutputType 之后就与真实码流（1280x720）不符，此后每次 ProcessOutput 都失败
    // ——日志里"已解出第一帧"出现在**第二次**协商之后，正是这个顺序问题的签名。
    //
    // 正确顺序：先把 SPS/PPS 作为 MF_MT_MPEG_SEQUENCE_HEADER 写进输入类型（解码器
    // 因此一开始就知道真实分辨率），协商则交给下面三条既有路径触发：
    //   FeedFrame 里 ProcessInput 的 MF_E_TRANSFORM_TYPE_NOT_SET、
    //   DrainOutput 里 ProcessOutput 的 MF_E_TRANSFORM_STREAM_CHANGE / TYPE_NOT_SET、
    //   以及这里的"协商不出来时按帧数重试"兜底。
    if (!output_type_set_ && !sequence_header_.empty() &&
        sequence_header_ != last_header_attempt_) {
      last_header_attempt_ = sequence_header_;
      ReinitializeInputType(sequence_header_);
      // **写进输入类型之后立刻协商**（§12.8 的修正）。
      //
      // 以前要等 `ProcessInput` 报 `MF_E_TRANSFORM_TYPE_NOT_SET`、或者喂够
      // `kOutputTypeNegotiationFrames` 帧才协商。实测（redroid 流）两条路都没走通：
      // ProcessInput 13 次全部返回 S_OK（不报错也不出帧），于是直到第 12 帧的兜底才协商，
      // 而那一刻拿到的是**默认 1920x1080**——按 MF 的语义，这说明解码器还没认出码流，
      // 之后的 `ProcessOutput` 只会一直返回"还需更多输入"，画面永远黑。
      // 现在参数集已经在输入类型里（上一句刚写完），`GetOutputAvailableType` 应当
      // 直接给出真实分辨率，所以这里同步协商一次；失败也不影响后面的既有路径。
      LogAvailableOutputTypesOnce();
      if (!TrySelectOutputType()) {
        DebugLog("写入 SPS/PPS 后仍协商不出输出类型（等更多输入 / 流格式变化）");
      }
    }
    if (!output_type_set_ && attempted_frames_ >= kOutputTypeNegotiationFrames) {
      TrySelectOutputType();
    }

    NotifyStreamingStarted();
    const bool fed = FeedFrame(frame, frame_timestamp_);
    if (!fed && output_type_set_) {
      // 单帧失败（例如丢了参考帧）不该让整条链路退出：丢这一帧，
      // 等后面的关键帧重新同步。协商阶段失败是预期内的，不刷日志。
      dropped_frames_.fetch_add(1);
      LogFailureThrottled("feed-frame", "丢弃一帧（喂帧失败）");
    } else if (fed) {
      fed_frames_.fetch_add(1);
    }
    frame_timestamp_ += kFrameDurationHns;
    const uint64_t published_before = published_frames_.load();
    DrainOutput();
    if (published_frames_.load() != published_before) {
      // 这一轮真的产出并发布了一帧：把"出队 → 发布"记为整帧处理耗时。
      last_process_us_ = std::chrono::duration_cast<std::chrono::microseconds>(
                             std::chrono::steady_clock::now() - iteration_begin)
                             .count();
      process_times_us_.push_back(last_process_us_);
      while (process_times_us_.size() > kHeartbeatTimingWindow) {
        process_times_us_.pop_front();
      }
    }
    // 心跳：把"帧间隔"和"处理耗时"一起报出来，卡死/流停/自己慢三种情况一眼可分。
    MaybeLogHeartbeat(false);
  }

  MaybeLogHeartbeat(true);
  DebugLog("解码线程退出：已解码 " + std::to_string(published_frames_.load()) +
           "，已发布 " + std::to_string(published_frames_.load()) + "，丢弃 " +
           std::to_string(dropped_frames_.load()));
  if (decoder_) {
    decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
  }
  // 必须在 CoUninitialize 之前释放掉所有 COM/MF 对象，否则可能卸载宿主 DLL
  // 之后再去 Release，进程退出时崩在别人的代码里。
  decoder_.Reset();
  output_buffer_bytes_ = 0;
  if (mf_initialized) {
    ::MFShutdown();
  }
  if (com_initialized) {
    ::CoUninitialize();
  }
}

void ScrcpyVideoDecoder::Impl::RecordDecoded() {
  const auto now = std::chrono::steady_clock::now();
  if (has_decoded_at_) {
    const long long gap_us =
        std::chrono::duration_cast<std::chrono::microseconds>(now -
                                                             last_decoded_at_)
            .count();
    decode_times_us_.push_back(gap_us);
    while (decode_times_us_.size() > kHeartbeatTimingWindow) {
      decode_times_us_.pop_front();
    }
    if (gap_us / 1000 > kHeartbeatSlowDecodeWarningMs) {
      // 单帧（喂入 → 换算完成）超过 1 秒：明确报出来，并带上当时的尺寸与队列深度。
      const long long now_ms = NowMs();
      if (last_slow_warning_at_ms_ < 0 ||
          now_ms - last_slow_warning_at_ms_ >= kWarningRepeatMs) {
        last_slow_warning_at_ms_ = now_ms;
        DebugLog("WARNING 单帧解码过慢：" + std::to_string(gap_us / 1000) +
                 "ms（阈值 " + std::to_string(kHeartbeatSlowDecodeWarningMs) +
                 "ms，指两帧之间的间隔），尺寸(最后一帧)=" +
                 std::to_string(output_width_) + "x" +
                 std::to_string(output_height_) + "，队列深度 " +
                 std::to_string(QueueDepth()));
      }
    }
  }
  last_decoded_at_ = now;
  has_decoded_at_ = true;
}

void ScrcpyVideoDecoder::Impl::MaybeLogHeartbeat(bool stopping) {
  const auto now = std::chrono::steady_clock::now();
  if (stopping && !has_decoded_at_) {
    return;  // 从没解出过帧就退出了，最后那条正常心跳已经说明情况
  }
  if (!stopping && now < next_heartbeat_) {
    return;
  }
  next_heartbeat_ = now + kHeartbeatInterval;

  const long long gap_ms =
      has_decoded_at_
          ? std::chrono::duration_cast<std::chrono::milliseconds>(
                now - last_decoded_at_)
                .count()
          : -1;
  // 队列深度先取一次快照：DebugLog 会去抢日志锁，绝不带着 queue_mutex_ 进去
  // （PushFrame 是"先拿 queue_mutex_ 再写日志"，反过来会死锁）。
  const size_t queue_depth = QueueDepth();

  // 平均值的三个口径（都是"最近 N 帧"）：
  //   - 帧间隔     ：两次发布之间的间隔（**由服务端给帧的节奏决定**，30fps 就是 ~33ms）
  //   - 平均处理   ：出队 → 发布 的整帧耗时（我们自己的开销）
  //   - 解码 / 换算：处理耗时里 MFT 解码部分与 YUV→RGBA 换算部分的拆分
  // 判据：帧间隔 >> 平均处理 = **流没给帧**（设备屏幕静止/休眠）；两者接近 = 我们慢。
  auto average_of = [](const std::deque<long long>& samples) -> long long {
    if (samples.empty()) {
      return -1;
    }
    long long total = 0;
    for (const long long item : samples) {
      total += item;
    }
    return total / static_cast<long long>(samples.size());
  };
  const long long average_interval_us = average_of(decode_times_us_);
  const long long average_process_us = average_of(process_times_us_);
  const long long average_convert_us = average_of(convert_times_us_);
  const long long average_mft_us =
      (average_process_us >= 0 && average_convert_us >= 0 &&
       average_process_us > average_convert_us)
          ? average_process_us - average_convert_us
          : -1;
  auto ms_text = [](long long microseconds) {
    return microseconds < 0 ? std::string("尚无样本")
                            : std::to_string(microseconds / 1000) + "ms";
  };

  // 尺寸有两个口径，**必须写清**（用户就是被这个含糊绕过的）：
  //   - 尺寸(初始)：configure 时按 displayInfo 定下的、也用于创建像素缓冲的尺寸；
  //   - 尺寸(最后一帧)：解码器输出类型真正给出的尺寸（首帧解出前是 0x0）。
  const std::string size_text = "，尺寸(初始)=" + std::to_string(current_width_) +
                                "x" + std::to_string(current_height_) +
                                "，尺寸(最后一帧)=" +
                                std::to_string(output_width_) + "x" +
                                std::to_string(output_height_);

  // 呈现路径 + "引擎侧的节奏"。
  //
  // 光栅回调 = 引擎（光栅线程）来取帧的次数：CPU 路是 PixelBufferStore::CopyLatest，
  // GPU 路是 D3D11VideoPresenter::ObtainDescriptor，两者口径一致。
  // **判据**（AGENTS.md §12.8）：
  //   - 已发布的增速 ≫ 光栅回调的增速 → 引擎侧（上传/合成）才是瓶颈；
  //   - 两者接近 → 瓶颈在我们这一侧（解码/换算/上传）。
  // 队列等待 = 入队 → 出队，这才是"排队带来的延迟"（只看队列深度看不出绝对值）。
  const uint64_t raster_callbacks =
      (gpu_path_ && presenter_ != nullptr) ? presenter_->descriptor_callbacks()
                                           : pixel_store_->raster_callbacks();
  const uint64_t raster_per_second =
      raster_callbacks >= previous_raster_callbacks_
          ? raster_callbacks - previous_raster_callbacks_
          : raster_callbacks;
  previous_raster_callbacks_ = raster_callbacks;

  // ---- 停摆检测（用户报的现象：网页端早就操作完了，Flutter 端"时不时卡几秒才显示"）----
  //
  // 关键是**用增量分开定性**，而不是看累计值：
  //   * 收到不涨            → 帧没到（服务端 / 网络 / WS）；
  //   * 收到涨、已发布不涨  → 帧到了但没解出来（MFT / 换算 / 锁）；
  //   * **已发布涨、光栅回调不涨** → 引擎没来取纹理（上传 / 合成 / 引擎帧调度）。
  // 第三种正是"画面卡住，而我们这边一切正常"的签名——用户看到的卡几秒属于这一类时，
  // 修的地方在引擎/上传侧，不在解码侧。连续 2 秒成立才报，且按 kWarningRepeatMs 抑制重复。
  {
    const uint64_t published_now = published_frames_.load();
    const uint64_t published_per_second =
        published_now >= previous_published_frames_
            ? published_now - previous_published_frames_
            : published_now;
    previous_published_frames_ = published_now;
    const bool engine_stalled =
        published_per_second > 0 && raster_per_second == 0;
    if (engine_stalled) {
      ++engine_stall_seconds_;
    } else {
      engine_stall_seconds_ = 0;
    }
    if (engine_stall_seconds_ >= 2 &&
        NowMs() - last_engine_stall_warning_ms_ >= kWarningRepeatMs) {
      last_engine_stall_warning_ms_ = NowMs();
      DebugLog(
          "WARNING 画面停摆 " + std::to_string(engine_stall_seconds_) +
          " 秒：我们这一秒发布了 " + std::to_string(published_per_second) +
          " 帧，但**引擎一次都没来取纹理**（光栅回调本秒 +0）——卡在引擎侧"
          "（纹理上传 / 合成 / 引擎帧调度），不是解码侧；路径=" +
          (gpu_path_ ? "GPU 共享纹理" : "CPU 像素缓冲") +
          "，尺寸=" + std::to_string(output_width_) + "x" +
          std::to_string(output_height_) + "，队列深度 " +
          std::to_string(queue_depth));
    }
  }
  const long long average_queue_wait_us = average_of(queue_wait_us_);
  const long long average_upload_us = average_of(upload_times_us_);
  std::string path_text =
      std::string("，路径=") + (gpu_path_ ? "GPU 共享纹理" : "CPU 像素缓冲");
  if (gpu_path_) {
    path_text += "（本帧上传 " + ms_text(last_upload_us_) + "，平均 " +
                 ms_text(average_upload_us) + "）";
  }
  path_text += "，光栅回调 " + std::to_string(raster_callbacks) + "（本秒 +" +
               std::to_string(raster_per_second) + "），队列等待 " +
               ms_text(average_queue_wait_us) + "，队列上限 " +
               std::to_string(kMaxPendingFrames);

  std::string line = "心跳：收到 " + std::to_string(received_frames_.load()) +
                     "，已喂入 " + std::to_string(fed_frames_.load()) +
                     "，已发布 " + std::to_string(published_frames_.load()) +
                     "，丢弃 " + std::to_string(dropped_frames_.load()) +
                     "，队列深度 " + std::to_string(queue_depth) + "，帧间隔 " +
                     ms_text(average_interval_us) + "，平均处理 " +
                     ms_text(average_process_us) + "（解码 " +
                     ms_text(average_mft_us) + " + 换算 " +
                     ms_text(average_convert_us) + "）" + size_text + path_text +
                     "，本帧处理 " + ms_text(last_process_us_) + "，本帧换算 " +
                     ms_text(last_convert_us_) +
                     // 累计失败数放在心跳里：这样"解不出来"不用翻日志也能一眼看到，
                     // 且这些计数本身不会刷屏（心跳是每秒一条）。
                     "，ProcessOutput 失败 " +
                     std::to_string(process_output_failures_) +
                     "（最近 " + HresultText(last_process_output_result_) +
                     "），ProcessOutput 需更多输入 " +
                     std::to_string(process_output_need_more_input_) +
                     "，ProcessInput 失败 " +
                     std::to_string(process_input_failures_) + "，流格式变化 " +
                     std::to_string(stream_change_count_) + " 次" +
                     "，强制重新协商 " +
                     std::to_string(forced_renegotiations_) + " 次" + "，结束=" +
                     (stopping ? "是" : "否");
  if (gap_ms > kHeartbeatStallWarningMs) {
    line = "WARNING 距上一帧已 " + std::to_string(gap_ms) + "ms（阈值 " +
           std::to_string(kHeartbeatStallWarningMs) +
           "ms）：**最常见的原因是设备画面这段时间没有变化**（scrcpy 只在画面变化时发帧，"
           "属正常现象）；其次才是编码器重建中 / 流已停。"
           "队列深度 " +
           std::to_string(queue_depth) + size_text + "，收到 " +
           std::to_string(received_frames_.load()) + "，已发布 " +
           std::to_string(published_frames_.load());
    const long long now_ms = NowMs();
    if (last_stall_warning_at_ms_ >= 0 &&
        now_ms - last_stall_warning_at_ms_ < kWarningRepeatMs) {
      return;  // 异常持续中：按最小间隔抑制重复警告
    }
    last_stall_warning_at_ms_ = now_ms;
  }
  DebugLog(line);
}

bool ScrcpyVideoDecoder::Impl::CreateDecoder() {
  IMFTransform* raw_decoder = nullptr;
  const HRESULT create_result = ::CoCreateInstance(
      CLSID_CMSH264DecoderMFT, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&raw_decoder));
  if (FAILED(create_result) || raw_decoder == nullptr) {
    SetError("创建 H.264 解码器失败（Media Foundation MFT " +
             HresultText(create_result) + "）");
    return false;
  }
  decoder_.Attach(raw_decoder);

  // 有些 MFT 是"异步"的（MF_TRANSFORM_ASYNC = 1）：解锁之后才能用同步的
  // ProcessInput / ProcessOutput 驱动，否则必须走 IMFMediaEventGenerator。
  //
  // **注意取属性的方式**：要用 `IMFTransform::GetAttributes`。
  // 原来这里用 `QueryInterface(IID_PPV_ARGS(&attributes))`——对这个解码器 MFT **拿不到**
  // （于是下面整段都没执行，我加的低延迟开关也一起没生效，日志里连那行都没有）。
  // 离线探针里用的就是 GetAttributes，一次成功；所以这里两种都试，优先 GetAttributes。
  IMFAttributes* raw_attributes = nullptr;
  if (FAILED(decoder_->GetAttributes(&raw_attributes)) ||
      raw_attributes == nullptr) {
    if (FAILED(decoder_->QueryInterface(IID_PPV_ARGS(&raw_attributes))) ||
        raw_attributes == nullptr) {
      raw_attributes = nullptr;
    }
  }
  if (raw_attributes != nullptr) {
    ComPtr<IMFAttributes> attributes;
    attributes.Attach(raw_attributes);
    UINT32 is_async = 0;
    if (SUCCEEDED(attributes->GetUINT32(MF_TRANSFORM_ASYNC, &is_async)) &&
        is_async != 0) {
      attributes->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
    }

    // ★★ **低延迟模式：真机"全黑 + 时不时卡几秒"的根因就是这个开关**（2026-10-01）★★
    //
    // 不设它时，这个 H.264 解码器 MFT 会**缓冲约 1.2 秒**（30fps ≈ **38 帧**）才吐第一张图。
    // 离线回放（tools\run_mft_replay_probe.cmd，真实抓包 43 帧）实测：
    //     不设 MF_LOW_LATENCY ：已发布  8/43 帧，首帧出现在第 **38** 帧
    //     设 MF_LOW_LATENCY   ：已发布 42/43 帧，首帧出现在第 **1** 帧
    // 一个原因解释掉用户报的全部现象：
    //   * 画面静止时服务端只给二十来帧（< 38）→ **永远黑屏**（真机第三次就是）；
    //   * 有操作时要先黑 1~3 秒才出第一张；
    //   * 编码器一重建（改 bounds / 重新协商）就再冻几秒、然后一次性追平
    //     —— 用户原话"时不时卡几秒然后才显示出来"；
    //   * 网页端流畅：浏览器解码器没有这层缓冲。
    // **必须在开始流之前设置**（MF 文档：MF_LOW_LATENCY 是创建期属性）。
    // CODECAPI_AVLowLatencyMode 这个 MFT 不支持（返回 E_INVALIDARG），不用管。
    const HRESULT low_latency = attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
    DebugLog(std::string("低延迟模式：MF_LOW_LATENCY 设置结果=") +
             HresultText(low_latency) +
             "（不设它解码器会缓冲约 1.2 秒 ≈ 38 帧，画面静止时直接黑屏，见 §12.8）");
  }

  // 输入类型：H.264 基本流。
  // 不设 MF_NALU_LENGTH_SET，因此样本按 Annex-B 起始码解释（一条消息一个访问单元）。
  IMFMediaType* raw_input_type = nullptr;
  HRESULT result = ::MFCreateMediaType(&raw_input_type);
  ComPtr<IMFMediaType> input_type;
  if (SUCCEEDED(result)) {
    input_type.Attach(raw_input_type);
    result = input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  }
  if (SUCCEEDED(result)) {
    result = input_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  }
  if (SUCCEEDED(result)) {
    result = decoder_->SetInputType(kInputStreamId, input_type.Get(), 0);
  }
  if (FAILED(result)) {
    SetError("设置解码器输入类型（H.264/Annex-B）失败：" + HresultText(result));
    return false;
  }
  return true;
}

bool ScrcpyVideoDecoder::Impl::TrySelectOutputType() {
  if (!decoder_) {
    return false;
  }
  // 逐个试可用的输出类型，挑一个"我们能转成 RGBA"的 4:2:0 格式。
  for (int index = 0; index < 32; ++index) {
    IMFMediaType* raw_type = nullptr;
    const HRESULT available = decoder_->GetOutputAvailableType(
        kOutputStreamId, static_cast<DWORD>(index), &raw_type);
    if (FAILED(available) || raw_type == nullptr) {
      // MF_E_NO_MORE_TYPES，或者解码器还没解析出参数集（还没法给出输出类型）。
      return false;
    }
    ComPtr<IMFMediaType> type;
    type.Attach(raw_type);

    GUID subtype = {};
    if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype))) {
      continue;
    }
    if (!IsEqualGUID(subtype, MFVideoFormat_NV12) &&
        !IsEqualGUID(subtype, MFVideoFormat_YV12) &&
        !IsEqualGUID(subtype, MFVideoFormat_IYUV)) {
      continue;
    }
    UINT32 width = 0;
    UINT32 height = 0;
    if (FAILED(::MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width,
                                    &height)) ||
        width == 0 || height == 0) {
      continue;
    }
    if (FAILED(decoder_->SetOutputType(kOutputStreamId, type.Get(), 0))) {
      continue;
    }

    // 行跨距可能带对齐（也可能为负 = 自下而上）。
    // 优先信 MF_MT_DEFAULT_STRIDE；它没给就按像素格式问系统要，**不要**假设等于宽度。
    LONG stride = 0;
    UINT32 raw_stride = 0;
    if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &raw_stride)) &&
        raw_stride != 0) {
      stride = static_cast<LONG>(raw_stride);
    } else if (FAILED(::MFGetStrideForBitmapInfoHeader(subtype.Data1, width,
                                                       &stride)) ||
               stride == 0) {
      stride = static_cast<LONG>(width);
    }
    const size_t absolute_stride =
        static_cast<size_t>(stride < 0 ? -stride : stride);

    // 解码器不提供输出样本，必须由我们给：容量取"布局真实需求"与 MFT 要求值的较大者。
    //
    // 注意这里**不再**手写 `stride * height * 3 / 2`：那是偶数高度的巧合值，853 这种
    // 奇数高度会少算半行（同一个坑在换算侧崩过一次）。统一走纯函数（§12.3）。
    MFT_OUTPUT_STREAM_INFO stream_info = {};
    if (FAILED(decoder_->GetOutputStreamInfo(kOutputStreamId, &stream_info))) {
      continue;
    }
    const Yuv420Layout layout = WsLayoutForSubtype(subtype);
    const size_t required_bytes =
        WsRequiredOutputBytes(layout, absolute_stride, width, height,
                              stream_info.cbSize);
    if (required_bytes == 0 || required_bytes > 0xFFFFFFFFull) {
      continue;
    }

    // **不在这里创建输出样本**：只记住容量。每次 ProcessOutput 都现造一个干净的
    // 样本——复用旧样本（其上还留着上一帧的 CurrentLength 与解码器写过的属性）
    // 正是 `0x80004005` 洪水的根因，见 AGENTS §12.6。
    output_buffer_bytes_ = static_cast<DWORD>(required_bytes);
    output_subtype_ = subtype;
    output_stride_ = absolute_stride;
    output_bottom_up_ = stride < 0;
    output_width_ = width;
    output_height_ = height;
    output_type_set_ = true;

    const bool renegotiated = output_type_negotiated_once_;
    char description[224] = {};
    std::snprintf(description, sizeof(description),
                  "输出类型就绪：%ux%u stride=%llu 缓冲=%llu 格式=%s（%s）",
                  static_cast<unsigned int>(width),
                  static_cast<unsigned int>(height),
                  static_cast<unsigned long long>(absolute_stride),
                  static_cast<unsigned long long>(required_bytes),
                  layout == Yuv420Layout::kNv12
                      ? "NV12"
                      : (layout == Yuv420Layout::kYv12 ? "YV12" : "IYUV/I420"),
                  renegotiated ? "中途重新协商" : "首次协商");
    DebugLog(description);
    output_type_negotiated_once_ = true;
    LogOnce("first-output-type",
            "首次输出类型协商完成：宽高 " + std::to_string(width) + "x" +
                std::to_string(height) + "，输出缓冲大小 " +
                std::to_string(required_bytes) + " 字节，格式 " +
                (layout == Yuv420Layout::kNv12
                     ? "NV12"
                     : (layout == Yuv420Layout::kYv12 ? "YV12" : "IYUV/I420")));
    ApplySize(width, height);
    return true;
  }
  return false;
}

void ScrcpyVideoDecoder::Impl::ReinitializeInputType(
    const std::vector<uint8_t>& sequence_header) {
  if (!decoder_ || sequence_header.empty()) {
    return;
  }
  // 兜底路径：把 SPS/PPS 作为 MF_MT_MPEG_SEQUENCE_HEADER 写进输入类型，解码器据此
  // 立刻就能给出真实分辨率的输出类型。协议里 SPS/PPS 恰好是单独一条消息先到
  // （docs/ws-scrcpy-protocol.md §4.4），这里天然拿得到。
  // 正常路径不靠它：先让解码器自己从码流里解析参数集（见 DecodeThreadMain）。
  IMFMediaType* raw_input_type = nullptr;
  HRESULT result = ::MFCreateMediaType(&raw_input_type);
  ComPtr<IMFMediaType> input_type;
  if (SUCCEEDED(result)) {
    input_type.Attach(raw_input_type);
    result = input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  }
  if (SUCCEEDED(result)) {
    result = input_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  }
  if (SUCCEEDED(result)) {
    result = input_type->SetBlob(
        MF_MT_MPEG_SEQUENCE_HEADER, sequence_header.data(),
        static_cast<UINT32>(sequence_header.size()));
  }
  if (FAILED(result)) {
    DebugLog("组装带 SPS/PPS 的输入类型失败：" + HresultText(result));
    return;
  }

  // 改输入类型前先 FLUSH：此时还没产出过任何帧，等价于重新开始。
  decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
  streaming_started_ = false;
  output_type_set_ = false;
  output_buffer_bytes_ = 0;

  const HRESULT applied =
      decoder_->SetInputType(kInputStreamId, input_type.Get(), 0);
  if (FAILED(applied)) {
    // 补不上也不致命：参数集本来就在码流里，仍可能靠 in-band 路径协商出输出类型。
    DebugLog("设置带 SPS/PPS 的输入类型失败：" + HresultText(applied));
    return;
  }
  DebugLog("已把 SPS/PPS 写入解码器输入类型");
}

void ScrcpyVideoDecoder::Impl::NotifyStreamingStarted() {
  if (streaming_started_ || !decoder_) {
    return;
  }
  // **输出类型没定下来之前绝不发 BEGIN_STREAMING**（§12.8 的修正）。
  //
  // MSDN 要求的顺序是 SetInputType → SetOutputType → NOTIFY_BEGIN_STREAMING →
  // NOTIFY_START_OF_STREAM → ProcessInput。旧实现在输出类型还没定时就发了
  // BEGIN_STREAMING（它居然返回 S_OK），于是解码器进入"接受输入但永不产出"的状态：
  // 真机日志里 13 帧（含 IDR）全部喂入、输出 0 帧、且 ProcessInput/ProcessOutput
  // **一个错误都不报**，心跳只能看到 `已喂入 13 / 已发布 0`。
  if (!output_type_set_) {
    if (!streaming_notify_logged_) {
      streaming_notify_logged_ = true;
      DebugLog("BEGIN_STREAMING 推迟到输出类型定下来之后（当前还没协商出类型）");
    }
    return;
  }
  const HRESULT result =
      decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  if (SUCCEEDED(result)) {
    decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    streaming_started_ = true;
    LogOnce("first-begin-streaming",
            "已在输出类型就绪后发送 BEGIN_STREAMING / START_OF_STREAM");
    return;
  }
  if (!streaming_notify_logged_) {
    streaming_notify_logged_ = true;
    DebugLog("BEGIN_STREAMING 失败：" + HresultText(result));
  }
}

bool ScrcpyVideoDecoder::Impl::FeedFrame(const std::vector<uint8_t>& frame, LONGLONG timestamp) {
  if (!decoder_ || frame.empty()) {
    return false;
  }
  IMFSample* raw_sample = nullptr;
  HRESULT result = ::MFCreateSample(&raw_sample);
  ComPtr<IMFSample> sample;
  if (SUCCEEDED(result) && raw_sample != nullptr) {
    sample.Attach(raw_sample);
    IMFMediaBuffer* raw_buffer = nullptr;
    result = ::MFCreateMemoryBuffer(static_cast<DWORD>(frame.size()),
                                    &raw_buffer);
    if (SUCCEEDED(result) && raw_buffer != nullptr) {
      ComPtr<IMFMediaBuffer> buffer;
      buffer.Attach(raw_buffer);
      BYTE* destination = nullptr;
      result = buffer->Lock(&destination, nullptr, nullptr);
      if (SUCCEEDED(result) && destination != nullptr) {
        std::memcpy(destination, frame.data(), frame.size());
        buffer->Unlock();
        result = buffer->SetCurrentLength(static_cast<DWORD>(frame.size()));
      }
      if (SUCCEEDED(result)) {
        result = sample->AddBuffer(buffer.Get());
      }
    }
  }
  if (SUCCEEDED(result)) {
    result = sample->SetSampleTime(timestamp);
  }
  if (SUCCEEDED(result)) {
    result = sample->SetSampleDuration(kFrameDurationHns);
  }
  if (FAILED(result)) {
    DebugLog("组装输入样本失败：" + HresultText(result));
    return false;
  }

  // MF_E_NOTACCEPTING / MF_E_TRANSFORM_TYPE_NOT_SET 都是"现在不行，先取走输出再试"
  // 的正常反馈，不是错误。
  for (int attempt = 0; attempt < 4; ++attempt) {
    const HRESULT input_result =
        decoder_->ProcessInput(kInputStreamId, sample.Get(), 0);
    if (input_result == MF_E_NOTACCEPTING) {
      if (!DrainOutput()) {
        return false;
      }
      continue;
    }
    if (input_result == MF_E_TRANSFORM_TYPE_NOT_SET) {
      if (!TrySelectOutputType()) {
        return false;
      }
      continue;
    }
    if (FAILED(input_result)) {
      ++process_input_failures_;
      LogFailureThrottled("process-input",
                          "ProcessInput 失败：" + HresultText(input_result));
      return false;
    }
    return true;
  }
  return false;
}

bool ScrcpyVideoDecoder::Impl::DrainOutput() {
  if (!decoder_) {
    return false;
  }
  // 一次输入可能产出多帧（B 帧重排时），所以循环取到"还缺输入"为止。
  for (int guard = 0; guard < 32; ++guard) {
    if (!output_type_set_ || output_buffer_bytes_ == 0) {
      return true;  // 还没有可用输出类型：等更多输入
    }
    // **每一轮都现造一个干净的输出样本**（不是复用上一帧那个）。
    //
    // 修复前的写法是"复用同一个样本：RemoveAllBuffers + AddBuffer 回去"。那个样本
    // 上还留着上一帧的 `IMFMediaBuffer::CurrentLength`（我们只读、从不复位），于是
    // 抛给解复用器的就是"一个已经装满数据的样本"。实测后果：**首个样本成功，
    // 之后每一次 ProcessOutput 都返回 0x80004005（E_FAIL）**——日志里
    // `已解码 1` 卡住、几千行 E_FAIL 洪水就是这么来的（见 AGENTS §12.6）。
    ComPtr<IMFSample> sample = MakeOutputSample(output_buffer_bytes_);
    if (!sample) {
      LogFailureThrottled("make-output-sample",
                          "创建输出样本失败（MFCreateSample/MFCreateMemoryBuffer）");
      return false;
    }
    MFT_OUTPUT_DATA_BUFFER output = {};
    output.dwStreamID = kOutputStreamId;
    output.pSample = sample.Get();
    DWORD status = 0;
    const HRESULT result = decoder_->ProcessOutput(0, 1, &output, &status);
    if (output.pEvents != nullptr) {
      output.pEvents->Release();
      output.pEvents = nullptr;
    }
    if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) {
      ++process_output_need_more_input_;
      return true;  // 正常：还需要更多输入才能出下一帧
    }
    if (result == MF_E_TRANSFORM_STREAM_CHANGE) {
      // 流格式变了（投流中设备旋转 / 编码参数变化 / 编码器重启）：必须重新协商输出类型，
      // 并按新类型重建输出样本的容量；**帧可以丢，但状态机不能卡死**。
      ++stream_change_count_;
      const uint32_t old_width = output_width_;
      const uint32_t old_height = output_height_;
      output_type_set_ = false;
      output_buffer_bytes_ = 0;
      DebugLog("解码器报告流格式变化（第 " + std::to_string(stream_change_count_) +
               " 次，上一次输出 " + std::to_string(old_width) + "x" +
               std::to_string(old_height) + "）：重新协商输出类型");
      if (!TrySelectOutputType()) {
        // 新参数集还没被解析出来时确实拿不到类型：保持"未协商"状态、等后续帧重试即可，
        // 这不是致命错误（以前这里也是 return true，但日志没有任何痕迹）。
        LogFailureThrottled(
            "stream-change-no-type",
            "流格式变化后暂时协商不出输出类型（等参数集 / 更多输入）");
        return true;
      }
      continue;
    }
    if (result == MF_E_TRANSFORM_TYPE_NOT_SET) {
      if (!TrySelectOutputType()) {
        return true;
      }
      continue;
    }
    if (FAILED(result)) {
      ++process_output_failures_;
      ++consecutive_process_output_failures_;
      last_process_output_result_ = result;
      LogFailureThrottled(
          "process-output",
          "ProcessOutput 失败：" + HresultText(result) + "（输出 " +
              std::to_string(output_width_) + "x" +
              std::to_string(output_height_) + " stride=" +
              std::to_string(output_stride_) + " 缓冲=" +
              std::to_string(output_buffer_bytes_) + " 字节 dwStatus=" +
              std::to_string(status) + "）");
      // 自愈：连续失败说明"当前输出类型与码流不符"（或者类型被中途改坏了），
      // 强制重新协商一次，而不是一辈子喂帧却一帧都解不出来。
      if (consecutive_process_output_failures_ >=
          kConsecutiveOutputFailuresBeforeRenegotiate) {
        consecutive_process_output_failures_ = 0;
        ++forced_renegotiations_;
        DebugLog("连续 " +
                 std::to_string(kConsecutiveOutputFailuresBeforeRenegotiate) +
                 " 次 ProcessOutput 失败（第 " +
                 std::to_string(forced_renegotiations_) +
                 " 次强制重新协商）：判定输出类型与码流不符，FLUSH 后重写 SPS/PPS "
                 "并重选输出类型");
        ForceRenegotiate();
      }
      return false;
    }
    consecutive_process_output_failures_ = 0;
    PresentOutput(sample);
  }
  return true;
}

// 造一个**干净**的输出样本：新 sample + 新 buffer，容量按协商结果。
ComPtr<IMFSample> ScrcpyVideoDecoder::Impl::MakeOutputSample(DWORD bytes) const {
  IMFSample* raw_sample = nullptr;
  if (FAILED(::MFCreateSample(&raw_sample)) || raw_sample == nullptr) {
    return ComPtr<IMFSample>();
  }
  ComPtr<IMFSample> sample;
  sample.Attach(raw_sample);
  IMFMediaBuffer* raw_buffer = nullptr;
  if (FAILED(::MFCreateMemoryBuffer(bytes, &raw_buffer)) || raw_buffer == nullptr) {
    return ComPtr<IMFSample>();
  }
  ComPtr<IMFMediaBuffer> buffer;
  buffer.Attach(raw_buffer);
  if (FAILED(sample->AddBuffer(buffer.Get()))) {
    return ComPtr<IMFSample>();
  }
  return sample;
}

// 强制重新协商输出类型：FLUSH → 重写 SPS/PPS 到输入类型 → 重选输出类型。
//
// 只在"连续多次 ProcessOutput 失败"时调用：正常情况下协商一次就对了，
// 这条路径是给"选错了 / 被中途改坏"兜底的，保证状态机不会卡死。
void ScrcpyVideoDecoder::Impl::ForceRenegotiate() {
  if (!decoder_) {
    return;
  }
  decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
  streaming_started_ = false;
  output_type_set_ = false;
  output_buffer_bytes_ = 0;
  if (!sequence_header_.empty()) {
    // 允许把同一份参数集再写一次（正常情况下 last_header_attempt_ 会阻止重复写）。
    last_header_attempt_.clear();
    ReinitializeInputType(sequence_header_);
  }
  TrySelectOutputType();
}

// 同类失败限流：前 3 次逐条打，之后每 100 次一条（带累计次数）。
//
// 为什么必须限流：这个 bug 的现场日志里 `ProcessOutput 失败` 刷了几千行，把 2 MB
// 上限写满之后把真正有用的信息挤掉了——失败日志本身变成了新的排查障碍。
void ScrcpyVideoDecoder::Impl::LogFailureThrottled(const std::string& key,
                                                   const std::string& message) {
  const uint64_t count = ++throttled_log_counts_[key];
  if (count <= 3 || (count % 100) == 0) {
    DebugLog(message + "（同类第 " + std::to_string(count) + " 次）");
  }
}

// 一次性把"解码器当前能给出哪些输出类型"写进日志。
//
// 这一行是**区分两类故障**的关键（§12.8）：协商选错了类型，与"解码器根本没认出码流"
// （只肯给 1920x1080 默认类型）在计数器上长得一模一样，只有列出候选类型才能分开。
void ScrcpyVideoDecoder::Impl::LogAvailableOutputTypesOnce() {
  if (logged_available_types_) {
    return;
  }
  logged_available_types_ = true;
  std::string text;
  for (int index = 0; index < 16; ++index) {
    IMFMediaType* raw_type = nullptr;
    if (FAILED(decoder_->GetOutputAvailableType(kOutputStreamId,
                                                static_cast<DWORD>(index),
                                                &raw_type)) ||
        raw_type == nullptr) {
      break;
    }
    ComPtr<IMFMediaType> type;
    type.Attach(raw_type);
    GUID subtype = {};
    UINT32 width = 0;
    UINT32 height = 0;
    const bool described =
        SUCCEEDED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) &&
        SUCCEEDED(::MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width,
                                       &height));
    if (!text.empty()) {
      text += "，";
    }
    text += described ? (std::to_string(width) + "x" + std::to_string(height))
                      : std::string("?");
  }
  DebugLog("解码器可用输出类型：" +
           (text.empty() ? std::string("一个都没有（参数集还没被解析）") : text));
}

// WS_CAPTURE_FRAMES=<路径>：把帧原样 dump 出来，用于离线复现真机问题。
//
// 文件格式（给 tools 里的复现工具读）：
//   8 字节魔数 "WSCAP001"，之后重复 { uint32 小端长度, 该长度的 Annex-B 帧字节 }。
void ScrcpyVideoDecoder::Impl::CaptureFrameIfRequested(const uint8_t* data,
                                                       size_t size) {
  if (data == nullptr || size == 0) {
    return;
  }
  std::lock_guard<std::mutex> lock(capture_mutex_);
  if (!capture_open_attempted_) {
    capture_open_attempted_ = true;
    char path[512] = {};
    const DWORD length = ::GetEnvironmentVariableA(
        "WS_CAPTURE_FRAMES", path, static_cast<DWORD>(sizeof(path)));
    if (length == 0 || length >= sizeof(path)) {
      path[0] = '\0';
      // 退路（上真机时最常用）：exe 同目录放了 `ws_capture.txt` 标记文件，
      // 就自动写到同目录的 `capture.bin`。为什么要有这条：现场常用 IDE / `flutter run`
      // 启动，设环境变量很麻烦；放一个标记文件就能抓，用完删掉即可。
      char module_path[MAX_PATH] = {};
      const DWORD module_length =
          ::GetModuleFileNameA(nullptr, module_path, MAX_PATH);
      if (module_length > 0 && module_length < MAX_PATH) {
        std::string directory(module_path, module_length);
        const size_t slash = directory.find_last_of("\\/");
        directory = slash == std::string::npos ? std::string()
                                               : directory.substr(0, slash + 1);
        const std::string marker = directory + "ws_capture.txt";
        if (!directory.empty() &&
            ::GetFileAttributesA(marker.c_str()) != INVALID_FILE_ATTRIBUTES) {
          const std::string target = directory + "capture.bin";
          std::snprintf(path, sizeof(path), "%s", target.c_str());
        }
      }
    }
    if (path[0] != '\0') {
      // "wb" 而不是追加：每次运行一份干净的抓包，避免与上一次混在一起。
      // 用 fopen_s：MSVC 把 fopen 标成 C4996，而 runner 开着 /W4 /WX。
      FILE* file = nullptr;
      if (fopen_s(&file, path, "wb") == 0) {
        capture_file_ = file;
      }
      if (capture_file_ != nullptr) {
        static const char kMagic[8] = {'W', 'S', 'C', 'A', 'P', '0', '0', '1'};
        std::fwrite(kMagic, 1, sizeof(kMagic), capture_file_);
        DebugLog(std::string("抓帧已开启：") + path +
                 "（格式：WSCAP001 + 重复{uint32 长度, 帧字节}）");
      } else {
        DebugLog(std::string("抓帧失败：打不开 ") + path);
      }
    }
  }
  if (capture_file_ == nullptr || capture_frames_ >= kMaxCaptureFrames) {
    return;
  }
  const uint32_t length = static_cast<uint32_t>(size);
  const uint8_t header[4] = {
      static_cast<uint8_t>(length & 0xFF),
      static_cast<uint8_t>((length >> 8) & 0xFF),
      static_cast<uint8_t>((length >> 16) & 0xFF),
      static_cast<uint8_t>((length >> 24) & 0xFF)};
  std::fwrite(header, 1, sizeof(header), capture_file_);
  std::fwrite(data, 1, size, capture_file_);
  ++capture_frames_;
  if ((capture_frames_ % 30) == 0) {
    std::fflush(capture_file_);
  }
}

void ScrcpyVideoDecoder::Impl::PresentOutput(const ComPtr<IMFSample>& sample) {  if (!sample) {
    return;
  }
  IMFMediaBuffer* raw_buffer = nullptr;
  if (FAILED(sample->GetBufferByIndex(0, &raw_buffer)) ||
      raw_buffer == nullptr) {
    return;
  }
  ComPtr<IMFMediaBuffer> buffer;
  buffer.Attach(raw_buffer);
  BYTE* data = nullptr;
  DWORD current_length = 0;
  if (FAILED(buffer->Lock(&data, nullptr, &current_length)) ||
      data == nullptr) {
    return;
  }
  ConvertAndPublish(data, static_cast<size_t>(current_length));
  buffer->Unlock();
}

void ScrcpyVideoDecoder::Impl::ConvertAndPublish(const uint8_t* data,
                                                 size_t length) {
  const uint32_t width = output_width_;
  const uint32_t height = output_height_;
  if (data == nullptr || width == 0 || height == 0) {
    return;
  }

  // 跨距只认"解码器真正用的那个"：优先 MF_MT_DEFAULT_STRIDE（协商输出类型时读到的），
  // 没给就按像素格式问系统要（MFGetStrideForBitmapInfoHeader），最后才退回 width。
  // **绝不能**假设 pitch == width：带对齐的输出很常见，NV12 的 UV 平面也是按 pitch 排布。
  size_t stride = output_stride_;
  if (stride == 0) {
    LONG derived = 0;
    if (SUCCEEDED(::MFGetStrideForBitmapInfoHeader(
            output_subtype_.Data1, width, &derived)) &&
        derived != 0) {
      stride = static_cast<size_t>(derived < 0 ? -derived : derived);
    }
  }
  if (stride == 0) {
    stride = width;
  }

  // ---- GPU 路：CPU 只做 NV12 重排 + 上传，换算交给像素着色器 ----
  //
  // 限制条件（不满足就走下面的 CPU 路，行为与改动前一致）：
  //   - 只支持 NV12：I420/YV12 的平面布局与 D3D11 的 NV12 纹理不一致，硬塞要自己拼 UV，
  //     而 MFT 的实际输出就是 NV12（I420/YV12 是兼容分支）；
  //   - 不支持自下而上（MF_MT_DEFAULT_STRIDE 为负）：着色器按正常方向取样。
  if (gpu_path_ && presenter_ != nullptr) {
    const bool nv12 = IsEqualGUID(output_subtype_, MFVideoFormat_NV12);
    if (nv12 && !output_bottom_up_) {
      ws_scrcpy::Nv12Frame nv12_frame;
      nv12_frame.data = data;
      nv12_frame.data_bytes = length;
      nv12_frame.pitch = stride;
      nv12_frame.width = width;
      nv12_frame.height = height;
      const auto upload_begin = std::chrono::steady_clock::now();
      const bool published = presenter_->PublishNv12(nv12_frame);
      last_upload_us_ = std::chrono::duration_cast<std::chrono::microseconds>(
                            std::chrono::steady_clock::now() - upload_begin)
                            .count();
      if (!published) {
        // 尺寸还没跟上（等待 ApplySize）或没拿到 keyed mutex：丢这一帧，不阻塞解码线程。
        dropped_frames_.fetch_add(1);
        LogFailureThrottled("gpu-publish",
                            "GPU 上屏失败（丢帧）：" + presenter_->LastError());
        return;
      }
      last_convert_us_ = 0;  // GPU 路没有 CPU 换算
      upload_times_us_.push_back(last_upload_us_);
      while (upload_times_us_.size() > kHeartbeatTimingWindow) {
        upload_times_us_.pop_front();
      }
      FinalizePublish(true);
      return;
    }
    if (!gpu_layout_fallback_logged_) {
      gpu_layout_fallback_logged_ = true;
      DebugLog("GPU 呈现只接受自上而下的 NV12，本帧起回落 CPU 换算：格式 Data1=" +
               HresultText(static_cast<HRESULT>(output_subtype_.Data1)) +
               "，自下而上=" + (output_bottom_up_ ? "是" : "否"));
    }
  }

  const size_t target_bytes = static_cast<size_t>(width) * height * 4;
  if (scratch_.size() != target_bytes) {
    scratch_.assign(target_bytes, 0);
  }

  Yuv420Layout layout = Yuv420Layout::kI420;
  if (IsEqualGUID(output_subtype_, MFVideoFormat_NV12)) {
    layout = Yuv420Layout::kNv12;
  } else if (IsEqualGUID(output_subtype_, MFVideoFormat_YV12)) {
    layout = Yuv420Layout::kYv12;
  }

  // 长度、跨距、宽高的合法性全部交给纯函数判断：它按平面布局与 ceil(height/2)
  // 算出**真实需求**，不够就返回 false（而不是像以前那样硬读越界）。
  const auto convert_begin = std::chrono::steady_clock::now();
  const bool converted =
      ConvertYuv420ToRgba(data, length, layout, stride, width, height,
                          output_bottom_up_, scratch_.data(), scratch_.size());
  last_convert_us_ = std::chrono::duration_cast<std::chrono::microseconds>(
                         std::chrono::steady_clock::now() - convert_begin)
                         .count();
  if (!converted) {
    dropped_frames_.fetch_add(1);
    // 只在"同一组参数"下刷一次，避免每帧刷屏把控制台淹掉。
    const std::string key = "reject-" + std::to_string(width) + "x" +
                            std::to_string(height) + "-" + std::to_string(stride);
    LogOnce(key.c_str(), "拒绝一帧解码输出：宽高 " + std::to_string(width) + "x" +
                             std::to_string(height) + "，跨距 " +
                             std::to_string(stride) + "，缓冲长度 " +
                             std::to_string(length) + "（长度不足或格式不符）");
    return;
  }

  pixel_store_->PublishDecoded(&scratch_);
  convert_times_us_.push_back(last_convert_us_);
  while (convert_times_us_.size() > kHeartbeatTimingWindow) {
    convert_times_us_.pop_front();
  }
  LogOnce("first-converted-frame",
          "首次换算成功：宽高 " + std::to_string(width) + "x" +
              std::to_string(height) + "，跨距 " + std::to_string(stride) +
              "，输入长度 " + std::to_string(length) + "，RGBA 字节 " +
              std::to_string(scratch_.size()));
  FinalizePublish(false);
}

// 两条呈现路径的公共收尾：计数、"首帧"锚点日志、通知引擎取新帧。
void ScrcpyVideoDecoder::Impl::FinalizePublish(bool gpu_path) {
  published_frames_.fetch_add(1);
  RecordDecoded();
  if (gpu_path) {
    LogOnce("first-gpu-frame",
            "首帧已用 GPU 共享纹理上屏：宽高 " + std::to_string(output_width_) +
                "x" + std::to_string(output_height_) + "，跨距 " +
                std::to_string(output_stride_) + "，本帧上传 " +
                std::to_string(last_upload_us_ / 1000) + "ms（无 CPU 换算）");
  } else {
    // 保留原有的"首帧解出"一次性日志（排查时按这几行找）。
    LogOnce("first-decoded-frame",
            "已解出第一帧并发布：" + std::to_string(output_width_) + "x" +
                std::to_string(output_height_) + " stride=" +
                std::to_string(output_stride_));
  }
  if (texture_id_ >= 0 && texture_registrar_ != nullptr) {
    LogOnce("first-mark-available",
            std::string("首次 MarkTextureFrameAvailable：textureId=") +
                std::to_string(texture_id_) +
                (gpu_path ? "（GPU 共享纹理）" : "（像素缓冲）"));
    texture_registrar_->MarkTextureFrameAvailable(texture_id_);
  }
}

void ScrcpyVideoDecoder::Impl::ApplySize(uint32_t width, uint32_t height) {
  if (width == 0 || height == 0) {
    return;
  }
  if (width == current_width_ && height == current_height_) {
    return;
  }
  const uint32_t previous_width = current_width_;
  const uint32_t previous_height = current_height_;
  current_width_ = width;
  current_height_ = height;
  // 通道层靠这个拉取当前尺寸（create / pushFrame 的回执），**不再**由这里回调出去。
  size_state_.Set(width, height);
  pixel_store_->Resize(width, height, &scratch_);
  if (gpu_path_ && presenter_ != nullptr) {
    // GPU 路：重建 NV12 与共享纹理（会换一个新的共享句柄），失败只记日志：
    // 下一帧 GPU 上屏会失败并被限流记录，画面停在上一帧，不会崩。
    if (!presenter_->Resize(width, height)) {
      DebugLog("GPU 呈现重建纹理失败：" + presenter_->LastError());
    }
  }
  if (texture_id_ >= 0 && texture_registrar_ != nullptr) {
    // 尺寸变了也要让引擎重新取一次缓冲，否则纹理还停在旧尺寸上。
    texture_registrar_->MarkTextureFrameAvailable(texture_id_);
  }
  DebugLog(std::string("尺寸变化(") + (gpu_path_ ? "GPU 共享纹理" : "像素缓冲") +
           "与 Dart 回执)：" + std::to_string(previous_width) + "x" +
           std::to_string(previous_height) + " → " + std::to_string(width) + "x" +
           std::to_string(height) + "（Dart 侧下次回执/主动 getSize 时生效）");
}

void ScrcpyVideoDecoder::Impl::SetError(const std::string& message) {
  std::lock_guard<std::mutex> lock(init_mutex_);
  last_error_ = message;
  DebugLog("错误：" + message);
}

ScrcpyVideoDecoder::ScrcpyVideoDecoder(
    flutter::TextureRegistrar* texture_registrar,
    ws_scrcpy::DecoderStartupTimings startup)
    : impl_(std::make_unique<Impl>(texture_registrar, startup)) {}

// 析构必须写在这里（而不是头文件里的 `= default`）：`Impl` 是不完整类型时
// `unique_ptr<Impl>` 的删除器没法实例化；本 .cpp 里 Impl 已经完整定义，没问题。
ScrcpyVideoDecoder::~ScrcpyVideoDecoder() = default;

int64_t ScrcpyVideoDecoder::Start() {
  return impl_->Start();
}

void ScrcpyVideoDecoder::PushFrame(const uint8_t* data, size_t size) {
  impl_->PushFrame(data, size);
}

ws_scrcpy::DecoderSize ScrcpyVideoDecoder::CurrentSize() const {
  return impl_->CurrentSize();
}

void ScrcpyVideoDecoder::Release() {
  impl_->Release();
}

std::string ScrcpyVideoDecoder::LastError() const {
  return impl_->LastError();
}
