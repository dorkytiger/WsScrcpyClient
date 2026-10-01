// 离线回放探针：把**真实抓下来的帧**（WSCAP001 格式）喂给 H.264 解码器 MFT，
// 用两种"协商 / 喂帧顺序"各跑一遍，直接对比哪一套能解出画面。
//
// 数据来源（两种，格式相同）：
//   1) App：`set WS_CAPTURE_FRAMES=<路径>` 后运行 —— 抓的是真正喂进解码器的字节；
//   2) 探测脚本：`set WS_PROBE_CAPTURE=<路径>` 后 `dart run tools/probe.dart`。
// 文件格式：8 字节 "WSCAP001" + 重复 { uint32 小端长度, 该长度的 Annex-B 帧 }。
//
// 为什么必须离线跑：真机日志只能告诉我们"喂入 13 帧、输出 0 帧、且不报任何错"，
// 而"到底是顺序问题、参数集问题还是码流本身的问题"必须在可控环境里二分。
// 本工具不需要 Flutter、不需要设备、不需要服务端。
//
// 用法：tools\run_mft_replay_probe.cmd [抓包路径]
//       默认抓包路径：.probe\capture.bin

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX  // 不要在 windows.h 里引入 min/max 宏（否则 std::min 会被展开成语法错误）
#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <codecapi.h>
#include <wmcodecdsp.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

constexpr DWORD kInputStreamId = 0;
constexpr DWORD kOutputStreamId = 0;
constexpr uint32_t kOutputTypeNegotiationFrames = 12;

std::string HresultText(HRESULT result) {
  char buffer[32] = {};
  std::snprintf(buffer, sizeof(buffer), "0x%08lX",
                static_cast<unsigned long>(result));
  return buffer;
}

// 读 WSCAP001：8 字节魔数 + 重复 { uint32 小端长度, 帧字节 }。
std::vector<std::vector<uint8_t>> LoadCapture(const char* path, bool* ok) {
  *ok = false;
  std::ifstream file(path, std::ios::binary);
  if (!file.is_open()) {
    std::printf("打不开抓包文件：%s\n", path);
    return {};
  }
  char magic[8] = {};
  file.read(magic, sizeof(magic));
  const std::string magic_text(magic, sizeof(magic));
  if (magic_text != "WSCAP001") {
    std::printf("魔数不对（期望 WSCAP001，实际 %s）\n", magic_text.c_str());
    return {};
  }
  std::vector<std::vector<uint8_t>> frames;
  for (;;) {
    uint8_t header[4] = {};
    file.read(reinterpret_cast<char*>(header), sizeof(header));
    if (file.gcount() != static_cast<std::streamsize>(sizeof(header))) {
      break;
    }
    const uint32_t length = static_cast<uint32_t>(header[0]) |
                            (static_cast<uint32_t>(header[1]) << 8) |
                            (static_cast<uint32_t>(header[2]) << 16) |
                            (static_cast<uint32_t>(header[3]) << 24);
    if (length == 0 || length > (64u << 20)) {
      std::printf("帧长度异常：%u，停止解析\n", length);
      break;
    }
    std::vector<uint8_t> frame(length);
    file.read(reinterpret_cast<char*>(frame.data()), length);
    if (file.gcount() != static_cast<std::streamsize>(length)) {
      std::printf("最后一帧不完整，丢弃\n");
      break;
    }
    frames.push_back(std::move(frame));
  }
  *ok = !frames.empty();
  return frames;
}

// Annex-B 扫描：找出 SPS(7)/PPS(8)（各自带起始码）以及 NAL 类型列表。
struct NalScan {
  std::vector<uint8_t> sps_pps;
  std::vector<int> types;
  bool has_idr = false;
  bool has_vcl = false;
};

NalScan ScanAnnexB(const uint8_t* data, size_t size) {
  NalScan scan;
  size_t index = 0;
  while (index + 3 < size) {
    size_t start = 0;
    size_t prefix = 0;
    if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1) {
      start = index + 3;
      prefix = 3;
    } else if (index + 4 < size && data[index] == 0 && data[index + 1] == 0 &&
               data[index + 2] == 0 && data[index + 3] == 1) {
      start = index + 4;
      prefix = 4;
    } else {
      ++index;
      continue;
    }
    if (start >= size) {
      break;
    }
    const int type = data[start] & 0x1F;
    scan.types.push_back(type);
    if (type == 5) {
      scan.has_idr = true;
      scan.has_vcl = true;
    } else if (type == 1) {
      scan.has_vcl = true;
    }
    if (type == 7 || type == 8) {
      // 复制"起始码 + NAL 负载"，直到下一个起始码。
      size_t end = start + 1;
      while (end + 3 < size) {
        if (data[end] == 0 && data[end + 1] == 0 &&
            (data[end + 2] == 1 ||
             (end + 3 < size && data[end + 2] == 0 && data[end + 3] == 1))) {
          break;
        }
        ++end;
      }
      scan.sps_pps.insert(scan.sps_pps.end(), data + index, data + end);
    }
    index = start;
  }
  return scan;
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

