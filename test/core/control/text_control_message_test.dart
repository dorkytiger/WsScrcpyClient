import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/control/text_control_message.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

import 'control_message_test_support.dart';

/// 文本消息的期望字节——对照 bundle 模块 5600 的写序列：
///
/// ```js
/// writeUInt8(type) writeUInt32BE(length) write(text)
/// ```
///
/// `length` 必须写**utf8 字节数**：bundle 写的是 JavaScript 的
/// `text.length`（UTF-16 码元数），非 ASCII 文本会少算，属于 bundle 的缺陷；
/// scrcpy-server 按字节数读取，且 bundle 的剪贴板命令用的也是字节数。
void main() {
  group('TextControlMessage 字节布局', () {
    test('ASCII：type=1 / length=5 / "Hello"', () {
      final message = TextControlMessage('Hello');

      final bytes = message.toBuffer();

      expectBytes(
        bytes,
        hexBytes(
          '01 ' // 0     type = TYPE_TEXT
          '00 00 00 05 ' // 1..4  length = 5 字节
          '48 65 6C 6C 6F', // 5..9  "Hello"
        ),
      );
      expect(message.type, ControlMessageType.text);
      expect(bytes, hasLength(message.bufferLength));
    });

    test('中文：length 写 utf8 字节数（6），而不是 JS 字符数（2）', () {
      final message = TextControlMessage('你好');

      expect(message.text.length, 2, reason: 'Dart/JS 的字符数');
      expect(message.utf8ByteLength, 6, reason: 'utf8 字节数');
      expectBytes(
        message.toBuffer(),
        hexBytes(
          '01 '
          '00 00 00 06 ' // 6 字节，不是 2
          'E4 BD A0 ' // 你 U+4F60
          'E5 A5 BD', // 好 U+597D
        ),
      );
    });

    test('中文标点混排："你好，世界" = 15 字节', () {
      final message = TextControlMessage('你好，世界');

      expect(message.utf8ByteLength, 15);
      expectBytes(
        message.toBuffer(),
        hexBytes(
          '01 '
          '00 00 00 0F '
          'E4 BD A0 ' // 你
          'E5 A5 BD ' // 好
          'EF BC 8C ' // ，U+FF0C
          'E4 B8 96 ' // 世
          'E7 95 8C', // 界
        ),
      );
    });

    test('长度字段按大端写入，可被 ByteData 还原', () {
      final bytes = TextControlMessage('你好').toBuffer();
      final view = ByteData.sublistView(bytes);
      expect(view.getUint32(TextControlMessage.lengthOffset, Endian.big), 6);
      expect(bytes.sublist(1, 5), [0x00, 0x00, 0x00, 0x06]);
    });

    test('编码结果与 utf8.encode 完全一致（不自行转码）', () {
      const text = 'a你b🙂';
      final bytes = TextControlMessage(text).toBuffer();
      final expectedBytes = utf8.encode(text);
      expectBytes(bytes.sublist(TextControlMessage.textOffset), expectedBytes);
      expect(
        ByteData.sublistView(bytes)
            .getUint32(TextControlMessage.lengthOffset, Endian.big),
        expectedBytes.length,
      );
    });
  });

  group('TextControlMessage 入参校验', () {
    test('空文本抛 ValidationException', () {
      expect(() => TextControlMessage(''), throwsA(isA<ValidationException>()));
    });
  });
}
