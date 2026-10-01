import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/control/key_code_control_message.dart';
import 'package:ws_scrcpy_client/core/control/touch_control_message.dart';

void main() {
  group('ControlMessageType', () {
    test('type 常量与 .probe/bundle.js 的 ControlMessage.ts 实测值一致', () {
      // 期望值逐条抄自 bundle webpack 模块 831 的
      // e.TYPE_KEYCODE=0, e.TYPE_TEXT=1, ... e.TYPE_PUSH_FILE=102。
      expect(ControlMessageType.keycode.code, 0);
      expect(ControlMessageType.text.code, 1);
      expect(ControlMessageType.touch.code, 2);
      expect(ControlMessageType.scroll.code, 3);
      expect(ControlMessageType.backOrScreenOn.code, 4);
      expect(ControlMessageType.expandNotificationPanel.code, 5);
      expect(ControlMessageType.expandSettingsPanel.code, 6);
      expect(ControlMessageType.collapsePanels.code, 7);
      expect(ControlMessageType.getClipboard.code, 8);
      expect(ControlMessageType.setClipboard.code, 9);
      expect(ControlMessageType.setScreenPowerMode.code, 10);
      expect(ControlMessageType.rotateDevice.code, 11);
      expect(ControlMessageType.changeStreamParameters.code, 101);
      expect(ControlMessageType.pushFile.code, 102);
    });

    test('code 唯一：没有两个类型共用同一个线上取值', () {
      final seen = <int>{};
      for (final type in ControlMessageType.values) {
        expect(seen.add(type.code), isTrue, reason: 'code 重复：${type.code}');
      }
    });

    test('fromCode 对全部已知取值都能往返', () {
      for (final type in ControlMessageType.values) {
        expect(ControlMessageType.fromCode(type.code), type);
      }
    });

    test('fromCode 对未知取值返回 null（不静默当成正常值）', () {
      // 12..100 与 103+ 都是 bundle 里未定义的取值。
      for (final unknown in <int>[12, 13, 100, 103, 255, -1]) {
        expect(
          ControlMessageType.fromCode(unknown),
          isNull,
          reason: '未知 type=$unknown 必须返回 null 交给调用方记日志',
        );
      }
    });
  });

  group('TouchAction', () {
    test('取值来自 bundle 的 AndroidMotionEvent（0/1/2）', () {
      expect(TouchAction.down.code, 0);
      expect(TouchAction.up.code, 1);
      expect(TouchAction.move.code, 2);
    });

    test('fromCode 已知往返、未知返回 null', () {
      expect(TouchAction.fromCode(0), TouchAction.down);
      expect(TouchAction.fromCode(1), TouchAction.up);
      expect(TouchAction.fromCode(2), TouchAction.move);
      expect(TouchAction.fromCode(3), isNull);
      expect(TouchAction.fromCode(-1), isNull);
    });
  });

  group('KeyCodeAction', () {
    test('取值来自 bundle 的 AndroidMotionEvent（0/1，没有 move）', () {
      expect(KeyCodeAction.down.code, 0);
      expect(KeyCodeAction.up.code, 1);
    });

    test('fromCode 已知往返、未知返回 null', () {
      expect(KeyCodeAction.fromCode(0), KeyCodeAction.down);
      expect(KeyCodeAction.fromCode(1), KeyCodeAction.up);
      expect(KeyCodeAction.fromCode(2), isNull);
    });
  });
}
