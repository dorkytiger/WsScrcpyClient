// 诊断工具：确认 Media Foundation 的 H.264 解码器 MFT 的**输出样本归属**与异步标记。
//
// 为什么需要它：`windows/runner/scrcpy_video_decoder.cpp` 的 DrainOutput 里是自己
// MFCreateSample 一张输出样本、把它塞进 MFT_OUTPUT_DATA_BUFFER.pSample，然后
// PresentOutput 只读回**自己那张**。如果 MFT 声明了自己提供样本
// （MFT_OUTPUT_STREAM_PROVIDES_SAMPLES），那么 ProcessOutput 会把 pSample 换成
// MFT 自己的样本，代码就读了一张从未被写过的空缓冲（表现为永远黑屏），
// 而且 MFT 那张样本没人 Release（表现为内存持续增长直到进程死掉）。
//
// 这个探针不依赖 Flutter、不依赖真机，只回答两件事：
//   1) MF_TRANSFORM_ASYNC 是否为真（决定要不要 MF_TRANSFORM_ASYNC_UNLOCK）；
//   2) GetOutputStreamInfo 的 dwFlags 里有没有 PROVIDES_SAMPLES / CAN_PROVIDE_SAMPLES。
//
// 编译与运行（工作区内、不污染系统）：
//   tools\run_mf_probe.cmd

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wmcodecdsp.h>  // CLSID_CMSH264DecoderMFT
#include <wrl/client.h>

#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

// 从 test/fixtures/stream_first_video_frames.txt 取第一行（真实的 SPS/PPS 报文）。
std::vector<uint8_t> LoadSpsPpsFixture(const char* path) {
  std::ifstream file(path);
  std::string line;
  if (!file.is_open() || !std::getline(file, line)) {
    return {};
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

void PrintHresult(const char* label, HRESULT hr) {
  std::printf("%-34s hr=0x%08lX %s\n", label, static_cast<unsigned long>(hr),
              SUCCEEDED(hr) ? "(ok)" : "(failed)");
}

}  // namespace

int main(int argc, char** argv) {
  const char* fixture =
      argc > 1 ? argv[1] : "test/fixtures/stream_first_video_frames.txt";

  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  std::printf("CoInitializeEx                     hr=0x%08lX\n",
              static_cast<unsigned long>(com));
  const HRESULT mf = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
  std::printf("MFStartup                          hr=0x%08lX\n",
              static_cast<unsigned long>(mf));
  if (FAILED(mf)) {
    return 1;
  }

  ComPtr<IMFTransform> decoder;
  const HRESULT created = ::CoCreateInstance(
      CLSID_CMSH264DecoderMFT, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&decoder));
  PrintHresult("CoCreateInstance(CMSH264DecoderMFT)", created);
  if (FAILED(created)) {
    ::MFShutdown();
    return 1;
  }

  ComPtr<IMFAttributes> attributes;
  if (SUCCEEDED(decoder.As(&attributes))) {
    UINT32 is_async = 0;
    const HRESULT got = attributes->GetUINT32(MF_TRANSFORM_ASYNC, &is_async);
    std::printf("MF_TRANSFORM_ASYNC                 %s (hr=0x%08lX)\n",
                SUCCEEDED(got) ? (is_async ? "TRUE" : "FALSE") : "not present",
                static_cast<unsigned long>(got));
    if (SUCCEEDED(got) && is_async != 0) {
      const HRESULT unlocked =
          attributes->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
      PrintHresult("Set MF_TRANSFORM_ASYNC_UNLOCK", unlocked);
    }
  }

  // 输入类型：H.264 基本流（Annex-B），并把真实 SPS/PPS 作为序列头写进去，
  // 这样解码器才有机会给出输出类型。
  const std::vector<uint8_t> sps_pps = LoadSpsPpsFixture(fixture);
  std::printf("SPS/PPS 夹具字节数                  %zu\n", sps_pps.size());

  ComPtr<IMFMediaType> input_type;
  HRESULT hr = ::MFCreateMediaType(&input_type);
  if (SUCCEEDED(hr)) {
    hr = input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  }
  if (SUCCEEDED(hr)) {
    hr = input_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  }
  if (SUCCEEDED(hr) && !sps_pps.empty()) {
    hr = input_type->SetBlob(MF_MT_MPEG_SEQUENCE_HEADER, sps_pps.data(),
                             static_cast<UINT32>(sps_pps.size()));
  }
  PrintHresult("组装输入类型", hr);
  if (SUCCEEDED(hr)) {
    PrintHresult("SetInputType", decoder->SetInputType(0, input_type.Get(), 0));
  }

  // 关键查询：输出流信息（样本归属）。
  MFT_OUTPUT_STREAM_INFO info = {};
  const HRESULT stream_info = decoder->GetOutputStreamInfo(0, &info);
  PrintHresult("GetOutputStreamInfo", stream_info);
  if (SUCCEEDED(stream_info)) {
    std::printf("  dwFlags                          = 0x%08lX\n",
                static_cast<unsigned long>(info.dwFlags));
    std::printf("  PROVIDES_SAMPLES (0x100)         = %s\n",
                (info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) ? "YES"
                                                                    : "no");
    std::printf("  CAN_PROVIDE_SAMPLES (0x80)       = %s\n",
                (info.dwFlags & MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES) ? "YES"
                                                                       : "no");
    std::printf("  WHOLE_SAMPLES (0x1)              = %s\n",
                (info.dwFlags & MFT_OUTPUT_STREAM_WHOLE_SAMPLES) ? "YES" : "no");
    std::printf("  SINGLE_SAMPLE_PER_BUFFER (0x2)   = %s\n",
                (info.dwFlags & MFT_OUTPUT_STREAM_SINGLE_SAMPLE_PER_BUFFER)
                    ? "YES"
                    : "no");
    std::printf("  FIXED_SAMPLE_SIZE (0x4)          = %s\n",
                (info.dwFlags & MFT_OUTPUT_STREAM_FIXED_SAMPLE_SIZE) ? "YES"
                                                                     : "no");
    std::printf("  cbSize                           = %lu\n",
                static_cast<unsigned long>(info.cbSize));
  }

  // 顺带看看能不能协商出输出类型（没有完整码流时可能拿不到，属正常）。
  for (DWORD index = 0; index < 4; ++index) {
    ComPtr<IMFMediaType> output_type;
    const HRESULT available =
        decoder->GetOutputAvailableType(0, index, &output_type);
    if (FAILED(available)) {
      std::printf("GetOutputAvailableType[%lu]        0x%08lX（到此为止）\n",
                  static_cast<unsigned long>(index),
                  static_cast<unsigned long>(available));
      break;
    }
    GUID subtype = {};
    output_type->GetGUID(MF_MT_SUBTYPE, &subtype);
    UINT32 width = 0;
    UINT32 height = 0;
    ::MFGetAttributeSize(output_type.Get(), MF_MT_FRAME_SIZE, &width, &height);
    UINT32 stride = 0;
    output_type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride);
    std::printf("GetOutputAvailableType[%lu]        %ux%u stride=%lu\n",
                static_cast<unsigned long>(index), width, height,
                static_cast<unsigned long>(stride));
  }

  decoder.Reset();
  ::MFShutdown();
  ::CoUninitialize();
  return 0;
}
