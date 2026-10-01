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

/// 视频画面在控件里的"contain 缩放"换算。
///
/// 投流画面保持宽高比居中显示（上下或左右留黑边），触摸/滚轮必须先把控件内坐标
/// 换算成**视频像素**再发给设备，否则点哪都偏——这是 M3 最容易错的一步，
/// 所以做成纯函数并单独测。
class VideoViewport {
  const VideoViewport({
    required this.videoWidth,
    required this.videoHeight,
    required this.viewWidth,
    required this.viewHeight,
  });

  /// 视频（解码输出）像素尺寸。
  final int videoWidth;
  final int videoHeight;

  /// 承载视频的控件尺寸（逻辑像素）。
  final double viewWidth;
  final double viewHeight;

  bool get isUsable =>
      videoWidth > 0 && videoHeight > 0 && viewWidth > 0 && viewHeight > 0;

  /// 缩放系数：视频像素 → 控件逻辑像素。
  double get scale {
    if (!isUsable) {
      return 0;
    }
    final scaleX = viewWidth / videoWidth;
    final scaleY = viewHeight / videoHeight;
    return scaleX < scaleY ? scaleX : scaleY;
  }

  /// 画面在控件里的实际绘制尺寸（逻辑像素）。
  double get displayWidth => videoWidth * scale;

  double get displayHeight => videoHeight * scale;

  /// 画面左上角在控件内的偏移（居中后的黑边宽度）。
  double get offsetX => (viewWidth - displayWidth) / 2;

  double get offsetY => (viewHeight - displayHeight) / 2;

  /// 控件内坐标是否落在画面（不含黑边）内。
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
      'view: ${viewWidth}x$viewHeight, scale: $scale)';
}
