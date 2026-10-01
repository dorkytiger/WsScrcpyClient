import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/control/control_message.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';

/// 按键动作，对应 bundle 里 `AndroidMotionEvent` 的
/// `ACTION_DOWN = 0` / `ACTION_UP = 1`（`.probe/bundle.js` webpack 模块 4504）。
///
/// 实测用例：`GoogToolBox` 里快捷栏是
/// `new KeyCodeControlMessage(action, code, 0, 0)`，action 取 ACTION_DOWN/ACTION_UP。
///
/// 不复用 TouchAction：触摸有第三态 `move`，按键没有，共用会让
/// `KeyCodeControlMessage(action: TouchAction.move)` 这种非法组合通过类型检查。
enum KeyCodeAction {
  /// 按下。
  down(0, '按下'),

  /// 抬起。
  up(1, '抬起');

  const KeyCodeAction(this.code, this.description);

  /// 线上 action 字段取值。
  final int code;

  /// 中文说明（日志与调试面板用）。
  final String description;

  /// 线上取值 → 枚举的唯一解析入口；未知取值返回 `null`。
  static KeyCodeAction? fromCode(int code) {
    for (final value in KeyCodeAction.values) {
      if (value.code == code) {
        return value;
      }
    }
    return null;
  }
}

/// Android `KeyEvent` 的 metaState 修饰键位掩码。
///
/// 取值**实测自** `.probe/bundle.js` 的 `AndroidKeyCode` 表
/// （`e.META_SHIFT_ON=1, e.META_ALT_ON=2, e.META_SYM_ON=4, e.META_FUNCTION_ON=8,`
/// `e.META_ALT_LEFT_ON=16, e.META_ALT_RIGHT_ON=32, e.META_SHIFT_LEFT_ON=64,`
/// `e.META_SHIFT_RIGHT_ON=128, e.META_CTRL_ON=4096, e.META_CTRL_LEFT_ON=8192,`
/// `e.META_CTRL_RIGHT_ON=16384, e.META_META_ON=65536, e.META_META_LEFT_ON=131072,`
/// `e.META_META_RIGHT_ON=262144, e.META_CAPS_LOCK_ON=1048576,`
/// `e.META_NUM_LOCK_ON=2097152, e.META_SCROLL_LOCK_ON=4194304`）。
///
/// 网页端 `KeyInputHandler` 就是把它们按位或后作为 `metaState` 发出去，
/// 客户端做桌面键盘映射时需要同样的组合语义。
class KeyCodeMetaState {
  const KeyCodeMetaState._();

  /// Shift 按下。
  static const int shiftOn = 1;

  /// Alt 按下。
  static const int altOn = 2;

  /// Sym 按下。
  static const int symOn = 4;

  /// Fn 按下。
  static const int functionOn = 8;

  /// 左侧 Alt 按下。
  static const int altLeftOn = 16;

  /// 右侧 Alt 按下。
  static const int altRightOn = 32;

  /// 左侧 Shift 按下。
  static const int shiftLeftOn = 64;

  /// 右侧 Shift 按下。
  static const int shiftRightOn = 128;

  /// Ctrl 按下。
  static const int ctrlOn = 4096;

  /// 左侧 Ctrl 按下。
  static const int ctrlLeftOn = 8192;

  /// 右侧 Ctrl 按下。
  static const int ctrlRightOn = 16384;

  /// Meta（Windows/Cmd）按下。
  static const int metaOn = 65536;

  /// 左侧 Meta 按下。
  static const int metaLeftOn = 131072;

  /// 右侧 Meta 按下。
  static const int metaRightOn = 262144;

  /// Caps Lock 生效。
  static const int capsLockOn = 1048576;

  /// Num Lock 生效。
  static const int numLockOn = 2097152;

  /// Scroll Lock 生效。
  static const int scrollLockOn = 4194304;
}

/// 按键注入消息（bundle 的 `KeyCodeControlMessage`）。
///
/// **实测字节布局**（模块 3125，`Buffer.alloc(PAYLOAD_LENGTH + 1)`，
/// `PAYLOAD_LENGTH = 13`，写序列见其 `toBuffer()`；全部**大端**）：
///
/// ```text
/// offset  size  field
/// 0       1     type      = 0 (TYPE_KEYCODE)
/// 1       1     action    0=down 1=up
/// 2       4     keycode   Android keycode
/// 6       4     repeat    重复次数（keydown 且浏览器 repeat 时计数，首按为 0）
/// 10      4     metaState 修饰键位掩码，见 [KeyCodeMetaState]
/// ```
///
/// 合计 14 字节，与 bundle 的 `PAYLOAD_LENGTH + 1` 完全一致（无零填充）。
class KeyCodeControlMessage extends ControlMessage {
  KeyCodeControlMessage({
    required this.action,
    required this.keycode,
    this.repeat = 0,
    this.metaState = 0,
  }) : super(ControlMessageType.keycode) {
    ControlMessage.validateIntField(
      fieldName: 'keycode',
      value: keycode,
      maxValue: ControlMessage.maxInt32Value,
    );
    ControlMessage.validateIntField(
      fieldName: 'repeat',
      value: repeat,
      maxValue: ControlMessage.maxInt32Value,
    );
    ControlMessage.validateIntField(
      fieldName: 'metaState',
      value: metaState,
      maxValue: ControlMessage.maxInt32Value,
    );
  }

  /// bundle 里的 `PAYLOAD_LENGTH`（不含 `type` 字段 1 字节）。
  static const int payloadLength = 13;

  /// 完整消息长度 = type(1) + payload(13) = 14。
  static const int bufferLength =
      ControlMessage.typeFieldLength + payloadLength;

  /// `action` 字段偏移。
  static const int actionOffset = ControlMessage.typeFieldLength;

  /// `keycode` 字段偏移。
  static const int keycodeOffset =
      actionOffset + ControlMessage.uint8FieldLength;

  /// `repeat` 字段偏移。
  static const int repeatOffset =
      keycodeOffset + ControlMessage.uint32FieldLength;

  /// `metaState` 字段偏移。
  static const int metaStateOffset =
      repeatOffset + ControlMessage.uint32FieldLength;

  final KeyCodeAction action;

  /// Android keycode，取值见 `AndroidKeyCode`（lib/core/control/android_key_code.dart）。
  final int keycode;

  /// 重复次数：0 表示首次按下（bundle 在非 repeat 时传 0）。
  final int repeat;

  /// 修饰键位掩码，见 [KeyCodeMetaState]。
  final int metaState;

  @override
  Uint8List toBuffer() {
    final data = ByteData(bufferLength);
    data.setUint8(0, type.code);
    data.setUint8(actionOffset, action.code);
    // 三个字段在 bundle 里都是 writeInt32BE；取值均为正，用无符号写入等价。
    data.setUint32(keycodeOffset, keycode, Endian.big);
    data.setUint32(repeatOffset, repeat, Endian.big);
    data.setUint32(metaStateOffset, metaState, Endian.big);
    return data.buffer.asUint8List();
  }

  @override
  String toString() =>
      'KeyCodeControlMessage(action: $action, keycode: $keycode, '
      'repeat: $repeat, metaState: $metaState)';
}
