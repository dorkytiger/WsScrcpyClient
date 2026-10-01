import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/control/control_message.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

/// 触摸动作，对应 bundle 里 `AndroidMotionEvent` 的动作常量
/// （`.probe/bundle.js` webpack 模块 4504）：
///
/// ```js
/// e.ACTION_DOWN=0, e.ACTION_UP=1, e.ACTION_MOVE=2
/// ```
///
/// 建枚举而不是直接用 int：`TouchAction.up` 与 `KeyCodeAction.up` 语义不同，
/// 用类型区分可避免把按键动作误传给触摸消息。
enum TouchAction {
  /// 手指/鼠标按下。
  down(0, '按下'),

  /// 手指/鼠标抬起。
  up(1, '抬起'),

  /// 手指/鼠标移动。
  move(2, '移动');

  const TouchAction(this.code, this.description);

  /// 线上 action 字段取值。
  final int code;

  /// 中文说明（日志与调试面板用）。
  final String description;

  /// 线上取值 → 枚举的唯一解析入口；未知取值返回 `null`，由调用方记日志处理。
  static TouchAction? fromCode(int code) {
    for (final value in TouchAction.values) {
      if (value.code == code) {
        return value;
      }
    }
    return null;
  }
}

/// 鼠标按键位掩码，语义来自 Android `MotionEvent` 的
/// `AMOTION_EVENT_BUTTON_*`（与浏览器 `MouseEvent.buttons` 位布局一致）。
///
/// 实测依据（`.probe/bundle.js` webpack 模块 4504 的 `AndroidMotionEvent` 类）里
/// **只有前三个**：
///
/// ```js
/// e.BUTTON_PRIMARY=1, e.BUTTON_SECONDARY=2, e.BUTTON_TERTIARY=4
/// ```
///
/// bundle 中不存在 `BUTTON_BACK` / `BUTTON_FORWARD` 的集中定义（全局搜
/// `BUTTON_BACK`、`BUTTON_FORWARD` 均无命中），其取值 8 / 16 按 scrcpy 官方
/// `app/src/control_msg.h` 的 `AMOTION_EVENT_BUTTON_BACK` /
/// `AMOTION_EVENT_BUTTON_FORWARD` 语义补全，并在此注明依据。
///
/// ws-scrcpy 网页端是直接透传浏览器 `MouseEvent.buttons`，所以这些值只作**位掩码**
/// 使用，可按位或组合。
class AndroidMotionEventButtons {
  const AndroidMotionEventButtons._();

  /// 无按键（按下以外的动作，或纯触摸）。
  static const int none = 0;

  /// 主键（左键）。
  static const int primary = 1;

  /// 次键（右键）。
  static const int secondary = 2;

  /// 第三键（中键/滚轮键）。
  static const int tertiary = 4;

  /// 后退键（依据 scrcpy `AMOTION_EVENT_BUTTON_BACK`，见类注释）。
  static const int back = 8;

  /// 前进键（依据 scrcpy `AMOTION_EVENT_BUTTON_FORWARD`，见类注释）。
  static const int forward = 16;
}

/// 触摸/鼠标注入消息（bundle 的 `TouchControlMessage`）。
///
/// **实测字节布局**（模块 7444，`Buffer.alloc(PAYLOAD_LENGTH + 1)`，
/// `PAYLOAD_LENGTH = 28`，写序列见其 `toBuffer()`；全部**大端**）：
///
/// ```text
/// offset  size  field
/// 0       1     type        = 2 (TYPE_TOUCH)
/// 1       1     action      0=down 1=up 2=move
/// 2       4     pointerId   高 4 字节，bundle 写死 0
/// 6       4     pointerId   低 4 字节
/// 10      4     x           像素
/// 14      4     y           像素
/// 18      2     screenWidth
/// 20      2     screenHeight
/// 22      2     pressure    pressure * MAX_PRESSURE_VALUE(=65535)
/// 24      4     buttons     位掩码
/// 28      1     （零填充）
/// ```
///
/// 关于第 29 字节：bundle 写序列只覆盖偏移 0..27（共 28 字节），
/// 但 `Buffer.alloc` 分配的是 `PAYLOAD_LENGTH + 1 = 29` 字节且**零填充**，
/// 所以线上实际发出的是 29 字节、末字节为 0——与 `FLUTTER_AGENT.md` §2.4
/// "共 29 字节"一致。此处**逐字节复刻**，原因见 [trailingPaddingLength]。
class TouchControlMessage extends ControlMessage {
  TouchControlMessage({
    required this.action,
    required this.pointerId,
    required this.position,
    required this.pressure,
    this.buttons = AndroidMotionEventButtons.none,
  }) : super(ControlMessageType.touch) {
    if (!position.screenSize.isValid) {
      throw ValidationException(
        message:
            '屏幕尺寸非法：${position.screenSize}（宽高需在 1..${ScreenSize.maxValue}）',
      );
    }
    ControlMessage.validateIntField(
      fieldName: 'pointerId',
      value: pointerId,
      maxValue: ControlMessage.maxUint32Value,
    );
    ControlMessage.validateIntField(
      fieldName: 'x',
      value: position.x,
      maxValue: position.screenSize.width,
    );
    ControlMessage.validateIntField(
      fieldName: 'y',
      value: position.y,
      maxValue: position.screenSize.height,
    );
    ControlMessage.validateIntField(
      fieldName: 'buttons',
      value: buttons,
      maxValue: ControlMessage.maxUint32Value,
    );
    if (pressure.isNaN || pressure < 0 || pressure > 1) {
      throw ValidationException(message: 'pressure 必须在 0..1：$pressure');
    }
  }

