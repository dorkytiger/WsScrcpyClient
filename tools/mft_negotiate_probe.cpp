// 诊断工具：H.264 解码器 MFT 的**输出类型协商行为**（离线，不需要真机与服务端）。
//
// 要回答的问题（来自真机日志，见 AGENTS.md §12.8）：
//   真机上出现过"喂入 13 帧（含 IDR）、输出 0 帧、且 ProcessInput/ProcessOutput 一个错误都不报"，
//   日志里协商到的输出类型是**默认的 1920x1080**。
//   两种可能必须分开：
//     A) 我们把 SPS/PPS 写进输入类型（MF_MT_MPEG_SEQUENCE_HEADER）之后，解码器其实**认得**，
//        只是旧代码在输出类型定下来**之前**就发了 BEGIN_STREAMING（违反 MSDN 的顺序）；
//     B) 解码器压根没解析我们给的参数集（那就得改序列头的构造方式）。
//   这个探针把三种顺序各跑一遍，直接打印"每一步之后 GetOutputAvailableType 给出什么"。
//
// 数据来源：test/fixtures/stream_first_video_frames.txt（真实服务端抓的报文；
//   第 1 行是同型号设备的完整 SPS+PPS，第 2 行是 IDR 的**前 256 字节**）。
//   注意：IDR 是截断的，所以本探针**不指望解出画面**，它只看协商行为。
//
// 编译与运行：tools\run_mft_negotiate_probe.cmd

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wmcodecdsp.h>
#include <wrl/client.h>

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

constexpr DWORD kInputStreamId = 0;
constexpr DWORD kOutputStreamId = 0;

std::string HresultText(HRESULT result) {
  char buffer[32] = {};
  std::snprintf(buffer, sizeof(buffer), "0x%08lX", static_cast<unsigned long>(result));
  return buffer;
}

// 把夹具第 index 行的 hex 解成字节（index 从 0 开始）。
std::vector<uint8_t> LoadFixtureLine(const char* path, int index) {
  std::ifstream file(path);
  std::string line;
  if (!file.is_open()) {
    return {};
  }
  for (int line_index = 0; line_index <= index; ++line_index) {
    if (!std::getline(file, line)) {
      return {};
    }
  }
  std::vector<uint8_t> bytes;
  int high = -1;
  for (const char ch : line) {
    int value = -1;
    if (ch >= '0' && ch <= '9') {
      value = ch - '0';
    } else if (ch >= 'a' && ch <= 'f') {
      value = ch - 'a' + 10;
    } else if (ch >= 'A' && ch <= 'F') {
      value = ch - 'A' + 10;
    } else {
      continue;
    }
    if (high < 0) {
      high = value;
    } else {
      bytes.push_back(static_cast<uint8_t>((high << 4) | value));
      high = -1;
    }
  }
  return bytes;
}

ComPtr<IMFTransform> CreateDecoder() {
  IMFTransform* raw = nullptr;
  const HRESULT result = ::CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr,
                                            CLSCTX_INPROC_SERVER,
                                            IID_PPV_ARGS(&raw));
  ComPtr<IMFTransform> decoder;
  if (FAILED(result) || raw == nullptr) {
    std::printf("  创建解码器失败：%s\n", HresultText(result).c_str());
    return decoder;
  }
  decoder.Attach(raw);
  IMFAttributes* raw_attributes = nullptr;
  if (SUCCEEDED(decoder->QueryInterface(IID_PPV_ARGS(&raw_attributes))) &&
      raw_attributes != nullptr) {
    ComPtr<IMFAttributes> attributes;
    attributes.Attach(raw_attributes);
    UINT32 is_async = 0;
    if (SUCCEEDED(attributes->GetUINT32(MF_TRANSFORM_ASYNC, &is_async)) &&
        is_async != 0) {
      attributes->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
    }
  }
  return decoder;
}

bool SetInputType(IMFTransform* decoder, const std::vector<uint8_t>* sequence_header) {
  IMFMediaType* raw_type = nullptr;
  HRESULT result = ::MFCreateMediaType(&raw_type);
  ComPtr<IMFMediaType> type;
  if (FAILED(result) || raw_type == nullptr) {
    return false;
  }
  type.Attach(raw_type);
  type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  if (sequence_header != nullptr && !sequence_header->empty()) {
    type->SetBlob(MF_MT_MPEG_SEQUENCE_HEADER, sequence_header->data(),
                  static_cast<UINT32>(sequence_header->size()));
  }
  result = decoder->SetInputType(kInputStreamId, type.Get(), 0);
  std::printf("  SetInputType(%s) -> %s\n",
              (sequence_header != nullptr && !sequence_header->empty())
                  ? "带 SPS/PPS"
                  : "不带 SPS/PPS",
              HresultText(result).c_str());
  return SUCCEEDED(result);
}

