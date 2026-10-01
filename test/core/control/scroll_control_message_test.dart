import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/control/control_message.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/control/scroll_control_message.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

import 'control_message_test_support.dart';

/// 滚动消息的期望字节（21 字节，全部大端）——对照 bundle 模块 3762 的写序列：
///
/// ```js
/// writeUInt8(type) writeUInt32BE(x) writeUInt32BE(y)
/// writeUInt16BE(screenWidth) writeUInt16BE(screenHeight)
/// writeInt32BE(hScroll) writeInt32BE(vScroll)
/// ```
///
/// 滚动消息**没有** action / pointerId / pressure / buttons，长度是 21 而不是 29。
void main() {
  const screen = ScreenSize(width: 1080, height: 1920);

  group('ScrollControlMessage 字节布局', () {
    test('向后滚一格：hScroll=-1 / vScroll=1（有符号，负值写补码）', () {
      final message = ScrollControlMessage(
        position: const TouchPosition(x: 200, y: 300, screenSize: screen),
        hScroll: -1,
        vScroll: 1,
      );

      final bytes = message.toBuffer();

      expectBytes(
        bytes,
        hexBytes(
          '03 ' // 0      type = TYPE_SCROLL
          '00 00 00 C8 ' // 1..4   x = 200
          '00 00 01 2C ' // 5..8   y = 300
          '04 38 ' // 9..10  screenWidth = 1080
          '07 80 ' // 11..12 screenHeight = 1920
          'FF FF FF FF ' // 13..16 hScroll = -1（int32 补码）
          '00 00 00 01', // 17..20 vScroll = 1
        ),
      );
      expect(bytes, hasLength(ScrollControlMessage.bufferLength));
      expect(bytes, hasLength(21));
      expect(message.type, ControlMessageType.scroll);
    });

    test('不滚动：hScroll=0 / vScroll=0', () {
      expectBytes(
        ScrollControlMessage(
          position: const TouchPosition(x: 0, y: 0, screenSize: screen),
          hScroll: 0,
          vScroll: 0,
        ).toBuffer(),
        hexBytes(
          '03 '
          '00 00 00 00 '
          '00 00 00 00 '
          '04 38 '
          '07 80 '
          '00 00 00 00 '
          '00 00 00 00',
        ),
      );
    });

    test('hScroll / vScroll 是有符号 int32，读取应还原负值', () {
      final bytes = ScrollControlMessage(
        position: const TouchPosition(x: 320, y: 240, screenSize: screen),
        hScroll: 0x7FFFFFFF,
        vScroll: -0x80000000,
      ).toBuffer();

      final view = ByteData.sublistView(bytes);
      expect(
        view.getInt32(ScrollControlMessage.hScrollOffset, Endian.big),
        0x7FFFFFFF,
      );
      expect(
        view.getInt32(ScrollControlMessage.vScrollOffset, Endian.big),
        -0x80000000,
      );
      expectBytes(bytes.sublist(13, 21), hexBytes('7F FF FF FF 80 00 00 00'));
    });
  });

  group('ScrollControlMessage 入参校验', () {
    test('滚动量超出 int32 抛 ValidationException', () {
      expect(
        () => ScrollControlMessage(
          position: const TouchPosition(x: 0, y: 0, screenSize: screen),
          hScroll: 0x80000000,
          vScroll: 0,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => ScrollControlMessage(
          position: const TouchPosition(x: 0, y: 0, screenSize: screen),
          hScroll: 0,
          vScroll: -0x80000001,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('坐标超出屏幕范围抛 ValidationException', () {
      expect(
        () => ScrollControlMessage(
          position: const TouchPosition(x: 0, y: 1921, screenSize: screen),
          hScroll: 0,
          vScroll: 0,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
