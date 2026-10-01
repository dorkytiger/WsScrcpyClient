// NV12 → RGBA8 的 GPU 换算（D3D11，着色器模型 4.0）。
// （文件名里的 bgra 是历史遗留：最初按 BGRA 目标写，真机实测引擎**只接受 GL_RGBA8**，
//   现在渲染目标是 DXGI_FORMAT_R8G8B8A8_UNORM；着色器数学与目标格式无关，不用改。）
//
// 为什么要有这个着色器：Windows 端原来的做法是"CPU 把整帧 NV12 转成 RGBA，再把
// 整帧 RGBA 交给 Flutter 引擎上传"（见 yuv_to_rgba.cpp / scrcpy_pixel_store.cpp）。
// 720p 下每帧 3.7MB 的 CPU 换算 + 上传，是 Windows 端与 Android（SurfaceProducer
// 直接写 GPU 纹理）、网页端（浏览器 GPU 解码 + GPU 合成）差距最大的一环。
// 这里把换算放到 GPU：CPU 只做一次约 1.4MB 的 NV12 重排 + 上传。
//
// **数值必须与 CPU 版逐位一致**（BT.601 视频范围，整数定点）：
//   yuv_to_rgba.cpp 的系数表是
//     luma = 298*(Y-16) + 128
//     R = (luma + 409*(V-128)) >> 8
//     G = (luma - 100*(U-128) - 208*(V-128)) >> 8
//     B = (luma + 516*(U-128)) >> 8
//   这里照抄同一套定点系数与移位，因此 GPU 路与 CPU 路输出应当**完全相同**；
//   tools/d3d11_present_test.cpp 会逐像素比对两边结果（不一致就报错）。
//
// 取样方式用 Load（按整型纹素坐标直接取）而不是 Sample：色度是半分辨率，
// Load 能精确取到"覆盖该像素的那个色度纹素"（与 CPU 版把 UV 复制给 2x2 像素一致），
// 既不需要采样器，也不受过滤方式影响。

Texture2D<float> YPlane : register(t0);
Texture2D<float2> UVPlane : register(t1);

struct VsOutput {
  float4 position : SV_Position;
};

// 全屏三角形（3 个顶点覆盖整个渲染目标，不用顶点缓冲）。
VsOutput VSMain(uint vertex_id : SV_VertexID) {
  VsOutput output;
  float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
  output.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
  return output;
}

float4 PSMain(VsOutput input) : SV_Target {
  // SV_Position 给的是像素中心（x+0.5），截断即得整型像素坐标。
  uint2 pixel = (uint2)input.position.xy;

  // UNORM 取样值乘 255 取整 → 与 CPU 版拿到的字节完全相同。
  const int y_value = (int)(YPlane.Load(int3(pixel, 0)) * 255.0 + 0.5);
  const float2 chroma = UVPlane.Load(int3(pixel >> 1, 0));
  const int u_value = (int)(chroma.x * 255.0 + 0.5);
  const int v_value = (int)(chroma.y * 255.0 + 0.5);

  const int luma = 298 * (y_value - 16) + 128;
  const int r = (luma + 409 * (v_value - 128)) >> 8;
  const int g = (luma - 100 * (u_value - 128) - 208 * (v_value - 128)) >> 8;
  const int b = (luma + 516 * (u_value - 128)) >> 8;

  // 渲染目标是 R8G8B8A8_UNORM（引擎只接受 GL_RGBA8）：写 (R,G,B,A) 即 R,G,B,A 字节序，
  // 正好对上 Flutter 的 kFlutterDesktopPixelFormatRGBA8888。
  return float4(clamp(r, 0, 255) / 255.0, clamp(g, 0, 255) / 255.0,
                clamp(b, 0, 255) / 255.0, 1.0);
}
