#ifndef RUNNER_D3D11_VIDEO_PRESENTER_H_
#define RUNNER_D3D11_VIDEO_PRESENTER_H_

#include <flutter_texture_registrar.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// Windows 端的 GPU 呈现路径：把解码器输出的 NV12 直接交给 GPU 转成 RGBA，
// 再以 DXGI 共享纹理的形式交给 Flutter 引擎（`flutter::GpuSurfaceTexture`）。
//
// 为什么要有它（与 Android / 网页端的差距）：
//   - Android：MediaCodec → SurfaceProducer，**解码器直接写 GPU 纹理**，零 CPU 像素操作；
//   - 网页端：浏览器 GPU 解码 + GPU 合成；
//   - 本仓库原来的 Windows 实现：MF 解出 NV12 → **CPU 整帧转 RGBA** → 每帧把整帧 RGBA
//     交给引擎走 `glTexImage2D`（见 yuv_to_rgba.cpp / scrcpy_pixel_store.cpp）。
//     720p 每帧要写 3.7MB，1080p 8.3MB，且上传与合成都在光栅线程上。
// 这条 GPU 路把 CPU 侧成本降到"一次约 1.4MB 的 NV12 重排 + 上传"（720p），
// 换算交给像素着色器做——与 Android/web 的结构对齐。
//
// 与 Flutter 的契约（逐条来自 windows/flutter/ephemeral/flutter_texture_registrar.h）：
//   1) `FlutterDesktopGpuSurfaceDescriptor.struct_size` 必须是结构体大小；
//   2) `handle` 用 `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` 时是 DXGI 共享句柄；
//      引擎侧走 ANGLE 的共享句柄路径，用的是**传统 `IDXGIResource::GetSharedHandle`**
//      （证据：flutter_windows.dll 里 ANGLE 的报错串 `-Failed to open share handle, `
//      与 `Invalid texture parameters in share handle texture.`，以及本头文件注释里
//      指向 GetSharedHandle 的文档链接）；
//   3) 句柄在"被引擎打开"之前必须保持有效 → 描述符由本类分配、`release_callback` 里回收，
//      且纹理对象在换尺寸时进入 retired 列表，不立刻销毁；
//   4) `format` 用 `kFlutterDesktopPixelFormatRGBA8888`，且共享纹理必须是
//      `DXGI_FORMAT_R8G8B8A8_UNORM`：真机实测引擎**只接受 GL_RGBA8**，给 BGRA 会被直接拒收
//      （`embedder_external_texture_gl.cc` 的 "Only support GL_RGBA8 format now"）。
//      着色器把 (R,G,B,A) 写进 SV_Target，对 RGBA8 目标字节序天然正确。
//
// 同步（keyed mutex，默认开）：共享纹理按 `D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX` 创建，
// 我们写入前 `AcquireSync(0, timeout)`、写完 `ReleaseSync(0)`。取不到锁就**丢掉这一帧**
// （宁可掉帧也不把解码线程堵死）。若真机上这条路表现异常，可用环境变量关掉它做 A/B：
//   WS_SCRCPY_GPU=0            完全回退 CPU 路（不建 D3D11 设备）
//   WS_SCRCPY_GPU_SYNC=none    用普通 SHARED 纹理（无 keyed mutex）
//   WS_SCRCPY_GPU_HANDLE=nth   改用 `IDXGIResource1::CreateSharedHandle`（NTHANDLE）
// 三个开关都会被写进日志，排查时先看那条 "GPU 呈现已就绪" 日志。
//
// 线程模型：
//   - `Create` / `Resize` / `PublishNv12` / `Release` 都在**解码线程**上调用（D3D11
//     即时上下文不是线程安全的，这里靠 `render_mutex_` 串行化）；
//   - `ObtainDescriptor` 由**光栅线程**调用，只读一份快照，不碰 D3D11 对象；
//   - 任何线程都可以读 `ready()` / `LastError()` 这类状态。
//
// 本文件**不依赖 Flutter 的 C++ wrapper**（只用了 C 头），因此
// `tools/d3d11_present_test.cpp` 能直接链接本类做离线数值自测（见 AGENTS.md §12.8）。

