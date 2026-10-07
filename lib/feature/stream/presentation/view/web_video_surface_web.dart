import 'package:flutter/widgets.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/webcodecs_video_decoder.dart';

/// web：把解码器建的 canvas 以平台视图的形式嵌进 widget 树。
///
/// 每次布局都把 viewport 推给解码器（在 post-frame 里做，避免 build 期间改 DOM 样式），
/// 那边用同一套数字写 canvas 的 CSS 位置——**渲染与触摸换算同源**。
Widget buildWebVideoSurface({
  required VideoViewport? viewport,
  required ValueChanged<VideoViewport?> onGeometry,
}) => _WebVideoSurface(viewport: viewport, onGeometry: onGeometry);

class _WebVideoSurface extends StatelessWidget {
  const _WebVideoSurface({required this.viewport, required this.onGeometry});

  final VideoViewport? viewport;
  final ValueChanged<VideoViewport?> onGeometry;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => onGeometry(viewport));
    return const HtmlElementView(viewType: WebCodecsVideoDecoder.viewType);
  }
}
