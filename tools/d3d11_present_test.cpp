// 自测：Windows GPU 呈现路（d3d11_video_presenter.cpp）。
//
// 为什么这个自测值钱：D3D11 共享纹理这条路**没法在真机上边猜边改**（一次真机往返
// 就是几分钟到几十分钟），而它有两个可离线验证的硬指标：
//   1) NV12 重排（任意跨距 → D3D11 需要的紧凑布局），纯 CPU，可逐字节断言；
//   2) GPU 着色器换算的**数值**：合成一帧 NV12 → 走真实呈现器 → 把共享纹理拷回 CPU，
//      与 CPU 参考实现 ConvertYuv420ToRgba 逐像素比对。
// 第 2 条特别重要：它同时验证了设备创建、NV12 平面视图（R8 / R8G8）、着色器、
// B8G8R8A8 渲染目标与 BGRA 字节序——**任何一处写错都会体现在像素值上**。
//
// 覆盖：偶数尺寸、奇数高度（1898x853，真机上出现过）、行跨距带对齐（stride > width）、
// 极小尺寸（3x3）、尺寸重建（Resize）、以及非法输入必须被拒绝。
//
// 用法：tools\run_d3d11_present_test.cmd

#include "../windows/runner/d3d11_video_presenter.h"
#include "../windows/runner/decoder_log.h"
#include "../windows/runner/yuv_to_rgba.h"

// windows.h 的 min/max 宏会把 std::min/std::max 打坏（本文件自己编译，没有 CMake 的 NOMINMAX）。
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <d3d11.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

int g_checks = 0;
int g_failures = 0;
int g_gpu_checks = 0;

void Expect(bool condition, const std::string& what) {
  ++g_checks;
  if (!condition) {
    ++g_failures;
    std::printf("  FAIL  %s\n", what.c_str());
  }
}

// 确定性填充（LCG）：两次运行、两条路径看到的字节完全一样。
struct Random {
  uint32_t state = 0x1234567u;
  uint8_t Next() {
    state = state * 1664525u + 1013904223u;
    return static_cast<uint8_t>(state >> 24);
  }
};

struct Nv12Source {
  uint32_t width = 0;
  uint32_t height = 0;
  size_t pitch = 0;
  std::vector<uint8_t> bytes;
};

// 造一帧 NV12：Y 平面 height 行、UV 平面 ceil(height/2) 行交错，(U,V) 成对。
// 每行只填 width（UV 是 ceil(width/2)*2）字节，行内 padding 填 0xEE —— 这样
// "重排时错把 padding 当像素拷进去"这类错误会让比对立刻失败。
Nv12Source MakeNv12(uint32_t width, uint32_t height, size_t pitch, uint32_t seed) {
  Nv12Source source;
  source.width = width;
  source.height = height;
  source.pitch = pitch;
  const size_t chroma_rows = (static_cast<size_t>(height) + 1) / 2;
  const size_t y_bytes = pitch * height;
  const size_t chroma_bytes = pitch * chroma_rows;
  source.bytes.assign(y_bytes + chroma_bytes, 0xEE);

  Random random;
  random.state = seed;
  const size_t y_row_bytes = std::min<size_t>(width, pitch);
  for (uint32_t row = 0; row < height; ++row) {
    uint8_t* line = source.bytes.data() + static_cast<size_t>(row) * pitch;
    for (size_t column = 0; column < y_row_bytes; ++column) {
      line[column] = random.Next();
    }
  }
  uint8_t* chroma = source.bytes.data() + y_bytes;
  const size_t chroma_row_bytes =
      std::min<size_t>((static_cast<size_t>(width) + 1) / 2 * 2, pitch);
  for (size_t row = 0; row < chroma_rows; ++row) {
    uint8_t* line = chroma + row * pitch;
    for (size_t index = 0; index < chroma_row_bytes; ++index) {
      line[index] = random.Next();
    }
  }
  return source;
}

