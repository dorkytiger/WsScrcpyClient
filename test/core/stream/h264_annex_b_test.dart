import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/stream/h264_annex_b.dart';

import '../../core/stream/stream_fixtures.dart';

/// 用**真实抓包**（`test/fixtures/stream_first_video_frames.txt`）钉住解析结果。
///
/// 这条链只服务 web 端（原生三端把整条消息直接喂系统解码器），所以这里用夹具而不是
/// 手写字节，避免"我照着记忆写了个 SPS"这种事。
void main() {
  final frames = loadVideoFrameFixture();
  final parameterSets = frames.first; // SPS + PPS，没有片数据
  final idr = frames[1]; // IDR 片（截断到 256 字节，但 NAL 类型完整）

  group('H264AnnexB.split', () {
    test('真实首帧：一条消息里有 SPS(7) + PPS(8)，没有片数据', () {
      final types = H264AnnexB.split(parameterSets)
          .map((H264NalUnit unit) => unit.type)
          .toList();
      expect(types, <int>[7, 8]);
      expect(H264AnnexB.hasIdr(parameterSets), isFalse);
      expect(H264AnnexB.hasParameterSets(parameterSets), isTrue);
    });

    test('真实第二条：IDR 片（type=5），要当 key 帧喂给 WebCodecs', () {
      final types = H264AnnexB.split(idr)
          .map((H264NalUnit unit) => unit.type)
          .toList();
      expect(types, contains(5));
      expect(H264AnnexB.hasIdr(idr), isTrue);
    });

    test('4 字节与 3 字节起始码都能切，且不会把 NAL 头算进 payload', () {
      // 3 字节起始码：00 00 01 67 …
      final threeByte = Uint8List.fromList(<int>[0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68, 0xCE]);
      final units = H264AnnexB.split(threeByte);
      expect(units, hasLength(2));
      expect(units[0].type, 7);
      expect(units[0].payloadOffset, 4);
      expect(units[0].end, 5, reason: '到下一个起始码之前为止（尾部零字节不算）');
      expect(units[1].type, 8);
    });

    test('没有起始码 → 空列表（调用方据此拒绝这条消息，而不是猜）', () {
      expect(H264AnnexB.split(Uint8List.fromList(<int>[1, 2, 3, 4])), isEmpty);
      expect(H264AnnexB.split(Uint8List(0)), isEmpty);
      expect(H264AnnexB.avcCodecString(Uint8List.fromList(<int>[1, 2, 3])), isNull);
    });
  });

  group('H264AnnexB.avcCodecString', () {
    test('★ 真实 SPS（67 42 c0 29 …）→ avc1.42c029（Baseline 4.1）', () {
      // WebCodecs 的 VideoDecoderConfig.codec 要这个串；造错会被 configure 直接拒绝。
      expect(H264AnnexB.avcCodecString(parameterSets), 'avc1.42c029');
    });

    test('进制与补零：小数值也要两位', () {
      // profile 0x42=66(Baseline) / constraints 0x00 / level 0x1E=30(3.0)
      final sps = Uint8List.fromList(<int>[0, 0, 1, 0x67, 0x42, 0x00, 0x1E, 0x00]);
      expect(H264AnnexB.avcCodecString(sps), 'avc1.42001e');
    });
  });
}
