/// 视频解码器的**平台分派**入口（与 `web_socket_transport_connect.dart` 同一套路）。
///
/// 上层只 import 这个文件，拿到的是当前平台那份 `createVideoDecoder`：
/// - 原生：`NativeVideoDecoder`（MethodChannel + 系统硬解，见 §11/§12/§15）；
/// - web：`WebCodecsVideoDecoder`（浏览器 `VideoDecoder` + canvas 平台视图）。
///
/// 条件导出按 `dart.library.js_interop` 分派：VM 测试里它是 false → 走原生那份，
/// 所以现有那批"mock `ws_scrcpy/video` 通道"的测试一行都不用改。
library;

export 'video_decoder.dart';
export 'video_decoder_factory_io.dart'
    if (dart.library.js_interop) 'video_decoder_factory_web.dart';