  /// bundle 里的 `PAYLOAD_LENGTH = 28`（原值保留，便于与 bundle 逐行对照）。
  static const int payloadLength = 28;

  /// 完整消息长度 = `PAYLOAD_LENGTH + 1` = 29（bundle 的
  /// `Buffer.alloc(t.PAYLOAD_LENGTH + 1)`，那个 `+1` 就是 `type` 字段）。
  static const int bufferLength =
      payloadLength + ControlMessage.typeFieldLength;

  /// bundle 的写序列**实际覆盖**的字节数：
  /// `type(1) + action(1) + pointerId(8) + x(4) + y(4) + w(2) + h(2)
  ///  + pressure(2) + buttons(4) = 28`。
  ///
  /// 与 [payloadLength] 数值相同纯属巧合：一个来自 bundle 的常量声明，
  /// 一个来自写序列的实际字节数，两者含义不同，所以分开命名。
  static const int writtenLength = 28;

  /// 零填充字节数 = [bufferLength] - [writtenLength]。
  ///
  /// 之所以仍然保留：ws-scrcpy 是对端权威实现，客户端必须逐字节复刻它实际发出的
  /// 数据（`Buffer.alloc` 零填充），若省掉这一字节，长度与对端预期不符。
  /// **这一点需在 M0 实测复核**。
  static const int trailingPaddingLength = bufferLength - writtenLength;

  /// `action` 字段偏移。
  static const int actionOffset = ControlMessage.typeFieldLength;

  /// `pointerId` 高 4 字节偏移。
  static const int pointerIdHighOffset =
      actionOffset + ControlMessage.uint8FieldLength;

  /// `pointerId` 低 4 字节偏移。
  static const int pointerIdLowOffset =
      pointerIdHighOffset + ControlMessage.uint32FieldLength;

  /// `x` 字段偏移。
  static const int xOffset =
      pointerIdLowOffset + ControlMessage.uint32FieldLength;

  /// `y` 字段偏移。
  static const int yOffset = xOffset + ControlMessage.uint32FieldLength;

  /// `screenWidth` 字段偏移。
  static const int screenWidthOffset =
      yOffset + ControlMessage.uint32FieldLength;

  /// `screenHeight` 字段偏移。
  static const int screenHeightOffset =
      screenWidthOffset + ControlMessage.uint16FieldLength;

  /// `pressure` 字段偏移。
  static const int pressureOffset =
      screenHeightOffset + ControlMessage.uint16FieldLength;

  /// `buttons` 字段偏移。
  static const int buttonsOffset =
      pressureOffset + ControlMessage.uint16FieldLength;

  /// bundle 的 `TouchControlMessage.MAX_PRESSURE_VALUE = 65535`，pressure=1.0 时写入它。
  static const int maxPressureValue = ControlMessage.maxUint16Value;

  /// java long 的**高 4 字节恒为 0**：bundle 里是写死的 `writeUInt32BE(0, ...)`。
  static const int pointerIdHighPartValue = 0;

  final TouchAction action;

  /// 多指触摸的指针 id；单指固定为 0 亦可（这里按调用方传入的值编码）。
  final int pointerId;

  final TouchPosition position;

  /// 归一化压力值，0.0~1.0；编码时乘 [maxPressureValue] 并四舍五入。
  final double pressure;

  /// 鼠标按键位掩码，见 [AndroidMotionEventButtons]。
  final int buttons;

  @override
  Uint8List toBuffer() {
    final data = ByteData(bufferLength);
    data.setUint8(0, type.code);
    data.setUint8(actionOffset, action.code);
    data.setUint32(pointerIdHighOffset, pointerIdHighPartValue, Endian.big);
    data.setUint32(pointerIdLowOffset, pointerId, Endian.big);
    data.setUint32(xOffset, position.x, Endian.big);
    data.setUint32(yOffset, position.y, Endian.big);
    data.setUint16(screenWidthOffset, position.screenSize.width, Endian.big);
    data.setUint16(screenHeightOffset, position.screenSize.height, Endian.big);
    data.setUint16(
      pressureOffset,
      (pressure * maxPressureValue).round(),
      Endian.big,
    );
    data.setUint32(buttonsOffset, buttons, Endian.big);
    // 偏移 28 的零填充由 ByteData 初始化时的全 0 保证，无需显式写入。
    return data.buffer.asUint8List();
  }

  @override
  String toString() =>
      'TouchControlMessage(action: $action, pointerId: $pointerId, '
      'position: $position, pressure: $pressure, buttons: $buttons)';
}
