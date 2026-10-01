import 'dart:convert';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/video_settings.dart';

/// 一路显示器（display）的投流状态。
class DisplayStreamState {
  const DisplayStreamState({
    required this.displayInfo,
    required this.connectionCount,
    this.screenInfo,
    this.videoSettings,
  });

  final DisplayInfo displayInfo;

  /// 当前该显示器上的投流客户端数量；0 表示我们是第一个。
  final int connectionCount;

  /// 为空表示服务端尚未开始编码，需要客户端下发 [VideoSettings] 才会启动。
  final ScreenInfo? screenInfo;

  /// 服务端当前的编码参数。
  final VideoSettings? videoSettings;

  /// 服务端是否已经在推流。
  bool get isStreaming => screenInfo != null && videoSettings != null;

  @override
  String toString() =>
      'DisplayStreamState(displayInfo: $displayInfo, '
      'connectionCount: $connectionCount, screenInfo: $screenInfo, '
      'videoSettings: $videoSettings)';
}

/// 投流通道的初始信息头（ws-scrcpy 服务端在 WS 建立后下发的第一条二进制消息）。
///
/// 实测结构（`scrcpy_initial`，全部大端）：
/// ```
/// offset size field
/// 0      14   magic = "scrcpy_initial"
/// 14     64   deviceName（utf8，尾部 \\0 填充）
/// 78     4    displayCount
///             per display:
///               DisplayInfo(24)
///               connectionCount: i32
///               screenInfoLen: i32 (+ screenInfo，可能为 0)
///               videoSettingsLen: i32 (+ videoSettings，可能为 0)
///             encoderCount: i32 (+ 每项 [len:i32][utf8 名称])
///             clientId: i32
/// ```
class StreamInitialInfo {
  const StreamInitialInfo({
    required this.deviceName,
    required this.displays,
    required this.encoders,
    required this.clientId,
  });

  /// 魔数，用于判断一帧是初始信息头还是视频数据。
  static const String magic = 'scrcpy_initial';

  /// 设备名固定字段长度。
  static const int deviceNameFieldLength = 64;

  static final Uint8List magicBytes = Uint8List.fromList(utf8.encode(magic));

  final String deviceName;
  final List<DisplayStreamState> displays;
  final List<String> encoders;
  final int clientId;

  /// 判断一条二进制消息是否为初始信息头。
  static bool matches(Uint8List data) {
    if (data.length <= magicBytes.length) {
      return false;
    }
    for (var i = 0; i < magicBytes.length; i++) {
      if (data[i] != magicBytes[i]) {
        return false;
      }
    }
    return true;
  }

  /// 解析初始信息头。
  ///
  /// 尽量复用服务端网页端同一套字段顺序；任何长度越界都返回 [ParsingException]。
  static StreamInitialInfo parse(Uint8List data) {
    var offset = magicBytes.length;
    final required =
        magicBytes.length + deviceNameFieldLength + 4 /*displayCount*/;
    if (data.length < required) {
      throw ParsingException(
        message: '初始信息头长度不足：收到 ${data.length} 字节，至少需要 $required 字节',
      );
    }
    final deviceName = _readPaddedString(data, offset, deviceNameFieldLength);
    offset += deviceNameFieldLength;

    int readInt32() {
      if (offset + 4 > data.length) {
        throw ParsingException(message: '初始信息头在偏移 $offset 处缺少 int32 字段');
      }
      final value = ByteData.sublistView(
        data,
        offset,
        offset + 4,
      ).getInt32(0, Endian.big);
      offset += 4;
      return value;
    }

    Uint8List readBytes(int length) {
      if (length < 0 || offset + length > data.length) {
        throw ParsingException(
          message: '初始信息头字段越界：偏移 $offset 需要 $length 字节，总长 ${data.length}',
        );
      }
      final slice = Uint8List.sublistView(data, offset, offset + length);
      offset += length;
      return slice;
    }

    final displayCount = readInt32();
    final displays = <DisplayStreamState>[];
    for (var i = 0; i < displayCount; i++) {
      final displayInfo = DisplayInfo.fromBuffer(
        readBytes(DisplayInfo.bufferLength),
      );
      final connectionCount = readInt32();
      final screenInfoLength = readInt32();
      final screenInfo = screenInfoLength > 0
          ? ScreenInfo.fromBuffer(readBytes(screenInfoLength))
          : null;
      final videoSettingsLength = readInt32();
      final videoSettings = videoSettingsLength > 0
          ? VideoSettings.fromBuffer(readBytes(videoSettingsLength))
          : null;
      displays.add(
        DisplayStreamState(
          displayInfo: displayInfo,
          connectionCount: connectionCount,
          screenInfo: screenInfo,
          videoSettings: videoSettings,
        ),
      );
    }

    final encoderCount = readInt32();
    final encoders = <String>[];
    for (var i = 0; i < encoderCount; i++) {
      final length = readInt32();
      encoders.add(utf8.decode(readBytes(length), allowMalformed: true));
    }

    final clientId = readInt32();

    return StreamInitialInfo(
      deviceName: deviceName,
      displays: displays,
      encoders: encoders,
      clientId: clientId,
    );
  }

  static String _readPaddedString(Uint8List data, int offset, int length) {
    var end = offset + length;
    var cursor = offset;
    while (cursor < end && data[cursor] != 0) {
      cursor++;
    }
    end = cursor;
    return utf8.decode(
      Uint8List.sublistView(data, offset, end),
      allowMalformed: true,
    );
  }

  @override
  String toString() =>
      'StreamInitialInfo(deviceName: $deviceName, displays: $displays, '
      'encoders: $encoders, clientId: $clientId)';
}
