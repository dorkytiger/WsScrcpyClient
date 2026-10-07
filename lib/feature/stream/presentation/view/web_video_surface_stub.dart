import 'package:flutter/widgets.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';

/// 原生平台：没有 web 画面这回事（`isWebPlatform` 是编译期 false，调用点是死代码）。
Widget buildWebVideoSurface({
  required VideoViewport? viewport,
  required ValueChanged<VideoViewport?> onGeometry,
}) => const SizedBox.shrink();
