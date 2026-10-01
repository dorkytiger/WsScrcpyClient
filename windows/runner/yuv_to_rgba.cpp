#include "yuv_to_rgba.h"

// 实现说明见 yuv_to_rgba.h 顶部的三条硬约束。
//
// 这里的每个边界判断都对应一次"实机首跑崩溃"的教训，**不要**为了让代码看起来短而
// 去掉它们：越界读在 debug 下是 0xC0000005，在 release 下会被 CRT 变成 fastfail，
// 两者都只给一个偏移量，排查成本极高。

namespace ws_scrcpy {
namespace {

// YUV→RGB 的定点系数表（BT.601 视频范围）。
//
// 为什么查表：每帧要算几百万个像素，把乘法和 +128 提前算好能省掉逐像素的乘法。
struct YuvTables {
  int32_t y[256];
  int32_t r_v[256];
  int32_t g_u[256];
  int32_t g_v[256];
  int32_t b_u[256];

  YuvTables() {
    for (int value = 0; value < 256; ++value) {
      y[value] = 298 * (value - 16) + 128;
      r_v[value] = 409 * (value - 128);
      g_u[value] = -100 * (value - 128);
      g_v[value] = -208 * (value - 128);
      b_u[value] = 516 * (value - 128);
    }
  }
};

const YuvTables& GetYuvTables() {
  // C++11 起的函数内静态量初始化是线程安全的（不需要额外加锁）。
  static const YuvTables tables;
  return tables;
}

inline uint8_t ClampToByte(int32_t value) {
  if (value < 0) {
    return 0;
  }
  if (value > 255) {
    return 255;
  }
  return static_cast<uint8_t>(value);
}

/// UV 平面的行数：**奇数高度也要算满一行**（ceil(height/2)）。
inline size_t ChromaRows(uint32_t height) {
  return (static_cast<size_t>(height) + 1) / 2;
}

/// NV12 一行里要读到的最大字节数：ceil(width/2) 对 UV，共 ceil(width/2)*2 字节。
inline size_t Nv12ChromaRowBytes(uint32_t width) {
  return (static_cast<size_t>(width) + 1) / 2 * 2;
}

}  // namespace

Yuv420SourceInfo ValidateYuv420Source(Yuv420Layout layout, size_t pitch,
                                      uint32_t width, uint32_t height,
                                      size_t data_bytes) {
  Yuv420SourceInfo info;
  if (width == 0 || height == 0) {
    info.reason = "zero size";
    return info;
  }
  if (pitch == 0) {
    info.reason = "zero pitch";
    return info;
  }
  if (layout != Yuv420Layout::kNv12 && (pitch % 2) != 0) {
    // 平面布局的色度平面跨距是 pitch/2，奇数 pitch 会算错平面起点。
    info.reason = "odd pitch for planar layout";
    return info;
  }
  // Y 平面：每行都按 pitch 排布，所以要读满 width 字节就得 pitch >= width。
  if (pitch < width) {
    info.reason = "pitch smaller than width";
    return info;
  }

  const size_t y_bytes = pitch * height;
  size_t chroma_bytes = 0;
  if (layout == Yuv420Layout::kNv12) {
    if (pitch < Nv12ChromaRowBytes(width)) {
      info.reason = "pitch too small for interleaved chroma";
      return info;
    }
    chroma_bytes = pitch * ChromaRows(height);
  } else {
    if (pitch / 2 < (static_cast<size_t>(width) + 1) / 2) {
      info.reason = "chroma pitch too small";
      return info;
    }
    chroma_bytes = (pitch / 2) * ChromaRows(height) * 2;
  }

  info.required_bytes = y_bytes + chroma_bytes;
  if (data_bytes < info.required_bytes) {
    info.reason = "source buffer too small";
    return info;
  }
  info.ok = true;
  return info;
}

bool ConvertYuv420ToRgba(const uint8_t* data, size_t data_bytes,
                         Yuv420Layout layout, size_t pitch, uint32_t width,
                         uint32_t height, bool bottom_up, uint8_t* dest,
                         size_t dest_capacity) {
  if (data == nullptr || dest == nullptr) {
    return false;
  }
  const size_t target_bytes = static_cast<size_t>(width) * height * 4;
  if (dest_capacity < target_bytes) {
    return false;
  }
  const Yuv420SourceInfo source =
      ValidateYuv420Source(layout, pitch, width, height, data_bytes);
  if (!source.ok) {
    return false;
  }

  const uint8_t* u_plane = nullptr;
  const uint8_t* v_plane = nullptr;
  size_t u_pitch = 0;
  size_t v_pitch = 0;
  const size_t chroma_rows = ChromaRows(height);
  if (layout == Yuv420Layout::kNv12) {
    // NV12：U 在前、V 在后，交错在同一行里，按 pitch 走。
    u_plane = data + pitch * height;
    v_plane = u_plane + 1;
    u_pitch = pitch;
    v_pitch = pitch;
  } else if (layout == Yuv420Layout::kYv12) {
    // YV12：Y + V + U（注意与 I420 的顺序相反）。
    v_plane = data + pitch * height;
    u_plane = v_plane + (pitch / 2) * chroma_rows;
    u_pitch = pitch / 2;
    v_pitch = pitch / 2;
  } else {
    // I420 / IYUV：Y + U + V。
    u_plane = data + pitch * height;
    v_plane = u_plane + (pitch / 2) * chroma_rows;
    u_pitch = pitch / 2;
    v_pitch = pitch / 2;
  }

  const YuvTables& tables = GetYuvTables();
  for (uint32_t row = 0; row < height; ++row) {
    // MF_MT_DEFAULT_STRIDE 为负表示自下而上（少见，但 H.264 允许），此时按行翻转。
    const uint32_t source_row = bottom_up ? (height - 1 - row) : row;
    const uint8_t* y_line = data + static_cast<size_t>(source_row) * pitch;
    const uint8_t* u_line =
        u_plane + static_cast<size_t>(source_row / 2) * u_pitch;
    const uint8_t* v_line =
        v_plane + static_cast<size_t>(source_row / 2) * v_pitch;
    uint8_t* out = dest + static_cast<size_t>(row) * width * 4;
    for (uint32_t column = 0; column < width; ++column) {
      const int32_t luma = tables.y[y_line[column]];
      const int32_t u =
          layout == Yuv420Layout::kNv12 ? u_line[(column / 2) * 2] : u_line[column / 2];
      const int32_t v =
          layout == Yuv420Layout::kNv12 ? v_line[(column / 2) * 2] : v_line[column / 2];
      out[0] = ClampToByte((luma + tables.r_v[v]) >> 8);
      out[1] = ClampToByte((luma + tables.g_u[u] + tables.g_v[v]) >> 8);
      out[2] = ClampToByte((luma + tables.b_u[u]) >> 8);
      out[3] = 255;
      out += 4;
    }
  }
  return true;
}

}  // namespace ws_scrcpy
