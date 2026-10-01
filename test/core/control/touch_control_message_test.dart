import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/control/control_message.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/control/touch_control_message.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

import 'control_message_test_support.dart';

/// 触摸消息的期望字节（29 字节，全部大端）——逐条对照 bundle 模块 7444 的写序列：
///
/// ```js
/// writeUInt8(type) writeUInt8(action) writeUInt32BE(0) writeUInt32BE(pointerId)
/// writeUInt32BE(x) writeUInt32BE(y) writeUInt16BE(width) writeUInt16BE(height)
/// writeUInt16BE(pressure * 65535) writeUInt32BE(buttons)
/// ```
///
/// 注意第 29 字节：bundle 用 `Buffer.alloc(PAYLOAD_LENGTH + 1)`（=29）零填充，
/// 而写序列只覆盖偏移 0..27，故末字节恒为 `00`。
void main() {
  const screen = ScreenSize(width: 1080, height: 1920);

  group('TouchControlMessage 字节布局', () {
    test('down：action=0 / pointerId=1 / (300,640) / pressure=1.0 / buttons=primary', () {
      final message = TouchControlMessage(
        action: TouchAction.down,
        pointerId: 1,
        position: const TouchPosition(x: 300, y: 640, screenSize: screen),
        pressure: 1.0,
        buttons: AndroidMotionEventButtons.primary,
      );

      final bytes = message.toBuffer();

      expectBytes(
        bytes,
        hexBytes(
          '02 ' // 0      type = TYPE_TOUCH
          '00 ' // 1      action = down
          '00 00 00 00 ' // 2..5   pointerId 高 4 字节（恒 0）
          '00 00 00 01 ' // 6..9   pointerId 低 4 字节 = 1
          '00 00 01 2C ' // 10..13 x = 300
          '00 00 02 80 ' // 14..17 y = 640
          '04 38 ' // 18..19 screenWidth = 1080
          '07 80 ' // 20..21 screenHeight = 1920
          'FF FF ' // 22..23 pressure = 1.0 * 0xFFFF
          '00 00 00 01 ' // 24..27 buttons = primary
          '00', // 28     bundle 的零填充
        ),
      );
      expect(bytes, hasLength(TouchControlMessage.bufferLength));
      expect(bytes, hasLength(29));
      expect(message.type, ControlMessageType.touch);
    });

    test(
      'up：action=1 / pointerId=2 / (1000,1900) / pressure=0.0 / buttons=none',
      () {
        final message = TouchControlMessage(
          action: TouchAction.up,
          pointerId: 2,
          position: const TouchPosition(x: 1000, y: 1900, screenSize: screen),
          pressure: 0,
        );

        final bytes = message.toBuffer();

        expectBytes(
          bytes,
          hexBytes(
            '02 ' // 0      type = TYPE_TOUCH
            '01 ' // 1      action = up
            '00 00 00 00 ' // 2..5   pointerId 高 4 字节
            '00 00 00 02 ' // 6..9   pointerId = 2
            '00 00 03 E8 ' // 10..13 x = 1000
            '00 00 07 6C ' // 14..17 y = 1900
            '04 38 ' // 18..19 screenWidth = 1080
            '07 80 ' // 20..21 screenHeight = 1920
            '00 00 ' // 22..23 pressure = 0
            '00 00 00 00 ' // 24..27 buttons = none（默认值）
            '00', // 28     零填充
          ),
        );
        expect(bytes, hasLength(29));
      },
    );

    test('move：action=2 / pointerId=5 / (1079,0) / pressure=0.75 / buttons=primary|secondary', () {
      // 0.75 * 65535 = 49151.25 → 四舍五入 49151 = 0xBFFF
      final message = TouchControlMessage(
        action: TouchAction.move,
        pointerId: 5,
        position: const TouchPosition(x: 1079, y: 0, screenSize: screen),
        pressure: 0.75,
        buttons:
            AndroidMotionEventButtons.primary |
            AndroidMotionEventButtons.secondary,
      );

      final bytes = message.toBuffer();

      expectBytes(
        bytes,
        hexBytes(
          '02 ' // 0      type = TYPE_TOUCH
          '02 ' // 1      action = move
          '00 00 00 00 ' // 2..5   pointerId 高 4 字节
          '00 00 00 05 ' // 6..9   pointerId = 5
          '00 00 04 37 ' // 10..13 x = 1079
          '00 00 00 00 ' // 14..17 y = 0
          '04 38 ' // 18..19 screenWidth = 1080
          '07 80 ' // 20..21 screenHeight = 1920
          'BF FF ' // 22..23 pressure = 49151
          '00 00 00 03 ' // 24..27 buttons = primary | secondary
          '00', // 28     零填充
        ),
      );
      expect(bytes, hasLength(29));
    });

    test('screenSize / pressure / buttons 都按大端写入固定偏移', () {
      // x/y 必须是 uint16 可表达的坐标（受 screenSize 上限约束），
      // 但 pointerId / buttons 是 uint32，可以用满 4 字节来验证字节序。
      final bytes = TouchControlMessage(
        action: TouchAction.down,
        pointerId: 0x0A0B0C0D,
        position: const TouchPosition(
          x: 0xABCD,
          y: 0x1234,
          screenSize: ScreenSize(width: 0xFFFF, height: 0x8000),
        ),
        pressure: 1.0,
        buttons: 0x10203040,
      ).toBuffer();

      final view = ByteData.sublistView(bytes);
      // 大端校验：高位在前，读回来的值应与写入值一致（若写成小端会不相等）。
      expect(view.getUint32(TouchControlMessage.xOffset, Endian.big), 0xABCD);
      expect(view.getUint32(TouchControlMessage.yOffset, Endian.big), 0x1234);
      expect(bytes.sublist(10, 14), [0x00, 0x00, 0xAB, 0xCD]);
      expect(bytes.sublist(14, 18), [0x00, 0x00, 0x12, 0x34]);
      expect(
        view.getUint16(TouchControlMessage.screenWidthOffset, Endian.big),
        0xFFFF,
      );
      expect(
        view.getUint16(TouchControlMessage.screenHeightOffset, Endian.big),
        0x8000,
      );
      expect(bytes.sublist(18, 20), [0xFF, 0xFF]);
      expect(bytes.sublist(20, 22), [0x80, 0x00]);
      expect(
        view.getUint16(TouchControlMessage.pressureOffset, Endian.big),
        TouchControlMessage.maxPressureValue,
      );
      expect(
        view.getUint32(TouchControlMessage.pointerIdLowOffset, Endian.big),
        0x0A0B0C0D,
      );
      expect(
        // pointerId 高 4 字节必须是 0（java long 高位）。
        bytes.sublist(
          TouchControlMessage.pointerIdHighOffset,
          TouchControlMessage.pointerIdLowOffset,
        ),
        [0, 0, 0, 0],
      );
      expect(
        view.getUint32(TouchControlMessage.buttonsOffset, Endian.big),
        0x10203040,
      );
      expect(bytes.sublist(24, 28), [0x10, 0x20, 0x30, 0x40]);
    });
  });

  group('TouchControlMessage 入参校验', () {
    test('pressure 超出 0..1 抛 ValidationException', () {
      expect(
        () => TouchControlMessage(
          action: TouchAction.down,
          pointerId: 0,
          position: const TouchPosition(x: 0, y: 0, screenSize: screen),
          pressure: 1.2,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => TouchControlMessage(
          action: TouchAction.down,
          pointerId: 0,
          position: const TouchPosition(x: 0, y: 0, screenSize: screen),
          pressure: double.nan,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('坐标超出屏幕范围抛 ValidationException', () {
      expect(
        () => TouchControlMessage(
          action: TouchAction.move,
          pointerId: 0,
          position: const TouchPosition(x: 1081, y: 10, screenSize: screen),
          pressure: 0.5,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => TouchControlMessage(
          action: TouchAction.move,
          pointerId: 0,
          position: const TouchPosition(x: 10, y: -1, screenSize: screen),
          pressure: 0.5,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('屏幕尺寸为 0 或超 uint16 抛 ValidationException', () {
      expect(
        () => TouchControlMessage(
          action: TouchAction.down,
          pointerId: 0,
          position: const TouchPosition(
            x: 0,
            y: 0,
            screenSize: ScreenSize(width: 0, height: 100),
          ),
          pressure: 0.5,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => TouchControlMessage(
          action: TouchAction.down,
          pointerId: 0,
          position: const TouchPosition(
            x: 0,
            y: 0,
            screenSize: ScreenSize(width: 70000, height: 100),
          ),
          pressure: 0.5,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('pointerId 超出 uint32 抛 ValidationException', () {
      expect(
        () => TouchControlMessage(
          action: TouchAction.down,
          pointerId: 0x100000000,
          position: const TouchPosition(x: 0, y: 0, screenSize: screen),
          pressure: 0.5,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('AndroidMotionEventButtons 取值', () {
    test('bundle 里集中定义的前三个（1/2/4）', () {
      expect(AndroidMotionEventButtons.primary, 1);
      expect(AndroidMotionEventButtons.secondary, 2);
      expect(AndroidMotionEventButtons.tertiary, 4);
    });

    test('bundle 未定义、按 scrcpy control_msg.h 补全的 back/forward（8/16）', () {
      expect(AndroidMotionEventButtons.back, 8);
      expect(AndroidMotionEventButtons.forward, 16);
    });

    test('是位掩码：可以按位或组合', () {
      expect(
        AndroidMotionEventButtons.primary | AndroidMotionEventButtons.tertiary,
        5,
      );
    });
  });
}
