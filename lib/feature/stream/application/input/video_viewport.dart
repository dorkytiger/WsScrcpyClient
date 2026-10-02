/// 视频坐标系里的一个点（scrcpy 要的是**视频像素**，不是 Flutter 逻辑像素）。
class VideoPoint {
  const VideoPoint(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is VideoPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'VideoPoint($x, $y)';
}

/// 画面在控件里的填充方式。
///
/// 为什么要有一个开关：被控设备是 16:9（1280x720），而手机**横屏**去掉顶栏和快捷栏后
/// 画面区大约是 3:1 —— 按比例完整显示必然左右各留一大条黑边（实测 874 宽里只用 501，
/// 浪费 43%）。"铺满"能把这块地用上，代价是设备画面的上下边缘被裁掉、点不到。
enum VideoFitMode {
  /// 完整显示设备画面（默认）：按比例缩放到装得下，四周留黑边。
  contain('完整显示'),

  /// 铺满控件：按比例缩放到铺得满，超出部分裁掉。
  cover('铺满裁切');

  const VideoFitMode(this.label);

  /// 给 UI 用的中文名（本文件是纯 Dart，不 import Flutter，所以文案挂在这里）。
  final String label;

  VideoFitMode get toggled =>
      this == VideoFitMode.contain ? VideoFitMode.cover : VideoFitMode.contain;
}

/// 视频画面在控件里的缩放换算（contain / cover 共用一套数字）。
///
/// 投流画面保持宽高比居中显示，触摸/滚轮必须先把控件内坐标换算成**视频像素**再发给
/// 设备，否则点哪都偏——这是 M3 最容易错的一步，所以做成纯函数并单独测。
///
/// **渲染与触摸必须用同一个 [fit]**：`player_page.dart` 里画面是用 `FittedBox` 按
/// contain/cover 画的，这里的 [scale] / [offsetX] / [offsetY] 就是同一套公式，
/// 两边一旦不一致，铺满模式下点哪都偏。
class VideoViewport {
  const VideoViewport({
    required this.videoWidth,
    required this.videoHeight,
    required this.viewWidth,
    required this.viewHeight,
    this.fit = VideoFitMode.contain,
  });

  /// 视频（解码输出）像素尺寸。
  final int videoWidth;
  final int videoHeight;

  /// 承载视频的控件尺寸（逻辑像素）。
  final double viewWidth;
  final double viewHeight;

  /// 填充方式。
  final VideoFitMode fit;

  bool get isUsable =>
      videoWidth > 0 && videoHeight > 0 && viewWidth > 0 && viewHeight > 0;

  /// 缩放系数：视频像素 → 控件逻辑像素。
  ///
  /// contain 取**较小**的那个比例（装得下）；cover 取**较大**的（铺得满）。
  double get scale {
    if (!isUsable) {
      return 0;
    }
    final scaleX = viewWidth / videoWidth;
    final scaleY = viewHeight / videoHeight;
    if (fit == VideoFitMode.cover) {
      return scaleX > scaleY ? scaleX : scaleY;
    }
    return scaleX < scaleY ? scaleX : scaleY;
  }

  /// 画面在控件里的实际绘制尺寸（逻辑像素）。
  ///
  /// contain 时 ≤ 控件（差值是黑边）；cover 时 ≥ 控件（差值是**被裁掉**的部分）。
  double get displayWidth => videoWidth * scale;

  double get displayHeight => videoHeight * scale;

  /// 画面左上角在控件内的偏移。
  ///
  /// contain 时是黑边宽度（≥ 0）；cover 时是被裁掉的宽度（≤ 0）。
  double get offsetX => (viewWidth - displayWidth) / 2;

  double get offsetY => (viewHeight - displayHeight) / 2;

  /// 控件内坐标是否落在**可见画面**内。
  ///
  /// cover 下画面铺满控件，所以整个控件都算（被裁掉的部分只是"点不到"，
  /// 不是"点位非法"）。
  bool contains(double localX, double localY) =>
      isUsable &&
      localX >= offsetX &&
      localX <= offsetX + displayWidth &&
      localY >= offsetY &&
      localY <= offsetY + displayHeight;

  /// 控件内坐标 → 视频像素坐标；落在黑边或不可用时返回 null。
  VideoPoint? toVideoPoint(double localX, double localY) {
    if (!contains(localX, localY)) {
      return null;
    }
    final x = ((localX - offsetX) / scale).round();
    final y = ((localY - offsetY) / scale).round();
    // 右/下边界取整后可能正好等于宽高，收进最后一个像素。
    return VideoPoint(x.clamp(0, videoWidth - 1), y.clamp(0, videoHeight - 1));
  }

  @override
  String toString() =>
      'VideoViewport(video: ${videoWidth}x$videoHeight, '
      'view: ${viewWidth}x$viewHeight, fit: ${fit.name}, scale: $scale)';
}
