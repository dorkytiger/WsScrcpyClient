import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/control/android_key_code.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/control/key_code_control_message.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

import 'control_message_test_support.dart';

/// 按键消息的期望字节（14 字节，全部大端）——对照 bundle 模块 3125 的写序列：
///
/// ```js
/// writeInt8(type) writeInt8(action) writeInt32BE(keycode)
/// writeInt32BE(repeat) writeInt32BE(metaState)
/// ```
void main() {
  group('KeyCodeControlMessage 字节布局', () {
    test(
      'down HOME：type=0 / action=0 / keycode=3 / repeat=0 / metaState=0',
      () {
        final message = KeyCodeControlMessage(
          action: KeyCodeAction.down,
          keycode: AndroidKeyCode.home,
        );

        final bytes = message.toBuffer();

        expectBytes(
          bytes,
          hexBytes(
            '00 ' // 0     type = TYPE_KEYCODE
            '00 ' // 1     action = down
            '00 00 00 03 ' // 2..5  keycode = HOME(3)
            '00 00 00 00 ' // 6..9  repeat = 0
            '00 00 00 00', // 10..13 metaState = 0
          ),
        );
        expect(bytes, hasLength(KeyCodeControlMessage.bufferLength));
        expect(bytes, hasLength(14));
        expect(message.type, ControlMessageType.keycode);
      },
    );

    test(
      'up APP_SWITCH：action=1 / keycode=187 / repeat=2 / metaState=Shift|Ctrl',
      () {
        final message = KeyCodeControlMessage(
          action: KeyCodeAction.up,
          keycode: AndroidKeyCode.appSwitch,
          repeat: 2,
          metaState: KeyCodeMetaState.shiftOn | KeyCodeMetaState.ctrlOn,
        );

        expectBytes(
          message.toBuffer(),
          hexBytes(
            '00 ' // 0     type = TYPE_KEYCODE
            '01 ' // 1     action = up
            '00 00 00 BB ' // 2..5  keycode = APP_SWITCH(187) = 0xBB
            '00 00 00 02 ' // 6..9  repeat = 2
            '00 00 10 01', // 10..13 metaState = 1 | 4096 = 0x1001
          ),
        );
      },
    );

    test('三个 int32 字段确实是大端（写成小端读回来会不等）', () {
      final bytes = KeyCodeControlMessage(
        action: KeyCodeAction.down,
        keycode: 0x01020304,
        repeat: 0x05060708,
        metaState: 0x090A0B0C,
      ).toBuffer();

      expectBytes(
        bytes,
        hexBytes(
          '00 00 '
          '01 02 03 04 '
          '05 06 07 08 '
          '09 0A 0B 0C',
        ),
      );
    });

    test('metaState 位掩码可与 bundle 的 META_* 常量按位或组合', () {
      final bytes = KeyCodeControlMessage(
        action: KeyCodeAction.down,
        keycode: AndroidKeyCode.enter,
        metaState:
            KeyCodeMetaState.altOn |
            KeyCodeMetaState.shiftOn |
            KeyCodeMetaState.ctrlOn |
            KeyCodeMetaState.metaOn |
            KeyCodeMetaState.capsLockOn |
            KeyCodeMetaState.scrollLockOn |
            KeyCodeMetaState.numLockOn,
      ).toBuffer();

      // altOn(2) | shiftOn(1) | ctrlOn(4096) | metaOn(65536)
      // | capsLockOn(1048576) | scrollLockOn(4194304) | numLockOn(2097152)
      // = 0x711003
      expectBytes(bytes.sublist(10, 14), hexBytes('00 71 10 03'));
    });
  });

  group('AndroidKeyCode 常量（实测自 bundle 的 AndroidKeyCode 表）', () {
    test('任务要求的九个取值', () {
      expect(AndroidKeyCode.home, 3);
      expect(AndroidKeyCode.back, 4);
      expect(AndroidKeyCode.appSwitch, 187);
      expect(AndroidKeyCode.power, 26);
      expect(AndroidKeyCode.volumeUp, 24);
      expect(AndroidKeyCode.volumeDown, 25);
      expect(AndroidKeyCode.enter, 66);
      expect(AndroidKeyCode.wakeup, 224);
      expect(AndroidKeyCode.menu, 82);
    });

    test('补充的常用取值', () {
      expect(AndroidKeyCode.unknown, 0);
      expect(AndroidKeyCode.sleep, 223);
      expect(AndroidKeyCode.volumeMute, 164);
      expect(AndroidKeyCode.del, 67);
      expect(AndroidKeyCode.forwardDel, 112);
      expect(AndroidKeyCode.tab, 61);
      expect(AndroidKeyCode.space, 62);
      expect(AndroidKeyCode.escape, 111);
      expect(AndroidKeyCode.notification, 83);
      expect(AndroidKeyCode.mediaPlayPause, 85);
      expect(AndroidKeyCode.camera, 27);
      expect(AndroidKeyCode.assist, 219);
      expect(AndroidKeyCode.brightnessDown, 220);
      expect(AndroidKeyCode.brightnessUp, 221);
    });
  });

  group('KeyCodeMetaState 常量（实测自 bundle）', () {
    test('位掩码取值', () {
      expect(KeyCodeMetaState.shiftOn, 1);
      expect(KeyCodeMetaState.altOn, 2);
      expect(KeyCodeMetaState.symOn, 4);
      expect(KeyCodeMetaState.functionOn, 8);
      expect(KeyCodeMetaState.altLeftOn, 16);
      expect(KeyCodeMetaState.altRightOn, 32);
      expect(KeyCodeMetaState.shiftLeftOn, 64);
      expect(KeyCodeMetaState.shiftRightOn, 128);
      expect(KeyCodeMetaState.ctrlOn, 4096);
      expect(KeyCodeMetaState.ctrlLeftOn, 8192);
      expect(KeyCodeMetaState.ctrlRightOn, 16384);
      expect(KeyCodeMetaState.metaOn, 65536);
      expect(KeyCodeMetaState.metaLeftOn, 131072);
      expect(KeyCodeMetaState.metaRightOn, 262144);
      expect(KeyCodeMetaState.capsLockOn, 1048576);
      expect(KeyCodeMetaState.numLockOn, 2097152);
      expect(KeyCodeMetaState.scrollLockOn, 4194304);
    });
  });

  group('KeyCodeControlMessage 入参校验', () {
    test('keycode / repeat / metaState 为负或超 int32 抛 ValidationException', () {
      expect(
        () => KeyCodeControlMessage(action: KeyCodeAction.down, keycode: -1),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => KeyCodeControlMessage(
          action: KeyCodeAction.down,
          keycode: AndroidKeyCode.home,
          repeat: -1,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => KeyCodeControlMessage(
          action: KeyCodeAction.down,
          keycode: AndroidKeyCode.home,
          metaState: 0x80000000,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
