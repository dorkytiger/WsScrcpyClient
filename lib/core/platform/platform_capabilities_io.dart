/// 原生平台（Android / iOS / Windows / macOS / Linux）。
library;

/// 是否运行在浏览器里。见 `platform_capabilities.dart`。
const bool isWebPlatform = false;

/// web 上"浏览器代管 Basic Auth"的说明文案；原生端不需要它（能自己带头）。
///
/// 保留同一个符号是为了让调用处两端一致，不用到处写分支。
const String? browserAuthHint = null;