void PrintAvailableTypes(IMFTransform* decoder, const char* label) {
  std::printf("  [%s] GetOutputAvailableType：", label);
  bool any = false;
  for (int index = 0; index < 16; ++index) {
    IMFMediaType* raw_type = nullptr;
    if (FAILED(decoder->GetOutputAvailableType(kOutputStreamId,
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
    type->GetGUID(MF_MT_SUBTYPE, &subtype);
    ::MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width, &height);
    std::printf(" %ux%u(Data1=0x%08lX)", width, height,
                static_cast<unsigned long>(subtype.Data1));
    any = true;
  }
  std::printf("%s\n", any ? "" : " 一个都没有（参数集没被解析）");
}

// 挑第一个 NV12/I420/YV12 类型并 SetOutputType，返回容量（0 表示没挑到）。
DWORD SelectFirstOutputType(IMFTransform* decoder) {
  for (int index = 0; index < 16; ++index) {
    IMFMediaType* raw_type = nullptr;
    if (FAILED(decoder->GetOutputAvailableType(kOutputStreamId,
                                               static_cast<DWORD>(index),
                                               &raw_type)) ||
        raw_type == nullptr) {
      return 0;
    }
    ComPtr<IMFMediaType> type;
    type.Attach(raw_type);
    GUID subtype = {};
    type->GetGUID(MF_MT_SUBTYPE, &subtype);
    if (!IsEqualGUID(subtype, MFVideoFormat_NV12) &&
        !IsEqualGUID(subtype, MFVideoFormat_I420) &&
        !IsEqualGUID(subtype, MFVideoFormat_YV12)) {
      continue;
    }
    const HRESULT applied = decoder->SetOutputType(kOutputStreamId, type.Get(), 0);
    UINT32 width = 0;
    UINT32 height = 0;
    ::MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width, &height);
    std::printf("  SetOutputType(%ux%u) -> %s\n", width, height,
                HresultText(applied).c_str());
    if (FAILED(applied)) {
      continue;
    }
    MFT_OUTPUT_STREAM_INFO info = {};
    if (FAILED(decoder->GetOutputStreamInfo(kOutputStreamId, &info))) {
      return 0;
    }
    const size_t bytes = static_cast<size_t>(width) * height * 3 / 2;
    return static_cast<DWORD>(bytes > info.cbSize ? bytes : info.cbSize);
  }
  return 0;
}

void FeedSample(IMFTransform* decoder, const std::vector<uint8_t>& data,
                LONGLONG timestamp) {
  IMFSample* raw_sample = nullptr;
  if (FAILED(::MFCreateSample(&raw_sample)) || raw_sample == nullptr) {
    return;
  }
  ComPtr<IMFSample> sample;
  sample.Attach(raw_sample);
  IMFMediaBuffer* raw_buffer = nullptr;
  if (FAILED(::MFCreateMemoryBuffer(static_cast<DWORD>(data.size()), &raw_buffer)) ||
      raw_buffer == nullptr) {
    return;
  }
  ComPtr<IMFMediaBuffer> buffer;
  buffer.Attach(raw_buffer);
  BYTE* destination = nullptr;
  if (SUCCEEDED(buffer->Lock(&destination, nullptr, nullptr)) &&
      destination != nullptr) {
    std::memcpy(destination, data.data(), data.size());
    buffer->Unlock();
    buffer->SetCurrentLength(static_cast<DWORD>(data.size()));
  }
  sample->AddBuffer(buffer.Get());
  sample->SetSampleTime(timestamp);
  sample->SetSampleDuration(333333);
  const HRESULT result = decoder->ProcessInput(kInputStreamId, sample.Get(), 0);
  std::printf("  ProcessInput(%u 字节) -> %s\n", static_cast<unsigned>(data.size()),
              HresultText(result).c_str());
}

void DrainOutput(IMFTransform* decoder, DWORD buffer_bytes) {
  if (buffer_bytes == 0) {
    std::printf("  DrainOutput：没有输出类型，跳过\n");
    return;
  }
  for (int attempt = 0; attempt < 4; ++attempt) {
    IMFSample* raw_sample = nullptr;
    if (FAILED(::MFCreateSample(&raw_sample)) || raw_sample == nullptr) {
      return;
    }
    ComPtr<IMFSample> sample;
    sample.Attach(raw_sample);
    IMFMediaBuffer* raw_buffer = nullptr;
    if (FAILED(::MFCreateMemoryBuffer(buffer_bytes, &raw_buffer)) ||
        raw_buffer == nullptr) {
      return;
    }
    sample->AddBuffer(raw_buffer);
    raw_buffer->Release();
    MFT_OUTPUT_DATA_BUFFER output = {};
    output.dwStreamID = kOutputStreamId;
    output.pSample = sample.Get();
    DWORD status = 0;
    const HRESULT result = decoder->ProcessOutput(0, 1, &output, &status);
    if (output.pEvents != nullptr) {
      output.pEvents->Release();
    }
    std::printf("  ProcessOutput -> %s（status=%lu）\n", HresultText(result).c_str(),
                static_cast<unsigned long>(status));
    if (result != S_OK) {
      return;
    }
  }
}

void RunCase(const char* name, bool sequence_header_in_input_type,
             bool begin_streaming_before_output_type, bool feed_config_sample,
             const std::vector<uint8_t>& sps_pps,
             const std::vector<uint8_t>& idr) {
  std::printf("\n==== %s ====\n", name);
  ComPtr<IMFTransform> decoder = CreateDecoder();
  if (!decoder) {
    return;
  }
  const std::vector<uint8_t>* header =
      sequence_header_in_input_type ? &sps_pps : nullptr;
  if (!SetInputType(decoder.Get(), header)) {
    return;
  }
  PrintAvailableTypes(decoder.Get(), "SetInputType 之后");

  DWORD buffer_bytes = 0;
  if (begin_streaming_before_output_type) {
    const HRESULT begin =
        decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    std::printf("  BEGIN_STREAMING（在输出类型之前）-> %s  ← 旧代码的行为\n",
                HresultText(begin).c_str());
  } else {
    buffer_bytes = SelectFirstOutputType(decoder.Get());
    const HRESULT begin =
        decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    std::printf("  选好输出类型后再 BEGIN_STREAMING -> %s  ← 新代码的行为\n",
                HresultText(begin).c_str());
  }

  if (feed_config_sample && !sps_pps.empty()) {
    FeedSample(decoder.Get(), sps_pps, 0);
  }
  PrintAvailableTypes(decoder.Get(), "喂入参数集样本之后");
  if (buffer_bytes == 0) {
    buffer_bytes = SelectFirstOutputType(decoder.Get());
  }
  if (!idr.empty()) {
    FeedSample(decoder.Get(), idr, 333333);
  }
  PrintAvailableTypes(decoder.Get(), "喂入 IDR 之后");
  if (buffer_bytes == 0) {
    buffer_bytes = SelectFirstOutputType(decoder.Get());
  }
  DrainOutput(decoder.Get(), buffer_bytes);
}

}  // namespace

