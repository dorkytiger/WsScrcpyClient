import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

/// 尺寸（像素）。
class VideoSize {
  const VideoSize(this.width, this.height);

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is VideoSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'VideoSize($width x $height)';
}

/// 显示器信息（`DisplayInfo`，固定 24 字节，全部大端）。
///
/// 布局：`[displayId:i32][width:i32][height:i32][rotation:i32][layerStack:i32][flags:i32]`
class DisplayInfo {
  const DisplayInfo({
    required this.displayId,
    required this.size,
    required this.rotation,
    required this.layerStack,
    required this.flags,
  });

  /// 固定字节长度。
  static const int bufferLength = 24;

  /// 主显示器 id。
  static const int defaultDisplayId = 0;

  /// 无效显示器 id。
  static const int invalidDisplayId = -1;

  static const int flagSupportsProtectedBuffers = 1;
  static const int flagSecure = 2;
  static const int flagPrivate = 4;
  static const int flagPresentation = 8;
  static const int flagRound = 16;

  final int displayId;
  final VideoSize size;
  final int rotation;
  final int layerStack;
  final int flags;

  bool get isRound => (flags & flagRound) != 0;

  static DisplayInfo fromBuffer(Uint8List buffer) {
    if (buffer.length != bufferLength) {
      throw ParsingException(
        message: '显示器信息长度不正确：期望 $bufferLength 字节，实际 ${buffer.length} 字节',
      );
    }
    final view = ByteData.sublistView(buffer);
    return DisplayInfo(
      displayId: view.getInt32(0, Endian.big),
      size: VideoSize(
        view.getInt32(4, Endian.big),
        view.getInt32(8, Endian.big),
      ),
      rotation: view.getInt32(12, Endian.big),
      layerStack: view.getInt32(16, Endian.big),
      flags: view.getInt32(20, Endian.big),
    );
  }

  @override
  String toString() =>
      'DisplayInfo(displayId: $displayId, size: $size, rotation: $rotation, '
      'layerStack: $layerStack, flags: $flags)';
}

/// 矩形区域（裁剪/内容区），取值语义为左、上、右、下。
class VideoRect {
  const VideoRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  static const VideoRect zero = VideoRect(left: 0, top: 0, right: 0, bottom: 0);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;

  int get height => bottom - top;

  @override
  String toString() => 'VideoRect($left, $top, $right, $bottom)';
}

/// 屏幕信息（`ScreenInfo`，固定 25 字节，全部大端）。
///
/// 布局：`[contentRect.left:i32][top:i32][right:i32][bottom:i32]`
/// `[videoWidth:i32][videoHeight:i32][deviceRotation:u8]`
class ScreenInfo {
  const ScreenInfo({
    required this.contentRect,
    required this.videoSize,
    required this.deviceRotation,
  });

  /// 固定字节长度。
  static const int bufferLength = 25;

  final VideoRect contentRect;
  final VideoSize videoSize;
  final int deviceRotation;

  static ScreenInfo fromBuffer(Uint8List buffer) {
    if (buffer.length < bufferLength) {
      throw ParsingException(
        message: '屏幕信息长度不足：期望至少 $bufferLength 字节，实际 ${buffer.length} 字节',
      );
    }
    final view = ByteData.sublistView(buffer);
    return ScreenInfo(
      contentRect: VideoRect(
        left: view.getInt32(0, Endian.big),
        top: view.getInt32(4, Endian.big),
        right: view.getInt32(8, Endian.big),
        bottom: view.getInt32(12, Endian.big),
      ),
      videoSize: VideoSize(
        view.getInt32(16, Endian.big),
        view.getInt32(20, Endian.big),
      ),
      deviceRotation: view.getUint8(24),
    );
  }

  @override
  String toString() =>
      'ScreenInfo(contentRect: $contentRect, videoSize: $videoSize, '
      'deviceRotation: $deviceRotation)';
}
