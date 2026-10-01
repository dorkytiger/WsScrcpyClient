import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/ws/multiplexer_message.dart';
import 'package:ws_scrcpy_client/core/ws/multiplexer_message_type.dart';

void main() {
  group('MultiplexerMessage 编码', () {
    test('帧头为 type(1) + channelId(uint32 小端) + payload', () {
      final message = MultiplexerMessage(
        type: MessageType.createChannel,
        channelId: 0x01020304,
        payload: Uint8List.fromList(<int>[0xAA, 0xBB]),
      );

      expect(message.encode(), <int>[
        4 /*createChannel*/,
        0x04,
        0x03,
        0x02,
        0x01 /*小端*/,
        0xAA,
        0xBB,
      ]);
    });

    test('payload 为空时不写多余字节', () {
      final bytes = MultiplexerMessage.encodeFrame(
        type: MessageType.closeChannel,
        channelId: 1,
      );
      expect(bytes.length, MultiplexerMessage.headerLength);
    });
  });

  group('MultiplexerMessage 解析', () {
    test('解析出类型、小端通道 id 与 payload', () {
      final decoded = MultiplexerMessage.decode(
        Uint8List.fromList(<int>[
          16 /*rawBinaryData*/,
          0x0A,
          0x00,
          0x00,
          0x00,
          0x01,
          0x02,
        ]),
      );
      expect(decoded.type, MessageType.rawBinaryData);
      expect(decoded.channelId, 10);
      expect(decoded.payload, <int>[1, 2]);
    });

    test('长度不足 5 字节时抛 ParsingException（半包防御）', () {
      expect(
        () => MultiplexerMessage.decode(Uint8List.fromList(<int>[4, 1, 0])),
        throwsA(isA<ParsingException>()),
      );
    });

    test('未知类型抛 ParsingException，不静默当成正常帧', () {
      expect(
        () => MultiplexerMessage.decode(
          Uint8List.fromList(<int>[0xFF, 1, 0, 0, 0]),
        ),
        throwsA(isA<ParsingException>()),
      );
    });
  });

  group('ChannelCloseEvent 解析', () {
    test('code + reasonLength(uint32 小端) + reason(utf8)', () {
      final reason = Uint8List.fromList(<int>[0xE6, 0x96, 0xAD]); // "断"
      final payload = Uint8List(6 + reason.length);
      ByteData.sublistView(payload)
        ..setUint16(0, 1000, Endian.little)
        ..setUint32(2, reason.length, Endian.little);
      payload.setRange(6, payload.length, reason);

      final event = MultiplexerMessage(
        type: MessageType.closeChannel,
        channelId: 1,
        payload: payload,
      ).decodeCloseEvent();

      expect(event.code, 1000);
      expect(event.reason, '断');
      expect(event.wasClean, isTrue);
    });

    test('只有 code 时 reason 为 null', () {
      final payload = Uint8List(2);
      ByteData.sublistView(payload).setUint16(0, 1006, Endian.little);
      final event = MultiplexerMessage(
        type: MessageType.closeChannel,
        channelId: 1,
        payload: payload,
      ).decodeCloseEvent();

      expect(event.code, 1006);
      expect(event.reason, isNull);
      expect(event.wasClean, isFalse);
    });
  });

  group('MessageType.fromCode', () {
    test('已知取值逐一映射', () {
      expect(MessageType.fromCode(4), MessageType.createChannel);
      expect(MessageType.fromCode(8), MessageType.closeChannel);
      expect(MessageType.fromCode(16), MessageType.rawBinaryData);
      expect(MessageType.fromCode(32), MessageType.rawStringData);
      expect(MessageType.fromCode(64), MessageType.data);
    });

    test('未知取值回落到 unknown', () {
      expect(MessageType.fromCode(99), MessageType.unknown);
    });
  });
}
