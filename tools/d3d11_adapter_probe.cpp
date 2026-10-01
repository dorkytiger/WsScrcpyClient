// 适配器探针：量清楚"传统 DXGI 共享句柄能不能跨适配器打开"。
//
// 为什么要它：真机上 Windows 投流曾经**全黑**，而日志显示解码发布都正常、引擎也来取过描述符
// （`光栅回调 154`）。机制推断是：我们的 D3D11 设备建在**独显**（NVIDIA），而 Flutter 引擎的
// ANGLE 设备在**核显**（Intel），**传统共享句柄不能跨适配器打开** → 引擎拿不到纹理。
// 推断必须变成测量 —— 这个工具就在同一台机器上把矩阵打出来：
//   * 每块适配器各建一个设备，各建一张 keyed-mutex 共享纹理并取句柄；
//   * 用**每块适配器**的设备去 `OpenSharedResource` 别人的句柄，逐格打印结果。
//
// 预期（也是本工具的验收）：**对角线（同适配器）必须成功**；跨适配器那几格应当失败
// （D3D11 的跨适配器共享需要 adapter group / linked adapters，混合显卡不满足）。
//
// 用法：tools\run_d3d11_adapter_probe.cmd

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <cstdio>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

std::string Utf8(const std::wstring& text) {
  if (text.empty()) {
    return {};
  }
  const int bytes = ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                                          static_cast<int>(text.size()), nullptr, 0,
                                          nullptr, nullptr);
  std::string out(static_cast<size_t>(bytes), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                        out.data(), bytes, nullptr, nullptr);
  return out;
}

std::string HresultText(HRESULT result) {
  char buffer[32] = {};
  std::snprintf(buffer, sizeof(buffer), "0x%08lX",
                static_cast<unsigned long>(result));
  return buffer;
}

struct AdapterInfo {
  ComPtr<IDXGIAdapter1> adapter;
  std::string name;
  UINT vendor_id = 0;
  SIZE_T dedicated_video_memory = 0;
};

std::vector<AdapterInfo> EnumerateAdapters() {
  std::vector<AdapterInfo> adapters;
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    return adapters;
  }
  for (UINT index = 0;; ++index) {
    IDXGIAdapter1* raw_adapter = nullptr;
    if (factory->EnumAdapters1(index, &raw_adapter) != S_OK ||
        raw_adapter == nullptr) {
      break;
    }
    AdapterInfo info;
    info.adapter.Attach(raw_adapter);
    DXGI_ADAPTER_DESC1 description = {};
    if (SUCCEEDED(info.adapter->GetDesc1(&description))) {
      info.name = Utf8(description.Description);
      info.vendor_id = description.VendorId;
      info.dedicated_video_memory = description.DedicatedVideoMemory;
    }
    adapters.push_back(std::move(info));
  }
  return adapters;
}

struct DeviceOnAdapter {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<ID3D11Texture2D> texture;
  HANDLE handle = nullptr;
};

// 在指定适配器上建设备 + 一张共享纹理（与 d3d11_video_presenter 用的参数一致）。
bool CreateSharedTextureOnAdapter(IDXGIAdapter1* adapter, DeviceOnAdapter* out) {
  D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
                                D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
  D3D_FEATURE_LEVEL obtained = D3D_FEATURE_LEVEL_10_0;
  HRESULT result = ::D3D11CreateDevice(
      adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
      levels, ARRAYSIZE(levels), D3D11_SDK_VERSION, &out->device, &obtained,
      &out->context);
  if (result == E_INVALIDARG) {
    result = ::D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                                 D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels + 1,
                                 ARRAYSIZE(levels) - 1, D3D11_SDK_VERSION,
                                 &out->device, &obtained, &out->context);
  }
  if (FAILED(result) || out->device == nullptr) {
    std::printf("    建设备失败：%s\n", HresultText(result).c_str());
    return false;
  }
  D3D11_TEXTURE2D_DESC description = {};
  description.Width = 1280;
  description.Height = 560;
  description.MipLevels = 1;
  description.ArraySize = 1;
  description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  description.SampleDesc.Count = 1;
  description.Usage = D3D11_USAGE_DEFAULT;
  description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  description.MiscFlags = D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
  result = out->device->CreateTexture2D(&description, nullptr, &out->texture);
  if (FAILED(result)) {
    std::printf("    建纹理失败：%s\n", HresultText(result).c_str());
    return false;
  }
  ComPtr<IDXGIResource> resource;
  if (FAILED(out->texture.As(&resource))) {
    std::printf("    取 IDXGIResource 失败\n");
    return false;
  }
  if (FAILED(resource->GetSharedHandle(&out->handle))) {
    std::printf("    GetSharedHandle 失败\n");
    return false;
  }
  return true;
}

