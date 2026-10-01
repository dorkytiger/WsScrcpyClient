import 'package:flutter/services.dart';
import 'package:ws_scrcpy_client/core/control/android_key_code.dart';
import 'package:ws_scrcpy_client/core/control/key_code_control_message.dart';

/// Flutter 键盘 → Android keycode 的映射表。
///
/// 只覆盖"桌面/物理键盘上真的会按"的那部分键；没覆盖到的键返回 null（调用方忽略，
/// 不猜一个 keycode 发过去，那样设备上会乱按键）。
/// 取值全部来自 [AndroidKeyCode]（实测自服务端 bundle）。
class KeyboardMapping {
  const KeyboardMapping._();

  /// 字母 a-z：Android 里字母键位连续（A=29 … Z=54），与 ASCII 大写相差 36。
  static final Map<LogicalKeyboardKey, int> _letters =
      <LogicalKeyboardKey, int>{
        for (
          int offset = 0;
          offset <= AndroidKeyCode.letterZ - AndroidKeyCode.letterA;
          offset++
        )
          LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + offset):
              AndroidKeyCode.letterA + offset,
      };

  /// 数字 0-9：0=7，1..9=8..16。
  static final Map<LogicalKeyboardKey, int> _digits = <LogicalKeyboardKey, int>{
    for (int offset = 0; offset <= 9; offset++)
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + offset): offset == 0
          ? AndroidKeyCode.digit0
          : AndroidKeyCode.digit0 + 1 + offset - 1,
  };

  static final Map<LogicalKeyboardKey, int> _special =
      <LogicalKeyboardKey, int>{
        LogicalKeyboardKey.enter: AndroidKeyCode.enter,
        LogicalKeyboardKey.numpadEnter: AndroidKeyCode.enter,
        LogicalKeyboardKey.escape: AndroidKeyCode.escape,
        LogicalKeyboardKey.backspace: AndroidKeyCode.del,
        LogicalKeyboardKey.delete: AndroidKeyCode.forwardDel,
        LogicalKeyboardKey.tab: AndroidKeyCode.tab,
        LogicalKeyboardKey.space: AndroidKeyCode.space,
        LogicalKeyboardKey.arrowUp: AndroidKeyCode.dpadUp,
        LogicalKeyboardKey.arrowDown: AndroidKeyCode.dpadDown,
        LogicalKeyboardKey.arrowLeft: AndroidKeyCode.dpadLeft,
        LogicalKeyboardKey.arrowRight: AndroidKeyCode.dpadRight,
        LogicalKeyboardKey.select: AndroidKeyCode.dpadCenter,
        LogicalKeyboardKey.home: AndroidKeyCode.moveHome,
        LogicalKeyboardKey.end: AndroidKeyCode.moveEnd,
        LogicalKeyboardKey.pageUp: AndroidKeyCode.pageUp,
        LogicalKeyboardKey.pageDown: AndroidKeyCode.pageDown,
        // F1..F12 在 Android 里也是连续的（131..142）。
        for (
          int offset = 0;
          offset <= AndroidKeyCode.f12 - AndroidKeyCode.f1;
          offset++
        )
          LogicalKeyboardKey(LogicalKeyboardKey.f1.keyId + offset):
              AndroidKeyCode.f1 + offset,
      };

  /// Flutter 逻辑键 → Android keycode；未覆盖返回 null。
  static int? androidKeyCodeFor(LogicalKeyboardKey key) =>
      _letters[key] ?? _digits[key] ?? _special[key];

  /// 由当前按下的修饰键合成 scrcpy 的 `metaState`（位掩码，见 [KeyCodeMetaState]）。
  static int metaStateFrom(HardwareKeyboard keyboard) {
    var metaState = 0;
    if (keyboard.isLogicalKeyPressed(LogicalKeyboardKey.shiftLeft) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.shiftRight) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.shift)) {
      metaState |= KeyCodeMetaState.shiftOn;
    }
    if (keyboard.isLogicalKeyPressed(LogicalKeyboardKey.controlLeft) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.controlRight) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.control)) {
      metaState |= KeyCodeMetaState.ctrlOn;
    }
    if (keyboard.isLogicalKeyPressed(LogicalKeyboardKey.altLeft) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.altRight) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.alt)) {
      metaState |= KeyCodeMetaState.altOn;
    }
    if (keyboard.isLogicalKeyPressed(LogicalKeyboardKey.metaLeft) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.metaRight) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.meta)) {
      metaState |= KeyCodeMetaState.metaOn;
    }
    return metaState;
  }

  /// Flutter 按键事件 → scrcpy 按键动作；不支持的事件返回 null。
  static KeyCodeAction? actionFor(KeyEvent event) => switch (event) {
    KeyDownEvent() || KeyRepeatEvent() => KeyCodeAction.down,
    KeyUpEvent() => KeyCodeAction.up,
    _ => null,
  };
}