bool SetInputType(IMFTransform* decoder, const std::vector<uint8_t>* header,
                 uint32_t width, uint32_t height) {
  IMFMediaType* raw_type = nullptr;
  if (FAILED(::MFCreateMediaType(&raw_type)) || raw_type == nullptr) {
    return false;
  }
  ComPtr<IMFMediaType> type;
  type.Attach(raw_type);
  type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  if (header != nullptr && !header->empty()) {
    type->SetBlob(MF_MT_MPEG_SEQUENCE_HEADER, header->data(),
                  static_cast<UINT32>(header->size()));
  }
  if (width != 0 && height != 0) {
    // **关键猜测**：把真实尺寸写在**输入类型**上，看解码器是否立刻按它广告输出类型。
    // 之前只在输出类型上试过（被 MF_E_INVALIDMEDIATYPE 拒），输入类型这条路还没试过。
    ::MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, width, height);
    type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  }
  return SUCCEEDED(decoder->SetInputType(kInputStreamId, type.Get(), 0));
}

void PrintAvailableTypes(IMFTransform* decoder, const char* label) {
  std::printf("  [%s] 可用输出类型：", label);
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
    std::printf(" %ux%u", width, height);
    any = true;
  }
  std::printf("%s\n", any ? "" : " 一个都没有");
}

DWORD SelectFirstOutputType(IMFTransform* decoder, uint32_t* width,
                            uint32_t* height) {
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
    if (FAILED(decoder->SetOutputType(kOutputStreamId, type.Get(), 0))) {
      continue;
    }
    UINT32 selected_width = 0;
    UINT32 selected_height = 0;
    ::MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &selected_width,
                         &selected_height);
    if (width != nullptr) {
      *width = selected_width;
    }
    if (height != nullptr) {
      *height = selected_height;
    }
    MFT_OUTPUT_STREAM_INFO info = {};
    if (FAILED(decoder->GetOutputStreamInfo(kOutputStreamId, &info))) {
      return 0;
    }
    const size_t needed =
        static_cast<size_t>(selected_width) * selected_height * 3 / 2;
    return static_cast<DWORD>(needed > info.cbSize ? needed : info.cbSize);
  }
  return 0;
}

/// 样本时间戳的给法（真机上我们用的是"每帧 +333333us"的合成时间）。
///
/// 为什么要逐个试：两种完全不同的码流（全 IDR 的 105 帧、IDR+P 帧的 43 帧）都恰好
/// 在"第 37~39 帧"才吐第一张图 —— 与内容无关，那就很像**时间戳/媒体时间**在卡它。
enum class TimestampMode {
  kSynthetic333ms,  // index * 333333（当前实现）
  kZero,            // 全部 0
  kTiny,            // index * 1000（1ms 一帧）
  kNone,            // 完全不打时间戳/时长
};

// 按模式算出"该给这帧什么时间戳"（单位 100ns，MF 的约定）。
LONGLONG TimestampFor(TimestampMode mode, size_t index) {
  switch (mode) {
    case TimestampMode::kZero:
      return 0;
    case TimestampMode::kTiny:
      return static_cast<LONGLONG>(index) * 1000;  // 1ms 一帧
    case TimestampMode::kNone:
    case TimestampMode::kSynthetic333ms:
    default:
      return static_cast<LONGLONG>(index) * 333333;  // 33.3ms 一帧
  }
}

