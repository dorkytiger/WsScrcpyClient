#ifndef RUNNER_YUV_TO_RGBA_H_
#define RUNNER_YUV_TO_RGBA_H_

#include <cstddef>
#include <cstdint>

// 4:2:0（NV12 / I420 / IYUV / YV12）→ RGBA8888 的**纯函数**。
//
// 为什么单独抽出来：实机首跑崩在越界（debug 是 0xC0000005，release 是 CRT fastfail），
// 而这套换算在解码器里没法离线复现（没有服务端就没有码流）。抽成不依赖 Media
// Foundation 的纯函数之后，`tools/yuv_to_rgba_test.cpp` 就能在本机用带 padding 的
// pitch、奇数宽高、1x1、缓冲只给半个 UV 平面这些边界输入直接驱动它，并用
// AddressSanitizer / 金丝雀字节证明不越界。
//
// 三条硬约束（对齐 Flutter 引擎的像素缓冲纹理实现
// shell/platform/windows/external_texture_pixelbuffer.cc）：
//   1) 目标必须是紧凑 RGBA（引擎按 GL_RGBA + GL_UNSIGNED_BYTE 上传，没设
//      GL_UNPACK_ROW_LENGTH，所以行跨距只能是 width*4）；
//   2) 源跨距**不能假设等于宽度**（解码器可能给带对齐的 pitch，NV12 的 UV 平面
//      是按 pitch 排布的，不是按 width）；
//   3) 源缓冲长度不足时必须**返回 false 而不是硬写**——奇数高度时 UV 平面需要
//      ceil(height/2) 行，按 height/2 估算会少读一行，这正是首跑崩掉的根因。

namespace ws_scrcpy {

/// 4:2:0 的三种平面排布。
enum class Yuv420Layout {
  kNv12,  ///< Y + 交错 UV（U 在前），UV 平面按 pitch 排布
  kI420,  ///< Y + U + V（IYUV 与它等价）
  kYv12,  ///< Y + V + U（与 I420 顺序相反）
};

/// 源缓冲的校验结果，便于调用方把失败原因写进日志。
struct Yuv420SourceInfo {
  bool ok = false;
  const char* reason = "";  ///< 失败原因（英文短语，日志里再拼中文）
  size_t required_bytes = 0;///< 按布局与宽高算出的最小源字节数
};

/// 校验源缓冲是否够放下这一帧（含奇数高度需要的额外 UV 行）。
///
/// [pitch] 是 Y 平面的行跨距（字节），[data_bytes] 是解码器给出的缓冲真实长度。
Yuv420SourceInfo ValidateYuv420Source(Yuv420Layout layout, size_t pitch,
                                      uint32_t width, uint32_t height,
                                      size_t data_bytes);

/// 换算一整帧到 [dest]。
///
/// 成功时写出恰好 `width * height * 4` 字节（紧凑 RGBA），返回 true；
/// 任一约束不满足（源缓冲不足、pitch 小于宽度、目标容量不足、宽高为 0）返回 false，
/// 此时**不写任何字节**。源指针可以为空——此时同样返回 false。
bool ConvertYuv420ToRgba(const uint8_t* data, size_t data_bytes,
                         Yuv420Layout layout, size_t pitch, uint32_t width,
                         uint32_t height, bool bottom_up, uint8_t* dest,
                         size_t dest_capacity);

}  // namespace ws_scrcpy

#endif  // RUNNER_YUV_TO_RGBA_H_