ws_scrcpy::Nv12Frame AsFrame(const Nv12Source& source) {
  ws_scrcpy::Nv12Frame frame;
  frame.data = source.bytes.data();
  frame.data_bytes = source.bytes.size();
  frame.pitch = source.pitch;
  frame.width = source.width;
  frame.height = source.height;
  return frame;
}

// 纯 CPU：PackNv12 的字节级断言。
void CheckPack() {
  std::printf("== PackNv12（纯 CPU，逐字节） ==\n");
  const Nv12Source source = MakeNv12(6, 4, 8, 7);
  std::vector<uint8_t> packed;
  Expect(ws_scrcpy::D3d11VideoPresenter::PackNv12(AsFrame(source), 8, 4, &packed),
         "PackNv12 接受 stride(8) > width(6) 的输入");
  Expect(packed.size() == 8u * 4 * 3 / 2, "PackNv12 输出大小 = physical_w*physical_h*3/2");
  if (packed.size() == 8u * 4 * 3 / 2) {
    bool y_ok = true;
    bool padding_zero = true;
    for (uint32_t row = 0; row < 4; ++row) {
      const uint8_t* expected = source.bytes.data() + static_cast<size_t>(row) * 8;
      const uint8_t* actual = packed.data() + static_cast<size_t>(row) * 8;
      if (std::memcmp(expected, actual, 6) != 0) {
        y_ok = false;
      }
      // 可见列(6)之后的两个字节是物理 padding，必须是 0（不能把源行 padding 抄进来）。
      if (actual[6] != 0 || actual[7] != 0) {
        padding_zero = false;
      }
    }
    Expect(y_ok, "Y 平面逐行复制正确（按源跨距取 6 列）");
    Expect(padding_zero, "Y 平面物理 padding 清零（没有把源行 padding 抄进来）");

    const uint8_t* uv_expected = source.bytes.data() + 8u * 4;
    const uint8_t* uv_actual = packed.data() + 8u * 4;
    Expect(std::memcmp(uv_expected, uv_actual, 6) == 0, "UV 平面第一行前 6 字节正确");
    Expect(uv_actual[6] == 0 && uv_actual[7] == 0, "UV 平面物理 padding 清零");
  }

  // 非法输入必须被拒绝（这些正是真机上"越界读 → 0xC0000005"的来源）。
  std::vector<uint8_t> ignored;
  // 奇数宽（5）时交错色度一行要 6 字节，pitch=5 装不下。
  const Nv12Source odd_width = MakeNv12(5, 4, 5, 11);
  Expect(!ws_scrcpy::D3d11VideoPresenter::PackNv12(AsFrame(odd_width), 6, 4, &ignored),
         "拒绝：NV12 的 pitch 装不下交错色度（奇数宽需要 width+1 字节）");
  ws_scrcpy::Nv12Frame truncated = AsFrame(source);
  truncated.data_bytes = source.bytes.size() - 4;
  Expect(!ws_scrcpy::D3d11VideoPresenter::PackNv12(truncated, 8, 4, &ignored),
         "拒绝：源缓冲长度不足");
  Expect(!ws_scrcpy::D3d11VideoPresenter::PackNv12(AsFrame(source), 7, 4, &ignored),
         "拒绝：物理宽是奇数（D3D11 的 4:2:0 纹理要求偶数）");
  Expect(!ws_scrcpy::D3d11VideoPresenter::PackNv12(AsFrame(source), 4, 4, &ignored),
         "拒绝：帧宽大于物理宽");
  Expect(!ws_scrcpy::D3d11VideoPresenter::PackNv12(AsFrame(source), 8, 2, &ignored),
         "拒绝：帧高大于物理高");
  ws_scrcpy::Nv12Frame null_frame = AsFrame(source);
  null_frame.data = nullptr;
  Expect(!ws_scrcpy::D3d11VideoPresenter::PackNv12(null_frame, 8, 4, &ignored),
         "拒绝：空指针");
}

