/// 平台能力判定（**纯 Dart，不依赖 Flutter**）。
///
/// `lib/core/**` 的纪律是不 import Flutter（这样协议层能原样编到 web 或命令行工具里），
/// 所以这里不用 `kIsWeb`，而是用条件导出在编译期定死一个常量。
library;

export 'platform_capabilities_io.dart'
    if (dart.library.js_interop) 'platform_capabilities_web.dart';
