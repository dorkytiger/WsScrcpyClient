import 'dart:convert';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/control/control_message.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

/// 文本注入消息（bundle 的 `TextControlMessage`）。
///
/// **实测字节布局**（模块 5600，
/// `Buffer.alloc(text.length + 1 + TEXT_SIZE_FIELD_LENGTH)`，
/// `TEXT_SIZE_FIELD_LENGTH = 4`；全部**大端**）：
///
/// ```text
/// offset  size    field
/// 0       1       type   = 1 (TYPE_TEXT)
/// 1       4       length 文本字节数（uint32，大端）
/// 5       length  文本本体（utf8）
/// ```
///
/// **与 bundle 的一处有意分歧（按 utf8 字节数而非 JS 字符数）**：
/// bundle 写的是 `this.text.length`，那是 JavaScript 的**UTF-16 码元个数**，
/// 对非 ASCII 文本会小于实际写入的 utf8 字节数（`Buffer.write` 默认 utf8），
/// 于是声明长度与实体长度不一致。同 bundle 的
/// `CommandControlMessage.createSetClipboardCommand` 用的是
/// `stringToUtf8ByteArray(text).length`（真正的字节数），
/// 且 scrcpy-server 侧按**字节数**读取本字段——两处证据都指向"字节数才是正确语义"。
/// 因此这里以字节数编码，保证中文等非 ASCII 文本不会被设备截断。
class TextControlMessage extends ControlMessage {
  TextControlMessage(this.text) : super(ControlMessageType.text) {
    if (text.isEmpty) {
      throw const ValidationException(message: '文本不能为空：空文本无法表达注入内容');
    }
    if (utf8ByteLength > ControlMessage.maxUint32Value) {
      throw ValidationException(
        message: '文本过长：$utf8ByteLength 字节，上限 ${ControlMessage.maxUint32Value}',
      );
    }
  }

  /// bundle 里的 `TEXT_SIZE_FIELD_LENGTH`：长度字段固定 4 字节。
  static const int textSizeFieldLength = ControlMessage.uint32FieldLength;

  /// `length` 字段偏移（紧跟在 `type` 之后）。
  static const int lengthOffset = ControlMessage.typeFieldLength;

  /// 文本本体偏移。
  static const int textOffset = lengthOffset + textSizeFieldLength;

  /// 待注入的文本。
  final String text;

  /// utf8 编码后的字节数。
  ///
  /// 单独暴露是为了让上层（日志面板/长度诊断）看到真正会被写进 `length` 字段的值，
  /// 而不是 JavaScript 语义下的字符数。
  int get utf8ByteLength => utf8.encode(text).length;

  /// 完整消息长度 = type(1) + length(4) + 文本字节数。
  int get bufferLength => textOffset + utf8ByteLength;

  @override
  Uint8List toBuffer() {
    final textBytes = utf8.encode(text);
    final buffer = Uint8List(textOffset + textBytes.length);
    final header = ByteData.sublistView(buffer);
    header.setUint8(0, type.code);
    header.setUint32(lengthOffset, textBytes.length, Endian.big);
    buffer.setRange(textOffset, buffer.length, textBytes);
    return buffer;
  }

  @override
  String toString() =>
      'TextControlMessage(text: $text, bytes: $utf8ByteLength)';
}