// 模拟**引擎侧**取纹理的方式：在另一个 D3D11 设备上用传统
// `ID3D11Device::OpenSharedResource` 打开我们给出的共享句柄，并取 `IDXGIKeyedMutex`。
//
// 为什么这一条最重要：真机首跑最可能失败的地方就是"引擎到底认不认我们这块纹理"。
// flutter_windows.dll 里的证据表明引擎把共享句柄交给 ANGLE（`egl/window_surface.cc`
// 与 `external_texture_d3d.cc` 的 "Binding D3D surface failed."），而 ANGLE 打开句柄用的是
// **传统 OpenSharedResource**（其报错串 `-Failed to open share handle, ` /
// `Invalid texture parameters in share handle texture.`）。这里把同一条 API 路径离线跑通，
// 真机黑屏的概率就大幅下降。
void CheckCrossDeviceSharing(uint64_t handle_value) {
  if (handle_value == 0) {
    Expect(false, "共享句柄非 0");
    return;
  }
  ID3D11Device* device = nullptr;
  ID3D11DeviceContext* context = nullptr;
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                      D3D_FEATURE_LEVEL_11_0};
  D3D_FEATURE_LEVEL obtained = D3D_FEATURE_LEVEL_11_0;
  HRESULT result = ::D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
      levels, 2, D3D11_SDK_VERSION, &device, &obtained, &context);
  if (result == E_INVALIDARG) {
    result = ::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels + 1, 1,
                                 D3D11_SDK_VERSION, &device, &obtained, &context);
  }
  Expect(SUCCEEDED(result) && device != nullptr,
         "模拟引擎侧：能建第二个 D3D11 设备");
  if (FAILED(result) || device == nullptr) {
    return;
  }

  ID3D11Texture2D* texture = nullptr;
  result = device->OpenSharedResource(
      reinterpret_cast<HANDLE>(handle_value), __uuidof(ID3D11Texture2D),
      reinterpret_cast<void**>(&texture));
  Expect(SUCCEEDED(result) && texture != nullptr,
         "另一设备能用传统 OpenSharedResource 打开我们的共享句柄（引擎/ANGLE 走的就是这条）");
  if (!texture) {
    D3D11_TEXTURE2D_DESC description = {};
    static_cast<void>(description);
    device->Release();
    context->Release();
    return;
  }

  D3D11_TEXTURE2D_DESC description = {};
  texture->GetDesc(&description);
  Expect(description.Format == DXGI_FORMAT_R8G8B8A8_UNORM,
         "打开后的纹理格式是 R8G8B8A8_UNORM（引擎只接受 GL_RGBA8，BGRA 会被拒收）");
  Expect((description.MiscFlags & D3D11_RESOURCE_MISC_SHARED) != 0 ||
             (description.MiscFlags & D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX) != 0 ||
             (description.MiscFlags & D3D11_RESOURCE_MISC_SHARED_NTHANDLE) != 0,
         "打开后的纹理是共享资源");

  IDXGIKeyedMutex* mutex = nullptr;
  result = texture->QueryInterface(__uuidof(IDXGIKeyedMutex),
                                   reinterpret_cast<void**>(&mutex));
  Expect(SUCCEEDED(result) && mutex != nullptr,
         "共享纹理可以取出 IDXGIKeyedMutex（默认同步方式）");
  if (mutex != nullptr) {
    const HRESULT acquire = mutex->AcquireSync(0, 1000);
    Expect(acquire == S_OK, "消费侧能 AcquireSync(0)");
    if (acquire == S_OK) {
      // 消费侧真读一次：拷回 CPU 证明跨设备内容可用。
      D3D11_TEXTURE2D_DESC staging_description = description;
      staging_description.Usage = D3D11_USAGE_STAGING;
      staging_description.BindFlags = 0;
      staging_description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      staging_description.MiscFlags = 0;
      ID3D11Texture2D* staging = nullptr;
      if (SUCCEEDED(device->CreateTexture2D(&staging_description, nullptr,
                                            &staging))) {
        context->CopyResource(staging, texture);
        D3D11_MAPPED_SUBRESOURCE mapped = {};
        Expect(SUCCEEDED(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped)),
               "消费侧能读回共享纹理（跨设备拷贝成功）");
        if (mapped.pData != nullptr) {
          context->Unmap(staging, 0);
        }
        staging->Release();
      } else {
        Expect(false, "创建 staging 纹理");
      }
      mutex->ReleaseSync(0);
    }
    mutex->Release();
  }
  texture->Release();
  device->Release();
  context->Release();
}