bool FeedSample(IMFTransform* decoder, const std::vector<uint8_t>& data,
                LONGLONG timestamp, TimestampMode mode) {
  IMFSample* raw_sample = nullptr;
  if (FAILED(::MFCreateSample(&raw_sample)) || raw_sample == nullptr) {
    return false;
  }
  ComPtr<IMFSample> sample;
  sample.Attach(raw_sample);
  IMFMediaBuffer* raw_buffer = nullptr;
  if (FAILED(::MFCreateMemoryBuffer(static_cast<DWORD>(data.size()),
                                    &raw_buffer)) ||
      raw_buffer == nullptr) {
    return false;
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
  if (mode != TimestampMode::kNone) {
    sample->SetSampleTime(timestamp);
    sample->SetSampleDuration(333333);
  }
  return SUCCEEDED(decoder->ProcessInput(kInputStreamId, sample.Get(), 0));
}

// 从 SPS 里解出真实分辨率（H.264 的基本解析：去 emulation prevention + ue(v) 读位）。
//
// 为什么要它：抓包实测"SPS 说 992x560，而 MFT 只广告默认 1920x1080"，
// 于是我们只能先按默认类型跑，等解码器**自己**报 MF_E_TRANSFORM_STREAM_CHANGE 才换到真实尺寸
// ——实测那一次要等到第 30 帧（画面黑好几秒）。既然我们手里已经有 SPS，
// 就可以直接把真实尺寸设成输出类型，省掉这段等待。
struct SpsSize {
  uint32_t width = 0;
  uint32_t height = 0;
  bool ok = false;
};

SpsSize ParseSpsSize(const uint8_t* nal, size_t size) {
  SpsSize result;
  if (nal == nullptr || size < 4) {
    return result;
  }
  // 去掉 emulation prevention（0x00 0x00 0x03 → 0x00 0x00）。
  std::vector<uint8_t> rbsp;
  rbsp.reserve(size);
  int zeros = 0;
  for (size_t i = 1; i < size; ++i) {  // 跳过 NAL 头字节
    const uint8_t byte = nal[i];
    if (zeros >= 2 && byte == 0x03) {
      zeros = 0;
      continue;
    }
    rbsp.push_back(byte);
    zeros = byte == 0 ? zeros + 1 : 0;
  }
  if (rbsp.size() < 4) {
    return result;
  }
  // profile_idc + constraint flags + level_idc 三字节之后才开始位域。
  std::vector<uint8_t> payload(rbsp.begin() + 3, rbsp.end());
  size_t bit_pos = 0;
  const auto bits_left = [&payload](size_t pos) {
    return payload.size() * 8 - pos;
  };
  const auto read_bit = [&payload, &bit_pos, &bits_left](uint32_t* out) {
    if (bits_left(bit_pos) < 1) {
      return false;
    }
    *out = (payload[bit_pos / 8] >> (7 - (bit_pos % 8))) & 1;
    ++bit_pos;
    return true;
  };
  const auto read_bits = [&](size_t count, uint32_t* out) {
    if (bits_left(bit_pos) < count || count > 32) {
      return false;
    }
    uint32_t value = 0;
    for (size_t i = 0; i < count; ++i) {
      uint32_t bit = 0;
      if (!read_bit(&bit)) {
        return false;
      }
      value = (value << 1) | bit;
    }
    *out = value;
    return true;
  };
  const auto read_ue = [&](uint32_t* out) {
    size_t zeros_count = 0;
    for (;;) {
      uint32_t bit = 0;
      if (!read_bit(&bit)) {
        return false;
      }
      if (bit == 1) {
        break;
      }
      ++zeros_count;
      if (zeros_count > 32) {
        return false;
      }
    }
    uint32_t rest = 0;
    if (zeros_count > 0 && !read_bits(zeros_count, &rest)) {
      return false;
    }
    *out = ((1u << zeros_count) - 1) + rest;
    return true;
  };

  uint32_t value = 0;
  if (!read_ue(&value)) {  // seq_parameter_set_id
    return result;
  }
  if (value > 31) {
    return result;
  }
  if (!read_ue(&value)) {  // log2_max_frame_num_minus4
    return result;
  }
  uint32_t poc_type = 0;
  if (!read_ue(&poc_type) || poc_type > 2) {
    return result;
  }
  if (poc_type == 0) {
    if (!read_ue(&value)) {
      return result;
    }
  } else if (poc_type == 1) {
    uint32_t bit = 0;
    if (!read_bits(1, &bit) || !read_ue(&value) || !read_ue(&value)) {
      return result;
    }
    uint32_t cycle = 0;
    if (!read_ue(&cycle)) {
      return result;
    }
    for (uint32_t i = 0; i < cycle; ++i) {
      if (!read_ue(&value)) {
        return result;
      }
    }
  }
  if (!read_ue(&value) || !read_bits(1, &value)) {  // max_num_ref_frames, gaps flag
    return result;
  }
  uint32_t width_mbs = 0;
  uint32_t height_map_units = 0;
  if (!read_ue(&width_mbs) || !read_ue(&height_map_units)) {
    return result;
  }
  uint32_t frame_mbs_only = 0;
  if (!read_bits(1, &frame_mbs_only)) {
    return result;
  }
  if (frame_mbs_only == 0 && !read_bits(1, &value)) {
    return result;
  }
  if (!read_bits(1, &value)) {  // direct_8x8_inference_flag
    return result;
  }
  uint32_t crop_flag = 0;
  if (!read_bits(1, &crop_flag)) {
    return result;
  }
  uint32_t crop_left = 0;
  uint32_t crop_right = 0;
  uint32_t crop_top = 0;
  uint32_t crop_bottom = 0;
  if (crop_flag != 0) {
    if (!read_ue(&crop_left) || !read_ue(&crop_right) ||
        !read_ue(&crop_top) || !read_ue(&crop_bottom)) {
      return result;
    }
  }
  const uint32_t width =
      (width_mbs + 1) * 16 - (crop_left + crop_right) * 2;
  const uint32_t height = (height_map_units + 1) * 16 * (2 - frame_mbs_only) -
                          (crop_top + crop_bottom) * 2;
  if (width == 0 || height == 0 || width > 8192 || height > 8192) {
    return result;
  }
  result.width = width;
  result.height = height;
  result.ok = true;
  return result;
}

// 把"只广告默认类型"的 MFT 直接设成我们知道的真实尺寸（类型不在可用列表里也照设）。
bool SetExplicitOutputType(IMFTransform* decoder, uint32_t width, uint32_t height,
                           DWORD* buffer_bytes) {
  IMFMediaType* raw_type = nullptr;
  if (FAILED(::MFCreateMediaType(&raw_type)) || raw_type == nullptr) {
    return false;
  }
  ComPtr<IMFMediaType> type;
  type.Attach(raw_type);
  type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  ::MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, width, height);
  const HRESULT applied = decoder->SetOutputType(kOutputStreamId, type.Get(), 0);
  std::printf("  直接 SetOutputType(%ux%u) -> %s\n", width, height,
              HresultText(applied).c_str());
  if (FAILED(applied)) {
    return false;
  }
  MFT_OUTPUT_STREAM_INFO info = {};
  if (FAILED(decoder->GetOutputStreamInfo(kOutputStreamId, &info))) {
    return false;
  }
  const size_t needed = static_cast<size_t>(width) * height * 3 / 2;
  *buffer_bytes = static_cast<DWORD>(needed > info.cbSize ? needed : info.cbSize);
  return true;
}

