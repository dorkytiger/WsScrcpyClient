import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/control/android_key_code.dart';
import 'package:ws_scrcpy_client/core/control/key_code_control_message.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/keyboard_mapping.dart';

/// 桌面端用物理键盘操作设备，映射错了会乱按键——这里钉住常用键。
void main() {
  // metaState 那条要读 HardwareKeyboard.instance，需要先初始化绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('字母键映射到 Android 连续 keycode（A=29 … Z=54）', () {
    expect(
      KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.keyA),
      AndroidKeyCode.letterA,
    );
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.keyZ), 54);
    // M 是第 13 个字母 → 29 + 12 = 41。
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.keyM), 41);
  });

  test('数字键映射（0=7，5=12，9=16）', () {
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.digit0), 7);
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.digit5), 12);
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.digit9), 16);
  });

  test('常用功能键', () {
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.enter), 66);
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.escape), 111);
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.backspace), 67);
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.space), 62);
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.tab), 61);
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.arrowUp), 19);
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.arrowDown), 20);
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.arrowLeft), 21);
    expect(
      KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.arrowRight),
      22,
    );
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.f1), 131);
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.f12), 142);
  });

  test('没覆盖的键返回 null（不猜 keycode，避免设备上乱按）', () {
    expect(KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.f13), isNull);
    expect(
      KeyboardMapping.androidKeyCodeFor(LogicalKeyboardKey.audioVolumeUp),
      isNull,
    );
  });

  test('按下/重复都是 down，抬起是 up', () {
    expect(
      KeyboardMapping.actionFor(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration.zero,
        ),
      ),
      KeyCodeAction.down,
    );
    expect(
      KeyboardMapping.actionFor(
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration.zero,
        ),
      ),
      KeyCodeAction.down,
    );
    expect(
      KeyboardMapping.actionFor(
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration.zero,
        ),
      ),
      KeyCodeAction.up,
    );
  });

  test('没有按修饰键时 metaState 为 0', () {
    expect(KeyboardMapping.metaStateFrom(HardwareKeyboard.instance), 0);
  });
}