// GPU：一帧从上传到画出的完整数值比对。
bool CheckGpuFrame(ws_scrcpy::D3d11VideoPresenter* presenter, uint32_t width,
                   uint32_t height, size_t pitch, uint32_t seed,
                   bool allow_resize) {
  const Nv12Source source = MakeNv12(width, height, pitch, seed);
  std::vector<uint8_t> expected(static_cast<size_t>(width) * height * 4, 0);
  const bool converted = ws_scrcpy::ConvertYuv420ToRgba(
      source.bytes.data(), source.bytes.size(), ws_scrcpy::Yuv420Layout::kNv12,
      pitch, width, height, false, expected.data(), expected.size());
  Expect(converted, "CPU 参考实现能换算 " + std::to_string(width) + "x" +
                        std::to_string(height));
  if (!converted) {
    return false;
  }

  if (allow_resize) {
    Expect(presenter->Resize(width, height), "Resize 到 " +
                                                 std::to_string(width) + "x" +
                                                 std::to_string(height));
  }
  Expect(presenter->visible_width() == width && presenter->visible_height() == height,
         "呈现器可见尺寸 = 真实尺寸 " + std::to_string(width) + "x" +
             std::to_string(height));
  Expect(presenter->physical_width() == ((width + 1) & ~1u) &&
             presenter->physical_height() == ((height + 1) & ~1u),
         "呈现器物理尺寸向上对齐到偶数");

  const bool published = presenter->PublishNv12(AsFrame(source));
  Expect(published, "PublishNv12 成功 " + std::to_string(width) + "x" +
                        std::to_string(height));
  if (!published) {
    std::printf("      呈现器错误：%s\n", presenter->LastError().c_str());
    return false;
  }

  std::vector<uint8_t> actual;
  Expect(presenter->ReadbackForTest(&actual), "共享纹理可拷回 CPU（staging）");
  const size_t row_bytes = static_cast<size_t>(presenter->physical_width()) * 4;
  if (actual.size() < row_bytes * height) {
    Expect(false, "回读缓冲大小足够");
    return false;
  }

  // 共享纹理是 R8G8B8A8_UNORM（引擎只接受 GL_RGBA8），CPU 参考实现也是 RGBA 字节序，
  // 所以这里**直接逐字节比较**，不需要任何通道交换。
  size_t mismatches = 0;
  int max_delta = 0;
  uint32_t first_x = 0;
  uint32_t first_y = 0;
  int first_expected[3] = {0, 0, 0};
  int first_actual[3] = {0, 0, 0};
  for (uint32_t row = 0; row < height; ++row) {
    const uint8_t* gpu_line = actual.data() + static_cast<size_t>(row) * row_bytes;
    const uint8_t* cpu_line = expected.data() + static_cast<size_t>(row) * width * 4;
    for (uint32_t column = 0; column < width; ++column) {
      const uint8_t gpu_r = gpu_line[column * 4 + 0];
      const uint8_t gpu_g = gpu_line[column * 4 + 1];
      const uint8_t gpu_b = gpu_line[column * 4 + 2];
      const uint8_t gpu_a = gpu_line[column * 4 + 3];
      const uint8_t cpu_r = cpu_line[column * 4 + 0];
      const uint8_t cpu_g = cpu_line[column * 4 + 1];
      const uint8_t cpu_b = cpu_line[column * 4 + 2];
      const int delta = std::abs(static_cast<int>(gpu_r) - cpu_r) +
                        std::abs(static_cast<int>(gpu_g) - cpu_g) +
                        std::abs(static_cast<int>(gpu_b) - cpu_b);
      if (delta != 0 || gpu_a != 255) {
        if (mismatches == 0) {
          first_x = column;
          first_y = row;
          first_expected[0] = cpu_r;
          first_expected[1] = cpu_g;
          first_expected[2] = cpu_b;
          first_actual[0] = gpu_r;
          first_actual[1] = gpu_g;
          first_actual[2] = gpu_b;
        }
        if (delta > max_delta) {
          max_delta = delta;
        }
        ++mismatches;
      }
    }
  }
  ++g_gpu_checks;
  if (mismatches != 0) {
    std::printf("      首个不一致像素 (%u,%u)：GPU=(%d,%d,%d) CPU=(%d,%d,%d)\n",
                first_x, first_y, first_actual[0], first_actual[1],
                first_actual[2], first_expected[0], first_expected[1],
                first_expected[2]);
  }
  Expect(mismatches == 0, "GPU 与 CPU 参考实现逐像素一致（" +
                              std::to_string(width) + "x" +
                              std::to_string(height) + " stride=" +
                              std::to_string(pitch) + "，不一致 " +
                              std::to_string(mismatches) + " 个，最大差 " +
                              std::to_string(max_delta) + "）");
  return true;
}

}  // namespace