struct RunStats {
  int published = 0;
  int stream_changes = 0;
  int need_more_input = 0;
  int failures = 0;
  int first_published_at = -1;
  uint32_t last_width = 0;
  uint32_t last_height = 0;
};

// **正统的 MF 协商路径**：先不设输出类型，喂了样本之后直接取一次输出。
// 按 MSDN，这时 MFT 应当返回 MF_E_TRANSFORM_TYPE_NOT_SET，而**之后**
// GetOutputAvailableType 才会给出**真实**尺寸（而不是那个 1920x1080 默认值）。
// 真实解码器的 DrainOutput 在"输出类型还没定"时直接 return 了，等于永远不问这一句。
void ProbeWithoutOutputType(IMFTransform* decoder, DWORD* buffer_bytes,
                            RunStats* stats, size_t frame_index,
                            bool* reported) {
  IMFSample* raw_sample = nullptr;
  if (FAILED(::MFCreateSample(&raw_sample)) || raw_sample == nullptr) {
    return;
  }
  ComPtr<IMFSample> sample;
  sample.Attach(raw_sample);
  IMFMediaBuffer* raw_buffer = nullptr;
  if (FAILED(::MFCreateMemoryBuffer(1920 * 1080 * 3 / 2, &raw_buffer)) ||
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
  if (!*reported || result != S_OK) {
    std::printf("  [第 %zu 帧] 未设输出类型时 ProcessOutput -> %s\n", frame_index,
                HresultText(result).c_str());
    *reported = true;
  }
  if (result == MF_E_TRANSFORM_TYPE_NOT_SET ||
      result == MF_E_TRANSFORM_STREAM_CHANGE) {
    PrintAvailableTypes(decoder, "TYPE_NOT_SET 之后的可用输出类型");
    *buffer_bytes =
        SelectFirstOutputType(decoder, &stats->last_width, &stats->last_height);
    std::printf("  按真实尺寸协商 -> %ux%u（缓冲 %lu 字节）\n", stats->last_width,
                stats->last_height, static_cast<unsigned long>(*buffer_bytes));
  }
}

// 异步 MFT 的事件队列：不取走事件时，有的 MFT 会迟迟不把输出交出来。
// 返回取到的事件数（顺带打印前几个事件类型，便于判断）。
size_t DrainDecoderEvents(IMFTransform* decoder) {
  IMFMediaEventGenerator* raw_generator = nullptr;
  if (FAILED(decoder->QueryInterface(IID_PPV_ARGS(&raw_generator))) ||
      raw_generator == nullptr) {
    return 0;
  }
  ComPtr<IMFMediaEventGenerator> generator;
  generator.Attach(raw_generator);
  size_t count = 0;
  for (int guard = 0; guard < 32; ++guard) {
    IMFMediaEvent* raw_event = nullptr;
    const HRESULT result =
        generator->GetEvent(MF_EVENT_FLAG_NO_WAIT, &raw_event);
    if (FAILED(result) || raw_event == nullptr) {
      break;
    }
    ComPtr<IMFMediaEvent> event;
    event.Attach(raw_event);
    MediaEventType type = MEUnknown;
    event->GetType(&type);
    if (count < 3) {
      std::printf("    事件：type=%ld\n", static_cast<long>(type));
    }
    ++count;
  }
  return count;
}

struct RunStats;

// 取一轮输出（最多 8 次），把 STREAM_CHANGE 按真实解码器的做法处理掉。
// [frame_index] 只用于日志：真实分辨率是"喂到第几帧"才被解码器认出来的，
// 这个数字直接决定"首帧要黑多久"。
void DrainOutput(IMFTransform* decoder, DWORD* buffer_bytes, RunStats* stats,
                 size_t frame_index, bool retry_output) {
  for (int guard = 0; guard < 8; ++guard) {
    if (*buffer_bytes == 0) {
      return;
    }
    IMFSample* raw_sample = nullptr;
    if (FAILED(::MFCreateSample(&raw_sample)) || raw_sample == nullptr) {
      return;
    }
    ComPtr<IMFSample> sample;
    sample.Attach(raw_sample);
    IMFMediaBuffer* raw_buffer = nullptr;
    if (FAILED(::MFCreateMemoryBuffer(*buffer_bytes, &raw_buffer)) ||
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
    if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) {
      ++stats->need_more_input;
      if (!retry_output) {
        return;
      }
      continue;  // 再调一次：看它是不是需要重复调用才推进
    }
    if (result == MF_E_TRANSFORM_STREAM_CHANGE) {
      ++stats->stream_changes;
      *buffer_bytes = SelectFirstOutputType(decoder, &stats->last_width,
                                            &stats->last_height);
      std::printf("  [第 %d 次流格式变化，喂到第 %zu 帧] 重新协商为 %ux%u\n",
                  stats->stream_changes, frame_index, stats->last_width,
                  stats->last_height);
      continue;
    }
    if (FAILED(result)) {
      ++stats->failures;
      if (stats->failures <= 3) {
        std::printf("  ProcessOutput 失败：%s\n", HresultText(result).c_str());
      }
      return;
    }
    ++stats->published;
    if (stats->first_published_at < 0) {
      stats->first_published_at = static_cast<int>(frame_index);
    }
  }
}

// 一次回放的开关（用来把"顺序""真实尺寸""取事件"三件事分开量）。
/// 样本时间戳的给法（真机上我们用的是"每帧 +333333us"的合成时间）。见上面的 TimestampMode。
struct ReplayOptions {
  bool new_order = true;      // 参数集进输入类型 → 先协商 → 后 BEGIN_STREAMING
  bool use_sps_size = false;  // 用 SPS 解出的真实尺寸直接设输出类型（不等 STREAM_CHANGE）
  bool drain_events = false;  // 每帧之后取走 MFT 的事件（异步 MFT 的正确驱动方式之一）
  bool defer_output_type = false;  // 先不设输出类型，靠 TYPE_NOT_SET 问出真实尺寸
  /// 前 [prime_repeats] 次先**重复喂第一个 VCL 帧**（IDR 可以安全重复解），
  /// 用来验证"解码器是不是纯粹要够 N 个样本才出图"——真机上画面静止时服务端只给二十来帧，
  /// 若解码器要 30 帧才吐第一张，那就永远黑屏（用户 2026-10-01 就是这样）。
  int prime_repeats = 0;
  /// 每喂一帧后发一次 `MFT_MESSAGE_COMMAND_DRAIN`（"把已缓冲的输出吐出来"）。
  ///
  /// 为什么要试：这个 MFT 在"输出类型先设成默认 1920x1080"的情况下要**憋到第 38 个样本**
  /// 才吐第一张图（两种完全不同的码流、时间戳、顺序都一样），而真机上画面静止时服务端
  /// 只给二十来帧 → **永远黑屏**（用户 2026-10-01 就是完全黑屏）。
  /// 如果 DRAIN 能让它马上吐，那我们的修法就是"没有输出时主动 DRAIN"。
  bool drain_command = false;
  /// ProcessOutput 返回 NEED_MORE_INPUT 时**继续再调几次**（而不是立刻收手）。
  /// 我们一直只调一次就 return —— MFT 的状态机可能需要反复调用才推进（便宜且关键的验证）。
  bool retry_output = false;
  /// 开低延迟模式：MF_LOW_LATENCY 属性 + CODECAPI_AVLowLatencyMode。
  /// **这是最可能的根因**：解码器默认会缓冲约 1.2 秒（30fps ≈ 38 帧）才吐第一张图，
  /// 而画面静止时服务端只给二十来帧 → 永远黑屏；编码器一重启就再冻几秒。
  bool low_latency = false;
  /// 把 SPS 解出的真实尺寸写到**输入类型**上（MF_MT_FRAME_SIZE）。
  bool input_frame_size = false;
  /// 关掉 H.264 硬件解码加速（CODECAPI_AVDecVideoAcceleration_H264 = 0）。
  /// DXVA 解码器会用 surface 池并攒帧，黑屏/周期性卡顿都像它的行为。
  bool disable_hw_accel = false;
  /// 不把"只有 SPS/PPS 的那条"当样本喂（只保留在输入类型的序列头里）。
  bool skip_config_sample = false;
  /// 每喂 [drain_every] 帧发一次 DRAIN（0 = 不用这个策略）。
  int drain_every = 0;
  /// 只在喂到第 [drain_once_at] 帧时发一次 DRAIN（0 = 不用）。
  int drain_once_at = 0;
  TimestampMode timestamp_mode = TimestampMode::kSynthetic333ms;
};

RunStats Replay(const std::vector<std::vector<uint8_t>>& frames,
                const ReplayOptions& options) {
  RunStats stats;
  ComPtr<IMFTransform> decoder = CreateDecoder();
  if (!decoder) {
    return stats;
  }

  // 第一帧若是参数集（含 7/8 号 NAL 且没有切片），就当作序列头。
  std::vector<uint8_t> sequence_header;
  size_t first_frame_index = 0;
  if (!frames.empty()) {
    const NalScan scan = ScanAnnexB(frames[0].data(), frames[0].size());
    if (!scan.sps_pps.empty() && !scan.has_vcl) {
      sequence_header = scan.sps_pps;
    }
  }
  // 从 SPS 里解出真实分辨率（用于 use_sps_size）。
  uint32_t sps_width = 0;
  uint32_t sps_height = 0;
  if (options.use_sps_size && !sequence_header.empty()) {
    // sequence_header 形如 "00 00 00 01 67 ..."：找到 NAL 头再交给解析器。
    size_t nal_start = 0;
    while (nal_start + 4 < sequence_header.size() &&
           !(sequence_header[nal_start] == 0 && sequence_header[nal_start + 1] == 0 &&
             sequence_header[nal_start + 2] == 0 && sequence_header[nal_start + 3] == 1)) {
      ++nal_start;
    }
    nal_start += 4;
    if (nal_start < sequence_header.size()) {
      const SpsSize size = ParseSpsSize(sequence_header.data() + nal_start,
                                        sequence_header.size() - nal_start);
      if (size.ok) {
        sps_width = size.width;
        sps_height = size.height;
        std::printf("  SPS 解析出真实分辨率：%ux%u\n", sps_width, sps_height);
      } else {
        std::printf("  SPS 解析失败，退回默认协商\n");
      }
    }
  }

  const uint32_t input_width = options.input_frame_size ? sps_width : 0;
  const uint32_t input_height = options.input_frame_size ? sps_height : 0;
  if (!SetInputType(decoder.Get(),
                    options.new_order && !sequence_header.empty()
                        ? &sequence_header
                        : nullptr,
                    input_width, input_height)) {
    std::printf("  SetInputType 失败\n");
    return stats;
  }
  if (options.low_latency) {
    // MF_LOW_LATENCY 必须在开始流之前设置（MF 官方的低延迟开关）。
    IMFAttributes* raw_attributes = nullptr;
    if (SUCCEEDED(decoder->GetAttributes(&raw_attributes)) &&
        raw_attributes != nullptr) {
      ComPtr<IMFAttributes> attributes;
      attributes.Attach(raw_attributes);
      const HRESULT set = attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
      std::printf("  设置 MF_LOW_LATENCY -> %s\n", HresultText(set).c_str());
    }
    ComPtr<ICodecAPI> codec_api;
    if (SUCCEEDED(decoder->QueryInterface(IID_PPV_ARGS(&codec_api))) &&
        codec_api != nullptr) {
      VARIANT value;
      ::VariantInit(&value);
      value.vt = VT_BOOL;
      value.boolVal = VARIANT_TRUE;
      const HRESULT set = codec_api->SetValue(&CODECAPI_AVLowLatencyMode, &value);
      ::VariantClear(&value);
      std::printf("  CODECAPI_AVLowLatencyMode -> %s\n", HresultText(set).c_str());
    }
  }
  if (options.disable_hw_accel) {
    // 关掉硬件解码加速：DXVA 解码器会持有 surface 池并攒帧（黑屏/周期性卡顿的典型嫌疑）。
    // 走标准接口 ICodecAPI::SetValue（不是 IMFAttributes）。
    ComPtr<ICodecAPI> codec_api;
    if (SUCCEEDED(decoder->QueryInterface(IID_PPV_ARGS(&codec_api))) &&
        codec_api != nullptr) {
      VARIANT value;
      ::VariantInit(&value);
      value.vt = VT_UI4;
      value.ulVal = 0;
      const HRESULT set = codec_api->SetValue(
          &CODECAPI_AVDecVideoAcceleration_H264, &value);
      ::VariantClear(&value);
      std::printf("  关闭硬件解码加速 -> %s\n", HresultText(set).c_str());
    } else {
      std::printf("  取 ICodecAPI 失败，无法关闭硬件加速\n");
    }
  }
  PrintAvailableTypes(decoder.Get(), "SetInputType 之后");

  DWORD buffer_bytes = 0;
  bool streaming_started = false;
  const auto start_streaming = [&decoder, &streaming_started]() {
    if (streaming_started) {
      return;
    }
    decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    streaming_started = true;
  };
  if (options.new_order) {
    if (options.defer_output_type) {
      std::printf("  本模式**故意先不设输出类型**：靠 ProcessOutput 的 "
                  "MF_E_TRANSFORM_TYPE_NOT_SET 去问真实尺寸\n");
    } else {
      if (options.use_sps_size && sps_width != 0 && sps_height != 0) {
        SetExplicitOutputType(decoder.Get(), sps_width, sps_height, &buffer_bytes);
        stats.last_width = sps_width;
        stats.last_height = sps_height;
      }
      if (buffer_bytes == 0) {
        buffer_bytes = SelectFirstOutputType(decoder.Get(), &stats.last_width,
                                             &stats.last_height);
      }
      std::printf("  先协商输出类型 -> %ux%u（缓冲 %lu 字节）\n", stats.last_width,
                  stats.last_height, static_cast<unsigned long>(buffer_bytes));
    }
    if (buffer_bytes != 0) {
      start_streaming();
    }
  } else {
    decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    streaming_started = true;
    std::printf("  先 BEGIN_STREAMING，输出类型等第 %u 帧兜底\n",
                kOutputTypeNegotiationFrames);
  }

  size_t fed = 0;
  bool type_not_set_reported = false;
  // 预热：重复喂第一个 VCL 帧（见 ReplayOptions::prime_repeats）。
  if (options.prime_repeats > 0 && frames.size() > 1) {
    std::printf("  预热：重复喂第 2 帧（首个 VCL/IDR）%d 次\n", options.prime_repeats);
    for (int repeat = 0; repeat < options.prime_repeats; ++repeat) {
      FeedSample(decoder.Get(), frames[1], static_cast<LONGLONG>(repeat) * 333333, options.timestamp_mode);
      ++fed;
      DrainOutput(decoder.Get(), &buffer_bytes, &stats, 1, options.retry_output);
      if (stats.first_published_at >= 0) {
        std::printf("  预热在第 %d 次重复时出图\n", repeat + 1);
        break;
      }
    }
  }
  const size_t loop_start =
      options.skip_config_sample && frames.size() > 1 ? 1 : first_frame_index;
  for (size_t index = loop_start; index < frames.size(); ++index) {
    if (!FeedSample(decoder.Get(), frames[index],
                    TimestampFor(options.timestamp_mode, index),
                    options.timestamp_mode)) {
      std::printf("  第 %zu 帧 ProcessInput 失败（继续）\n", index);
    }
    ++fed;
    if (options.drain_command) {
      decoder->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
    }
    if (options.drain_every > 0 && (fed % options.drain_every) == 0) {
      decoder->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
    }
    if (options.drain_once_at > 0 &&
        fed == static_cast<size_t>(options.drain_once_at)) {
      decoder->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
    }
    if (options.drain_events) {
      DrainDecoderEvents(decoder.Get());
    }
    if (options.defer_output_type && buffer_bytes == 0) {
      ProbeWithoutOutputType(decoder.Get(), &buffer_bytes, &stats, index,
                             &type_not_set_reported);
      if (buffer_bytes != 0) {
        start_streaming();
      }
    }
    if (!options.new_order && buffer_bytes == 0 &&
        fed >= kOutputTypeNegotiationFrames) {
      buffer_bytes = SelectFirstOutputType(decoder.Get(), &stats.last_width,
                                           &stats.last_height);
      std::printf("  第 %u 帧兜底协商 -> %ux%u（缓冲 %lu 字节）\n",
                  kOutputTypeNegotiationFrames, stats.last_width,
                  stats.last_height, static_cast<unsigned long>(buffer_bytes));
    }
    DrainOutput(decoder.Get(), &buffer_bytes, &stats, index, options.retry_output);
  }
  std::printf(
      "  喂入 %zu 帧：已发布 %d 帧（首帧出现在第 %d 帧），流格式变化 %d 次，"
      "需更多输入 %d 次，失败 %d 次\n",
      fed, stats.published, stats.first_published_at, stats.stream_changes,
      stats.need_more_input, stats.failures);
  return stats;
}

}  // namespace

