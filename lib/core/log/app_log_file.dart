/// Dart 侧日志落盘（平台分支，条件导出）。
///
/// **为什么要它**：原生解码器有 `scrcpy_decoder.log` 每次落盘（§12.2），而 Dart 侧的日志
/// （投流参数、视口诊断、吞吐、输入事件……）以前**只在应用内的日志面板**里 ——
/// 每次排查都要用户手动复制粘贴，或者干脆看不到。2026-10-08 那次"低延迟开关到底改了没改"
/// 就是因为看不见 `首发视频参数…` 而只能靠感觉判断（§16.5）。
///
/// 拆法与 [database_executor] 同一个套路：`dart:io` 在 web 上是一调用就抛的桩，
/// 所以 web 走空实现。
library;

export 'app_log_file_io.dart'
    if (dart.library.js_interop) 'app_log_file_web.dart';