// 用 [target] 的设备打开 [source] 的句柄（引擎/ANGLE 走的就是这条 API）。
HRESULT OpenFromOtherAdapter(ID3D11Device* target, HANDLE handle) {
  ComPtr<ID3D11Texture2D> opened;
  const HRESULT result = target->OpenSharedResource(
      handle, __uuidof(ID3D11Texture2D),
      reinterpret_cast<void**>(opened.GetAddressOf()));
  if (FAILED(result)) {
    return result;
  }
  // 打开成功还要能取到 keyed mutex 并拿到锁（ANGLE 会做同样的事）。
  ComPtr<IDXGIKeyedMutex> mutex;
  if (FAILED(opened.As(&mutex))) {
    return E_NOINTERFACE;
  }
  const HRESULT acquired = mutex->AcquireSync(0, 100);
  if (acquired == S_OK) {
    mutex->ReleaseSync(0);
  }
  return acquired;
}

}  // namespace

int main() {
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  std::printf("CoInitializeEx=%s\n", HresultText(com).c_str());

  const std::vector<AdapterInfo> adapters = EnumerateAdapters();
  std::printf("适配器 %zu 块：\n", adapters.size());
  for (size_t index = 0; index < adapters.size(); ++index) {
    std::printf("  [%zu] %s（VendorId=0x%04X，显存 %.0f MB）\n", index,
                adapters[index].name.c_str(), adapters[index].vendor_id,
                static_cast<double>(adapters[index].dedicated_video_memory) /
                    (1024.0 * 1024.0));
  }
  if (adapters.empty()) {
    std::printf("没有适配器，退出。\n");
    return 1;
  }

  // 每块适配器各建一份"设备 + 共享纹理 + 句柄"。
  std::vector<DeviceOnAdapter> sources(adapters.size());
  std::vector<bool> usable(adapters.size(), false);
  for (size_t index = 0; index < adapters.size(); ++index) {
    std::printf("\n在 [%zu] %s 上创建共享纹理：\n", index,
                adapters[index].name.c_str());
    usable[index] = CreateSharedTextureOnAdapter(adapters[index].adapter.Get(),
                                                 &sources[index]);
    if (usable[index]) {
      std::printf("    共享句柄=0x%llX\n",
                  static_cast<unsigned long long>(
                      reinterpret_cast<uintptr_t>(sources[index].handle)));
    }
  }

  std::printf("\n=== 打开矩阵（行=谁去打开，列=句柄来自谁）===\n");
  std::printf("%-28s", "打开方 \\ 句柄源");
  for (size_t column = 0; column < adapters.size(); ++column) {
    std::printf(" [%zu]", column);
  }
  std::printf("\n");

  int same_adapter_ok = 0;
  int same_adapter_total = 0;
  int cross_adapter_ok = 0;
  int cross_adapter_total = 0;
  for (size_t row = 0; row < adapters.size(); ++row) {
    std::printf("%-28s", ("[" + std::to_string(row) + "] " +
                          adapters[row].name.substr(0, 20))
                             .c_str());
    for (size_t column = 0; column < adapters.size(); ++column) {
      if (!usable[row] || !usable[column]) {
        std::printf("  --");
        continue;
      }
      const HRESULT result =
          OpenFromOtherAdapter(sources[row].device.Get(), sources[column].handle);
      const bool ok = result == S_OK;
      if (row == column) {
        ++same_adapter_total;
        same_adapter_ok += ok ? 1 : 0;
      } else {
        ++cross_adapter_total;
        cross_adapter_ok += ok ? 1 : 0;
      }
      std::printf(ok ? "  OK" : "  X ");
    }
    std::printf("\n");
  }

  std::printf("\n同适配器：%d/%d 成功（**必须**全成功，否则我们的 GPU 路在自家设备上都走不通）\n",
              same_adapter_ok, same_adapter_total);
  std::printf("跨适配器：%d/%d 成功（预期 0 —— 传统共享句柄不能跨适配器；"
              "这正是真机黑屏的机制）\n",
              cross_adapter_ok, cross_adapter_total);

  for (DeviceOnAdapter& source : sources) {
    source.texture.Reset();
    source.context.Reset();
    source.device.Reset();
  }
  ::CoUninitialize();

  if (same_adapter_total == 0) {
    std::printf("RESULT: SKIP（没有可用的适配器组合）\n");
    return 0;
  }
  if (same_adapter_ok != same_adapter_total) {
    std::printf("RESULT: FAIL（同适配器都打不开，GPU 路的前提不成立）\n");
    return 1;
  }
  std::printf("RESULT: PASS（同适配器可用；跨适配器结论见上面那行）\n");
  return 0;
}
