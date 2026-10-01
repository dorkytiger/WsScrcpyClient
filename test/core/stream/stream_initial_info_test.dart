import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/stream_initial_info.dart';
import 'package:ws_scrcpy_client/core/stream/video_settings.dart';

import 'stream_fixtures.dart';

void main() {
  group('StreamInitialInfo 解析（真实报文）', () {
    test('能从真实初始头解析出设备名、显示器与编码器', () {
      final bytes = loadInitialInfoFixture();
      expect(StreamInitialInfo.matches(bytes), isTrue);

      final info = StreamInitialInfo.parse(bytes);
      expect(info.deviceName, 'redroid12_x86_64_only');
      expect(info.displays, isNotEmpty);
      expect(info.encoders, contains('c2.android.avc.encoder'));
      expect(info.clientId, greaterThanOrEqualTo(0));

      final display = info.displays.first;
      expect(display.displayInfo.displayId, DisplayInfo.defaultDisplayId);
      expect(display.displayInfo.size.width, greaterThan(0));
      expect(display.displayInfo.size.height, greaterThan(0));
    });

    test('非初始头的报文不会被识别', () {
      expect(
        StreamInitialInfo.matches(Uint8List.fromList(<int>[0, 0, 0, 1, 0x65])),
        isFalse,
      );
    });

    test('长度不足时抛 ParsingException', () {
      final bytes = Uint8List.fromList(<int>[
        ...StreamInitialInfo.magicBytes,
        1,
        2,
        3,
      ]);
      expect(
        () => StreamInitialInfo.parse(bytes),
        throwsA(isA<ParsingException>()),
      );
    });
  });

  group('VideoSettings 编解码', () {
    test('toBuffer 长度为基础 35 字节（无 encoderName/codecOptions）', () {
      const settings = VideoSettings();
      expect(settings.toBuffer().length, VideoSettings.baseBufferLength);
    });

    test('往返一致（含可选字符串字段）', () {
      const settings = VideoSettings(
        bitrate: 8000000,
        maxFps: 30,
        iFrameInterval: 5,
        bounds: VideoSize(1280, 720),
        crop: VideoRect(left: 1, top: 2, right: 3, bottom: 4),
        sendFrameMeta: false,
        lockedVideoOrientation: 1,
        displayId: 0,
        codecOptions: 'profile=1',
        encoderName: 'c2.android.avc.encoder',
      );

      final decoded = VideoSettings.fromBuffer(settings.toBuffer());
      expect(decoded.bitrate, settings.bitrate);
      expect(decoded.maxFps, settings.maxFps);
      expect(decoded.iFrameInterval, settings.iFrameInterval);
      expect(decoded.bounds, const VideoSize(1280, 720));
      expect(decoded.crop, isNotNull);
      expect(decoded.sendFrameMeta, isFalse);
      expect(decoded.lockedVideoOrientation, 1);
      expect(decoded.codecOptions, 'profile=1');
      expect(decoded.encoderName, 'c2.android.avc.encoder');
    });

    test('bounds 为 0 时按 null 解析（服务端用 0 表示未指定）', () {
      final decoded = VideoSettings.fromBuffer(
        const VideoSettings().toBuffer(),
      );
      expect(decoded.bounds, isNull);
      expect(decoded.crop, isNull);
    });

    test('长度不足时抛 ParsingException', () {
      expect(
        () => VideoSettings.fromBuffer(Uint8List(10)),
        throwsA(isA<ParsingException>()),
      );
    });
  });

  group('DisplayInfo / ScreenInfo', () {
    test('DisplayInfo 长度必须精确 24 字节', () {
      expect(
        () => DisplayInfo.fromBuffer(Uint8List(23)),
        throwsA(isA<ParsingException>()),
      );
    });

    test('ScreenInfo 从 25 字节解析', () {
      final buffer = Uint8List(ScreenInfo.bufferLength);
      final view = ByteData.sublistView(buffer)
        ..setInt32(0, 0, Endian.big)
        ..setInt32(4, 0, Endian.big)
        ..setInt32(8, 1280, Endian.big)
        ..setInt32(12, 720, Endian.big)
        ..setInt32(16, 1280, Endian.big)
        ..setInt32(20, 720, Endian.big)
        ..setUint8(24, 0);

      final info = ScreenInfo.fromBuffer(buffer);
      expect(info.contentRect.width, 1280);
      expect(info.contentRect.height, 720);
      expect(info.videoSize, const VideoSize(1280, 720));
      expect(info.deviceRotation, 0);
      expect(view.lengthInBytes, 25);
    });
  });
}
