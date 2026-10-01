import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/stream/annex_b_parser.dart';

import 'stream_fixtures.dart';

void main() {
  group('AnnexBParser（真实报文）', () {
    late List<Uint8List> frames;

    setUpAll(() {
      frames = loadVideoFrameFixture();
    });

    test('夹具里至少有 3 条真实视频消息', () {
      expect(frames.length, greaterThanOrEqualTo(3));
    });

    test('每条消息都以 00 00 00 01 起始码开头', () {
      for (final frame in frames) {
        expect(AnnexBParser.hasStartCode(frame), isTrue);
      }
    });

    test('第 1 条是 SPS + PPS 两条 NAL', () {
      final units = AnnexBParser.split(frames.first);
      expect(units, hasLength(2));
      expect(units[0].isSps, isTrue);
      expect(units[1].isPps, isTrue);
      expect(units[0].startCodeLength, 4);
    });

    test('第 2 条是 IDR 关键帧', () {
      final units = AnnexBParser.split(frames[1]);
      expect(units, isNotEmpty);
      expect(units.first.type, H264NalUnit.typeIdrSlice);
      expect(units.first.isKeyFrame, isTrue);
    });

    test('后续消息是非 IDR 片', () {
      if (frames.length < 3) {
        return;
      }
      final units = AnnexBParser.split(frames[2]);
      expect(units, isNotEmpty);
      expect(units.first.type, H264NalUnit.typeNonIdrSlice);
      expect(units.first.isKeyFrame, isFalse);
    });
  });

  group('AnnexBParser 边界', () {
    test('3 字节起始码也能识别', () {
      final frame = Uint8List.fromList(<int>[0, 0, 1, 0x61, 0xAA, 0xBB]);
      final units = AnnexBParser.split(frame);
      expect(units, hasLength(1));
      expect(units.single.type, H264NalUnit.typeNonIdrSlice);
      expect(units.single.startCodeLength, 3);
      expect(units.single.data, <int>[0x61, 0xAA, 0xBB]);
    });

    test('没有起始码时返回空列表', () {
      expect(
        AnnexBParser.split(Uint8List.fromList(<int>[1, 2, 3, 4])),
        isEmpty,
      );
      expect(
        AnnexBParser.hasStartCode(Uint8List.fromList(<int>[1, 2, 3, 4])),
        isFalse,
      );
    });

    test('截断的起始码不会越界', () {
      expect(AnnexBParser.split(Uint8List.fromList(<int>[0, 0])), isEmpty);
      expect(
        AnnexBParser.hasStartCode(Uint8List.fromList(<int>[0, 0, 1])),
        isFalse,
      );
    });

    test('空帧安全返回', () {
      expect(AnnexBParser.split(Uint8List(0)), isEmpty);
    });
  });
}