namespace ws_scrcpy {

/// 一帧 NV12 的来源描述（跨距与尺寸都取自解码器协商出来的输出类型）。
struct Nv12Frame {
  const uint8_t* data = nullptr;
  size_t data_bytes = 0;
  size_t pitch = 0;  // 解码器真正使用的行跨距（Y 与 UV 平面共用）
  uint32_t width = 0;
  uint32_t height = 0;
};

/// GPU 呈现路径的可选开关（默认值即推荐值；环境变量可覆盖，见文件头注释）。
struct PresenterOptions {
  bool enabled = false;     // 是否启用 GPU 路（false = 直接用 CPU 路；真机第三次全黑后默认关）
  bool keyed_mutex = true;  // 共享纹理是否带 keyed mutex 同步
  bool nth_handle = false;  // 是否改用 NTHANDLE（默认传统 GetSharedHandle）

  /// 选哪块适配器：空串/`auto` = 优先核显；`0`/`1`… = 索引；`intel`/`amd`/`nvidia` = 按名字。
  std::string adapter_hint = "auto";

  /// 从环境变量读覆盖项（WS_SCRCPY_GPU / _SYNC / _HANDLE / _ADAPTER）。
  static PresenterOptions FromEnvironment();
};

class D3d11VideoPresenter {
 public:
  D3d11VideoPresenter();
  ~D3d11VideoPresenter();

  D3d11VideoPresenter(const D3d11VideoPresenter&) = delete;
  D3d11VideoPresenter& operator=(const D3d11VideoPresenter&) = delete;

  /// 建 D3D11 设备 + 着色器 + 纹理（含共享句柄）。失败返回 false，原因见 LastError()。
  bool Create(uint32_t width, uint32_t height, const PresenterOptions& options);

  /// 尺寸变化时重建纹理与共享句柄；尺寸没变是空操作。只能在解码线程上调用。
  bool Resize(uint32_t width, uint32_t height);

  /// 上传一帧 NV12 并在 GPU 上转成 RGBA 画进共享纹理。
  /// 返回 false 表示这一帧没上屏（尺寸不符 / 重排失败 / 没拿到 keyed mutex）。
  bool PublishNv12(const Nv12Frame& frame);

  /// 释放设备与纹理；可重复调用。
  void Release();

  bool ready() const;

  /// 物理尺寸（已向上对齐到偶数；D3D11 的 NV12 纹理要求偶数宽高）。
  uint32_t physical_width() const;
  uint32_t physical_height() const;

  /// 可见尺寸（真实解码尺寸，可能是奇数，例如 1898x853）。
  uint32_t visible_width() const;
  uint32_t visible_height() const;

  /// 适配器名（日志用；拿不到时是空串）。
  std::string device_name() const;

  /// 最近一次失败的可读原因。
  std::string LastError() const;

  /// 本次是否启用了 keyed mutex / NTHANDLE（日志与自检用）。
  bool keyed_mutex_enabled() const;
  bool nth_handle_enabled() const;

  /// 当前共享句柄（0 表示还没就绪）。仅供日志与自检。
  uint64_t shared_handle_value() const;

  /// 引擎（光栅线程）来取描述符的次数。
  ///
  /// 与 CPU 像素路的 `PixelBufferStore::raster_callbacks()` 同一个口径：心跳里拿它跟
  /// "已发布"对比，就能判断瓶颈在我们这一侧还是引擎侧（判据见 AGENTS.md §12.8）。
  uint64_t descriptor_callbacks() const;

  /// Flutter 的 GPU 表面回调：每次调用分配一份描述符，引擎打开句柄后回调里回收。
  const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor();

  /// 组装 GPU 表面配置（给 `flutter::GpuSurfaceTexture` 用）。
  FlutterDesktopGpuSurfaceTextureConfig Config();

  /// 仅自测用：把当前共享纹理拷回 CPU（紧凑 RGBA8888，物理尺寸）。
  bool ReadbackForTest(std::vector<uint8_t>* out);

  /// 仅自测用：把任意跨距的 NV12 重排成 D3D11 `UpdateSubresource` 需要的紧凑布局
  /// （Y 平面 physical_height 行，UV 平面 physical_height/2 行，行跨距都是 physical_width，
  /// 越界与尺寸不符一律拒绝——复用 yuv_to_rgba 里那份校验，不维护第二份业务逻辑）。
  static bool PackNv12(const Nv12Frame& frame, uint32_t physical_width,
                       uint32_t physical_height, std::vector<uint8_t>* out);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace ws_scrcpy

#endif  // RUNNER_D3D11_VIDEO_PRESENTER_H_