int main() {
  ws_scrcpy::OverrideLogFilePathForTesting(".tmp\\d3d11test\\d3d11_present_test.log");
  ws_scrcpy::InitializeLog("D3d11PresentTest");

  std::printf("==== PackNv12（纯 CPU） ====\n");
  CheckPack();

  std::printf("==== GPU 呈现（D3D11 共享纹理 + 着色器） ====\n");
  ws_scrcpy::PresenterOptions options;
  options.keyed_mutex = true;
  options.nth_handle = false;
  ws_scrcpy::D3d11VideoPresenter presenter;
  if (!presenter.Create(1280, 720, options)) {
    std::printf("  [SKIP] GPU 部分未执行：%s\n", presenter.LastError().c_str());
    std::printf("         （PackNv12 的检查已经跑完；GPU 部分需要在有 D3D11 设备的会话里跑）\n");
  } else {
    std::printf("  适配器：%s，共享句柄：0x%llX，同步：%s\n",
                presenter.device_name().c_str(),
                static_cast<unsigned long long>(presenter.shared_handle_value()),
                presenter.keyed_mutex_enabled() ? "keyed-mutex(key 0)" : "无");
    // 0) 引擎侧取纹理的方式（跨设备 OpenSharedResource + keyed mutex）
    CheckCrossDeviceSharing(presenter.shared_handle_value());
    // 1) 与创建尺寸一致
    CheckGpuFrame(&presenter, 1280, 720, 1280, 1, false);
    // 2) 行跨距带对齐（MF 常见：stride 大于 width）
    CheckGpuFrame(&presenter, 1280, 720, 1344, 2, false);
    // 3) 奇数高度（真机上真实出现过 1898x853）
    CheckGpuFrame(&presenter, 1898, 853, 1920, 3, true);
    // 4) 常见小尺寸 + 重建
    CheckGpuFrame(&presenter, 992, 560, 992, 4, true);
    // 5) 极小奇数尺寸（边界：物理尺寸要向上对齐、色度最后一行要复制）
    CheckGpuFrame(&presenter, 3, 3, 8, 5, true);
    CheckGpuFrame(&presenter, 2, 2, 2, 6, true);
    presenter.Release();
    Expect(!presenter.ready(), "Release 之后 ready() 为假");
    presenter.Release();  // 可重复调用
    Expect(true, "Release 可重复调用（幂等）");
  }

  std::printf("\n检查项 %d（其中 GPU 帧比对 %d），失败 %d\n", g_checks, g_gpu_checks,
              g_failures);
  if (g_failures != 0) {
    std::printf("RESULT: FAIL\n");
    return 1;
  }
  std::printf("RESULT: PASS\n");
  return 0;
}
