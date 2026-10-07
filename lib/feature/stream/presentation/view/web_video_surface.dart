/// web 视频画面（canvas 平台视图）的**平台分派**入口。
///
/// web 上画面是 DOM 里的 canvas，不参与 Flutter 绘制：`FittedBox` 缩放它没有意义，
/// 而它又必须跟触摸换算用**同一套** [VideoViewport] 数字（否则"点哪都偏"）。
/// 所以这里把 viewport 交给解码器去摆 CSS（见 `WebCodecsVideoDecoder.applyDisplayGeometry`）。
///
/// 原生平台上这个函数是空实现（那段分支在 `isWebPlatform == false` 时是死代码）。
library;

export 'web_video_surface_stub.dart'
    if (dart.library.js_interop) 'web_video_surface_web.dart';