int main() {
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const HRESULT mf = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
  std::printf("CoInitializeEx=%s MFStartup=%s\n", HresultText(com).c_str(),
              HresultText(mf).c_str());

  const char* fixture = "test/fixtures/stream_first_video_frames.txt";
  const std::vector<uint8_t> sps_pps = LoadFixtureLine(fixture, 0);
  const std::vector<uint8_t> idr = LoadFixtureLine(fixture, 1);
  std::printf("夹具：SPS/PPS %u 字节，IDR（前 256 字节）%u 字节\n",
              static_cast<unsigned>(sps_pps.size()),
              static_cast<unsigned>(idr.size()));
  if (sps_pps.empty()) {
    std::printf("读不到夹具，退出。\n");
    return 1;
  }
  std::printf("SPS/PPS hex：");
  for (size_t index = 0; index < sps_pps.size(); ++index) {
    std::printf("%02X", sps_pps[index]);
  }
  std::printf("\n");

  // 旧代码：输入类型**不带**序列头，且在输出类型之前就 BEGIN_STREAMING，
  // 参数集靠 in-band 样本喂进去。
  RunCase("旧顺序 A：无序列头 + 先 BEGIN_STREAMING + in-band 参数集", false, true,
          true, sps_pps, idr);

  // 新代码：序列头写进输入类型 → **立刻协商输出类型** → 再 BEGIN_STREAMING → 喂帧。
  RunCase("新顺序 B：序列头进输入类型 + 先协商 + 后 BEGIN_STREAMING", true, false,
          true, sps_pps, idr);

  // 对照：序列头进输入类型，但**不**喂参数集样本（纯 out-of-band）。
  RunCase("对照 C：序列头进输入类型 + 先协商 + 不喂参数集样本", true, false, false,
          sps_pps, idr);

  ::MFShutdown();
  ::CoUninitialize();
  return 0;
}
