import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/control/control_message.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

/// 滚轮注入消息（bundle 的 `ScrollControlMessage`）。
///
/// **实测字节布局**（模块 3762，`Buffer.alloc(PAYLOAD_LENGTH + 1)`，
/// `PAYLOAD_LENGTH = 20`，写序列见其 `toBuffer()`；全部**大端**）：
///
/// ```text
/// offset  size  field
/// 0       1     type          = 3 (TYPE_SCROLL)
/// 1       4     x             像素
/// 5       4     y             像素
/// 9       2     screenWidth
/// 11      2     screenHeight
/// 13      4     hScroll       有符号，左正右负（bundle: deltaX>0 → -1，<0 → 1）
/// 17      4     vScroll       有符号，上正下负（bundle: deltaY>0 → -1，<0 → 1）
/// ```
///
/// 合计 21 字节 = `PAYLOAD_LENGTH + 1`，无零填充（与触摸消息不同）。
/// 注意滚动消息**没有 action / pointerId / pressure / buttons** 字段，
/// 只有位置与两个滚动量——照抄 bundle 的写序列，不要按触摸消息的结构套。
class ScrollControlMessage extends ControlMessage {
  ScrollControlMessage({
    required this.position,
    required this.hScroll,
    required this.vScroll,
  }) : super(ControlMessageType.scroll) {
    if (!position.screenSize.isValid) {
      throw ValidationException(
        message:
            '屏幕尺寸非法：${position.screenSize}（宽高需在 1..${ScreenSize.maxValue}）',
      );
    }
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
      fieldName: 'hScroll',
      value: hScroll,
      minValue: ControlMessage.minInt32Value,
      maxValue: ControlMessage.maxInt32Value,
    );
    ControlMessage.validateIntField(
      fieldName: 'vScroll',
      value: vScroll,
      minValue: ControlMessage.minInt32Value,
      maxValue: ControlMessage.maxInt32Value,
    );
  }

  /// bundle 里的 `PAYLOAD_LENGTH`（不含 `type` 字段 1 字节）。
  static const int payloadLength = 20;

  /// 完整消息长度 = type(1) + payload(20) = 21。
  static const int bufferLength =
      ControlMessage.typeFieldLength + payloadLength;

  /// `x` 字段偏移。
  static const int xOffset = ControlMessage.typeFieldLength;

  /// `y` 字段偏移。
  static const int yOffset = xOffset + ControlMessage.uint32FieldLength;

  /// `screenWidth` 字段偏移。
  static const int screenWidthOffset =
      yOffset + ControlMessage.uint32FieldLength;

  /// `screenHeight` 字段偏移。
  static const int screenHeightOffset =
      screenWidthOffset + ControlMessage.uint16FieldLength;

  /// `hScroll` 字段偏移。
  static const int hScrollOffset =
      screenHeightOffset + ControlMessage.uint16FieldLength;

  /// `vScroll` 字段偏移。
  static const int vScrollOffset =
      hScrollOffset + ControlMessage.uint32FieldLength;

  /// 滚动中心位置（滚轮事件发生处的指针坐标）。
  final TouchPosition position;

  /// 水平滚动量：负=向左滚，正=向右滚（bundle 按浏览器 deltaX 符号映射为 ±1/0）。
  final int hScroll;

  /// 垂直滚动量：负=向下滚，正=向上滚（bundle 按浏览器 deltaY 符号映射为 ±1/0）。
  final int vScroll;

  @override
  Uint8List toBuffer() {
    final data = ByteData(bufferLength);
    data.setUint8(0, type.code);
    data.setUint32(xOffset, position.x, Endian.big);
    data.setUint32(yOffset, position.y, Endian.big);
    data.setUint16(screenWidthOffset, position.screenSize.width, Endian.big);
    data.setUint16(screenHeightOffset, position.screenSize.height, Endian.big);
    // 两个滚动量在 bundle 里是 writeInt32BE，允许负值。
    data.setInt32(hScrollOffset, hScroll, Endian.big);
    data.setInt32(vScrollOffset, vScroll, Endian.big);
    return data.buffer.asUint8List();
  }

  @override
  String toString() =>
      'ScrollControlMessage(position: $position, hScroll: $hScroll, '
      'vScroll: $vScroll)';
}
