cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "decoder_log.cpp"
  "d3d11_video_presenter.cpp"
  "scrcpy_pixel_store.cpp"
  "scrcpy_video_decoder.cpp"
  "yuv_to_rgba.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# 源码里有中文注释，而这个项目开着 /W4 /WX：MSVC 默认按系统代码页（936）解释源文件，
# 一旦文件没有 BOM 就会报 C4819 并因为 /WX 直接失败。原来靠"所有文件必须存成
# UTF-8 with BOM"来规避，但编辑器（甚至自动改写文件的工具）会把 BOM 吃掉，
# 于是构建莫名其妙地挂。这里显式告诉编译器源文件是 UTF-8，从此与 BOM 无关。
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
# flutter_window.cpp 要拿引擎的纹理注册器（PluginRegistrar::texture_registrar）；
# 那套 PluginRegistrar（Manager）在 flutter_wrapper_plugin 里（插件同样是这么用的），
# 因此 runner 也要链上它。两者只是源码集合不同，不会重复定义符号。
target_link_libraries(${BINARY_NAME} PRIVATE flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# 原生 H.264 解码（scrcpy_video_decoder.cpp）用的 Windows 系统库：
#   mfplat            Media Foundation 平台（MFStartup / MFCreateSample / MFGetAttributeSize…）
#   mfuuid            MFVideoFormat_* / MFMediaType_* / MF_MT_* 等 GUID 的定义
#   wmcodecdspuuid    CLSID_CMSH264DecoderMFT（系统内置 H.264 解码器 MFT）
#   ole32             CoInitializeEx / CoCreateInstance
# GPU 呈现（d3d11_video_presenter.cpp）用：
#   d3d11             D3D11CreateDevice / 纹理 / 着色器 / UpdateSubresource
#   dxgi              IDXGIResource::GetSharedHandle（引擎侧走 ANGLE 的共享句柄路径，
#                     见 d3d11_video_presenter.h 顶部的证据说明）
# 全部是系统库，不引入任何 NuGet 依赖（离线构建链路见 windows/CMakeLists.txt）。
target_link_libraries(${BINARY_NAME} PRIVATE
  "mfplat.lib"
  "mfuuid.lib"
  "wmcodecdspuuid.lib"
  "ole32.lib"
  "d3d11.lib"
  "dxgi.lib"
)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