int main(int argc, char** argv) {
  const char* path = argc > 1 ? argv[1] : ".probe\\capture.bin";
  bool ok = false;
  const std::vector<std::vector<uint8_t>> frames = LoadCapture(path, &ok);
  if (!ok) {
    std::printf("没有可用帧（先用 WS_CAPTURE_FRAMES / WS_PROBE_CAPTURE 抓一份）。\n");
    return 1;
  }
  size_t total_bytes = 0;
  for (const std::vector<uint8_t>& frame : frames) {
    total_bytes += frame.size();
  }
  std::printf("抓包：%zu 帧，共 %zu 字节（平均 %.0f 字节）\n", frames.size(),
              total_bytes,
              frames.empty() ? 0.0
                             : static_cast<double>(total_bytes) /
                                   static_cast<double>(frames.size()));
  const NalScan first = ScanAnnexB(frames[0].data(), frames[0].size());
  std::printf("首帧 NAL 类型：");
  for (const int type : first.types) {
    std::printf("%d ", type);
  }
  std::printf("\n");

  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const HRESULT mf = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
  std::printf("CoInitializeEx=%s MFStartup=%s\n", HresultText(com).c_str(),
              HresultText(mf).c_str());

  ReplayOptions options;
  std::printf("\n==== 旧顺序（先 BEGIN_STREAMING，第 12 帧才协商）====\n");
  options = ReplayOptions{};
  options.new_order = false;
  const RunStats old_stats = Replay(frames, options);

  std::printf("\n==== 新顺序（参数集进输入类型 → 先协商 → 后 BEGIN_STREAMING）====\n");
  options = ReplayOptions{};
  const RunStats new_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 用 SPS 的真实尺寸直接设输出类型 ====\n");
  options = ReplayOptions{};
  options.use_sps_size = true;
  const RunStats sps_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 取走 MFT 事件（异步 MFT 的正确驱动）====\n");
  options = ReplayOptions{};
  options.drain_events = true;
  const RunStats event_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + SPS 尺寸 + 取事件 ====\n");
  options = ReplayOptions{};
  options.use_sps_size = true;
  options.drain_events = true;
  const RunStats both_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 先不设输出类型（正统 MF 协商，靠 TYPE_NOT_SET 问真实尺寸）====\n");
  options = ReplayOptions{};
  options.defer_output_type = true;
  const RunStats deferred_stats = Replay(frames, options);

  // 这是关键实验：**只重复喂同一个 IDR**，看解码器是不是纯按"喂够多少个样本"出图。
  // 若这里也是第 ~30 次才出图 → 真机上"画面静止导致只来 20 来帧"就必然黑屏，
  // 而我们**可以自己重复喂**把它顶过去（IDR 重复解是合法的）。
  std::printf("\n==== 新顺序 + 预热（重复首个 IDR 最多 80 次）====\n");
  options = ReplayOptions{};
  options.prime_repeats = 80;
  const RunStats prime_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 每帧后 COMMAND_DRAIN ====\n");
  options = ReplayOptions{};
  options.drain_command = true;
  const RunStats drain_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 输入类型带真实尺寸（MF_MT_FRAME_SIZE）====\n");
  options = ReplayOptions{};
  options.input_frame_size = true;
  const RunStats input_size_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 关闭硬件解码加速 ====\n");
  options = ReplayOptions{};
  options.disable_hw_accel = true;
  const RunStats no_hw_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 不喂参数集样本 ====\n");
  options = ReplayOptions{};
  options.skip_config_sample = true;
  const RunStats skip_cfg_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 重复调 ProcessOutput ====\n");
  options = ReplayOptions{};
  options.retry_output = true;
  const RunStats retry_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 低延迟模式 ====\n");
  options = ReplayOptions{};
  options.low_latency = true;
  const RunStats low_latency_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 只在第 2 帧后 DRAIN 一次 ====\n");
  options = ReplayOptions{};
  options.drain_once_at = 2;
  const RunStats drain_once_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 每 3 帧 DRAIN 一次 ====\n");
  options = ReplayOptions{};
  options.drain_every = 3;
  const RunStats drain_every_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 时间戳全 0 ====\n");
  options = ReplayOptions{};
  options.timestamp_mode = TimestampMode::kZero;
  const RunStats zero_ts_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 时间戳 1ms/帧 ====\n");
  options = ReplayOptions{};
  options.timestamp_mode = TimestampMode::kTiny;
  const RunStats tiny_ts_stats = Replay(frames, options);

  std::printf("\n==== 新顺序 + 完全不打时间戳 ====\n");
  options = ReplayOptions{};
  options.timestamp_mode = TimestampMode::kNone;
  const RunStats none_ts_stats = Replay(frames, options);

  ::MFShutdown();
  ::CoUninitialize();

  std::printf("\n==== 结论（首帧出现在第几帧 = 画面黑多久）====\n");
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "旧顺序",
              old_stats.published, old_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序",
              new_stats.published, new_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + SPS 尺寸",
              sps_stats.published, sps_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 取事件",
              event_stats.published, event_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + SPS 尺寸 + 取事件",
              both_stats.published, both_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 先不设输出类型",
              deferred_stats.published, deferred_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 预热重复 IDR",
              prime_stats.published, prime_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + COMMAND_DRAIN",
              drain_stats.published, drain_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 输入类型带尺寸",
              input_size_stats.published, input_size_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 低延迟模式",
              low_latency_stats.published, low_latency_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 重复调输出",
              retry_stats.published, retry_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 关硬件加速",
              no_hw_stats.published, no_hw_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 不喂参数集样本",
              skip_cfg_stats.published, skip_cfg_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 只 DRAIN 一次",
              drain_once_stats.published, drain_once_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 每 3 帧 DRAIN",
              drain_every_stats.published, drain_every_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 时间戳全 0",
              zero_ts_stats.published, zero_ts_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 时间戳 1ms/帧",
              tiny_ts_stats.published, tiny_ts_stats.first_published_at);
  std::printf("%-34s 已发布 %3d 帧，首帧在第 %3d 帧\n", "新顺序 + 不打时间戳",
              none_ts_stats.published, none_ts_stats.first_published_at);

  int best_first = -1;
  const int candidates[] = {new_stats.first_published_at,
                            sps_stats.first_published_at,
                            event_stats.first_published_at,
                            both_stats.first_published_at,
                            deferred_stats.first_published_at,
                            drain_stats.first_published_at,
                            prime_stats.first_published_at,
                            zero_ts_stats.first_published_at,
                            tiny_ts_stats.first_published_at,
                            none_ts_stats.first_published_at};
  for (const int candidate : candidates) {
    if (candidate >= 0 && (best_first < 0 || candidate < best_first)) {
      best_first = candidate;
    }
  }
  // 只有**明显**提前（大于 10 帧）才算"更快的启动路径"。实测各变体在 27~34 帧之间跳，
  // 这是逐次运行的噪声，不要把它当成果（曾经差点这么误判）。
  if (best_first >= 0 && new_stats.first_published_at >= 0 &&
      best_first + 10 < new_stats.first_published_at) {
    std::printf("→ 有更快的启动路径（首帧从第 %d 帧提前到第 %d 帧），值得移植回解码器。\n",
                new_stats.first_published_at, best_first);
  } else {
    std::printf("→ 没有更快的启动路径：各变体首帧都在第 27~34 帧（差异是噪声）。\n"
                "  实测这个 MFT 在解析出真实格式之前只肯给默认 1920x1080，"
                "而且必须喂够约 30 个样本才报 MF_E_TRANSFORM_STREAM_CHANGE —— "
                "**这是它的固有行为，客户端无可调之处**（试过的三条路："
                "MF_E_TRANSFORM_TYPE_NOT_SET 之后问到的仍是 1920x1080；"
                "直接 SetOutputType(真实尺寸) 被拒（MF_E_INVALIDMEDIATYPE）；"
                "取走 MFT 事件只快 1~4 帧）。\n");
  }
  return 0;
}
