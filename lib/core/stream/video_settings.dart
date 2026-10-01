import 'dart:convert';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';

/// 投流编码参数（`VideoSettings`，基础长度 35 字节，全部大端）。
///
/// 布局：
/// ```
/// offset size field
/// 0      4    bitrate
/// 4      4    maxFps
/// 8      1    iFrameInterval
/// 9      2    bounds.width
/// 11     2    bounds.height
/// 13     2    crop.left
/// 15     2    crop.top
/// 17     2    crop.right
/// 19     2    crop.bottom
/// 21     1    sendFrameMeta
/// 22     1    lockedVideoOrientation（-1 表示不锁定）
/// 23     4    displayId
/// 27     4    codecOptions 长度 + 内容
/// ...    4    encoderName 长度 + 内容
/// ```
class VideoSettings {
  const VideoSettings({
    this.bitrate = defaultBitrate,
    this.maxFps = 0,
    this.iFrameInterval = defaultIFrameInterval,
    this.bounds,
    this.crop,
    this.sendFrameMeta = false,
    this.lockedVideoOrientation = unlockedOrientation,
    this.displayId = DisplayInfo.defaultDisplayId,
    this.codecOptions,
    this.encoderName,
  });

  /// 不含可选字符串字段的基础长度。
  static const int baseBufferLength = 35;

  /// 默认码率：8 Mbps（与服务端网页端默认值一致）。
  static const int defaultBitrate = 8000000;

  /// 默认关键帧间隔（秒）。
  static const int defaultIFrameInterval = 10;

  /// 不锁定方向。
  static const int unlockedOrientation = -1;

  final int bitrate;
  final int maxFps;
  final int iFrameInterval;
  final VideoSize? bounds;
  final VideoRect? crop;

  /// 是否在每帧前附加 12 字节帧信息（8 字节 PTS + 4 字节长度）。
  /// 裸 H.264（00 00 00 01 起始码）场景保持 false。
  final bool sendFrameMeta;

  final int lockedVideoOrientation;
  final int displayId;
  final String? codecOptions;
  final String? encoderName;

  static VideoSettings fromBuffer(Uint8List buffer) {
    if (buffer.length < baseBufferLength) {
      throw ParsingException(
        message: '视频参数长度不足：期望至少 $baseBufferLength 字节，实际 ${buffer.length} 字节',
      );
    }
    final view = ByteData.sublistView(buffer);
    final bitrate = view.getInt32(0, Endian.big);
    final maxFps = view.getInt32(4, Endian.big);
    final iFrameInterval = view.getInt8(8);
    final boundsWidth = view.getInt16(9, Endian.big);
    final boundsHeight = view.getInt16(11, Endian.big);
    final crop = VideoRect(
      left: view.getInt16(13, Endian.big),
      top: view.getInt16(15, Endian.big),
      right: view.getInt16(17, Endian.big),
      bottom: view.getInt16(19, Endian.big),
    );
    final sendFrameMeta = view.getInt8(21) != 0;
    final lockedVideoOrientation = view.getInt8(22);
    final displayId = view.getInt32(23, Endian.big);

    var offset = 27;
    String? readOptionalString() {
      if (offset + 4 > buffer.length) {
        return null;
      }
      final length = ByteData.sublistView(
        buffer,
        offset,
        offset + 4,
      ).getInt32(0, Endian.big);
      offset += 4;
      if (length <= 0 || offset + length > buffer.length) {
        offset += length > 0 ? length : 0;
        return null;
      }
      final value = utf8.decode(
        Uint8List.sublistView(buffer, offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      return value;
    }

    final codecOptions = readOptionalString();
    final encoderName = readOptionalString();

    return VideoSettings(
      bitrate: bitrate,
      maxFps: maxFps,
      iFrameInterval: iFrameInterval,
      bounds: (boundsWidth != 0 && boundsHeight != 0)
          ? VideoSize(boundsWidth, boundsHeight)
          : null,
      crop: (crop.width != 0 || crop.height != 0) ? crop : null,
      sendFrameMeta: sendFrameMeta,
      lockedVideoOrientation: lockedVideoOrientation,
      displayId: displayId,
      codecOptions: codecOptions,
      encoderName: encoderName,
    );
  }

  /// 编码为发送给服务端的参数缓冲区。
  Uint8List toBuffer() {
    final codecOptionsBytes = _optionalBytes(codecOptions);
    final encoderNameBytes = _optionalBytes(encoderName);
    final length =
        baseBufferLength + codecOptionsBytes.length + encoderNameBytes.length;
    final buffer = Uint8List(length);
    final view = ByteData.sublistView(buffer);
    view.setInt32(0, bitrate, Endian.big);
    view.setInt32(4, maxFps, Endian.big);
    view.setInt8(8, iFrameInterval);
    view.setInt16(9, bounds?.width ?? 0, Endian.big);
    view.setInt16(11, bounds?.height ?? 0, Endian.big);
    final effectiveCrop = crop ?? VideoRect.zero;
    view.setInt16(13, effectiveCrop.left, Endian.big);
    view.setInt16(15, effectiveCrop.top, Endian.big);
    view.setInt16(17, effectiveCrop.right, Endian.big);
    view.setInt16(19, effectiveCrop.bottom, Endian.big);
    view.setInt8(21, sendFrameMeta ? 1 : 0);
    view.setInt8(22, lockedVideoOrientation);
    view.setInt32(23, displayId, Endian.big);
    var offset = 27;
    view.setInt32(offset, codecOptionsBytes.length, Endian.big);
    offset += 4;
    buffer.setRange(
      offset,
      offset + codecOptionsBytes.length,
      codecOptionsBytes,
    );
    offset += codecOptionsBytes.length;
    view.setInt32(offset, encoderNameBytes.length, Endian.big);
    offset += 4;
    buffer.setRange(offset, offset + encoderNameBytes.length, encoderNameBytes);
    return buffer;
  }

  VideoSettings copyWith({
    int? bitrate,
    int? maxFps,
    int? iFrameInterval,
    VideoSize? bounds,
    VideoRect? crop,
    bool? sendFrameMeta,
    int? lockedVideoOrientation,
    int? displayId,
    String? codecOptions,
    String? encoderName,
  }) {
    return VideoSettings(
      bitrate: bitrate ?? this.bitrate,
      maxFps: maxFps ?? this.maxFps,
      iFrameInterval: iFrameInterval ?? this.iFrameInterval,
      bounds: bounds ?? this.bounds,
      crop: crop ?? this.crop,
      sendFrameMeta: sendFrameMeta ?? this.sendFrameMeta,
      lockedVideoOrientation:
          lockedVideoOrientation ?? this.lockedVideoOrientation,
      displayId: displayId ?? this.displayId,
      codecOptions: codecOptions ?? this.codecOptions,
      encoderName: encoderName ?? this.encoderName,
    );
  }

  static Uint8List _optionalBytes(String? value) {
    if (value == null || value.isEmpty) {
      return Uint8List(0);
    }
    return Uint8List.fromList(utf8.encode(value));
  }

  @override
  String toString() =>
      'VideoSettings(bitrate: $bitrate, maxFps: $maxFps, '
      'iFrameInterval: $iFrameInterval, bounds: $bounds, crop: $crop, '
      'sendFrameMeta: $sendFrameMeta, displayId: $displayId, '
      'encoderName: $encoderName)';
}
