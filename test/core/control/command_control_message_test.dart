import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/control/command_control_message.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

import 'control_message_test_support.dart';

/// 命令消息的期望字节——对照 bundle 模块 5994：
///
/// * 无负载命令：`Buffer.alloc(PAYLOAD_LENGTH + 1)` 只写 `type`；
/// * `createSetScreenPowerModeCommand`：`alloc(2)`，第 2 字节 `on?1:0`；
/// * `createSetClipboardCommand`：`alloc(6 + 文本字节数)`，
///   `type / paste / length(4) / 文本`。
void main() {
  group('CommandType 取值（实测自 bundle 的 Commands 表）', () {
    test('七个 Commands 表条目', () {
      expect(CommandType.expandNotificationPanel.code, 5);
      expect(CommandType.expandSettingsPanel.code, 6);
      expect(CommandType.collapsePanels.code, 7);
      expect(CommandType.getClipboard.code, 8);
      expect(CommandType.setClipboard.code, 9);
      expect(CommandType.rotateDevice.code, 11);
      expect(CommandType.changeStreamParameters.code, 101);
    });

    test('屏幕开关（不在 Commands 表里，来自 createSetScreenPowerModeCommand）', () {
      expect(CommandType.setScreenPowerMode.code, 10);
    });

    test('code 与 ControlMessageType 同源，且与基类字段一致', () {
      for (final command in CommandType.values) {
        expect(command.type.code, command.code);
        expect(ControlMessageType.fromCode(command.code), command.type);
      }
    });

    test('requiresPayload 标出必须带负载的命令', () {
      expect(CommandType.setClipboard.requiresPayload, isTrue);
      expect(CommandType.setScreenPowerMode.requiresPayload, isTrue);
      expect(CommandType.changeStreamParameters.requiresPayload, isTrue);
      expect(CommandType.collapsePanels.requiresPayload, isFalse);
      expect(CommandType.getClipboard.requiresPayload, isFalse);
      expect(CommandType.rotateDevice.requiresPayload, isFalse);
      expect(CommandType.expandNotificationPanel.requiresPayload, isFalse);
      expect(CommandType.expandSettingsPanel.requiresPayload, isFalse);
    });
  });

  group('CommandControlMessage 字节布局', () {
    test('无负载命令只写 1 字节 type', () {
      expectBytes(
        CommandControlMessage(CommandType.expandNotificationPanel).toBuffer(),
        hexBytes('05'),
      );
      expectBytes(
        CommandControlMessage(CommandType.expandSettingsPanel).toBuffer(),
        hexBytes('06'),
      );
      expectBytes(
        CommandControlMessage(CommandType.collapsePanels).toBuffer(),
        hexBytes('07'),
      );
      expectBytes(
        CommandControlMessage(CommandType.getClipboard).toBuffer(),
        hexBytes('08'),
      );
      expectBytes(
        CommandControlMessage(CommandType.rotateDevice).toBuffer(),
        hexBytes('0B'),
      );
    });

    test('开关屏幕：type=10 + 1 字节模式（1=开 / 0=关）', () {
      final on = CommandControlMessage.setScreenPowerMode(screenOn: true);
      final off = CommandControlMessage.setScreenPowerMode(screenOn: false);

      expectBytes(on.toBuffer(), hexBytes('0A 01'));
      expectBytes(off.toBuffer(), hexBytes('0A 00'));
      expect(on.type, ControlMessageType.setScreenPowerMode);
      expect(
        on.toBuffer()[CommandControlMessage.screenPowerModeFieldOffset],
        CommandControlMessage.screenOnModeValue,
      );
    });

    test('写剪贴板（不粘贴）：type=9 / paste=0 / length / utf8 文本', () {
      final message = CommandControlMessage.setClipboard(
        text: 'hi',
        paste: false,
      );

      expectBytes(
        message.toBuffer(),
        hexBytes(
          '09 ' // 0     type = TYPE_SET_CLIPBOARD
          '00 ' // 1     paste = 0
          '00 00 00 02 ' // 2..5  length = 2 字节
          '68 69', // 6..7  "hi"
        ),
      );
      expect(message.type, ControlMessageType.setClipboard);
    });

    test('写剪贴板（直接粘贴）：paste 字节为 1', () {
      expectBytes(
        CommandControlMessage.setClipboard(text: 'hi', paste: true).toBuffer(),
        hexBytes('09 01 00 00 00 02 68 69'),
      );
    });

    test('写剪贴板（无文本）：length 写 0，没有文本字节', () {
      expectBytes(
        CommandControlMessage.setClipboard(paste: true).toBuffer(),
        hexBytes('09 01 00 00 00 00'),
      );
      expectBytes(
        CommandControlMessage.setClipboard(text: '').toBuffer(),
        hexBytes('09 00 00 00 00 00'),
      );
    });

    test('写剪贴板（中文）：length 用 utf8 字节数 6', () {
      expectBytes(
        CommandControlMessage.setClipboard(text: '你好').toBuffer(),
        hexBytes(
          '09 '
          '00 '
          '00 00 00 06 '
          'E4 BD A0 E5 A5 BD',
        ),
      );
    });

    test('动态改视频参数：type=101 后原样拼接调用方负载', () {
      final message = CommandControlMessage.changeStreamParameters(
        Uint8List.fromList([0xAA, 0xBB, 0xCC]),
      );

      expectBytes(message.toBuffer(), hexBytes('65 AA BB CC'));
      expect(message.payloadLength, 3);
      expect(message.type, ControlMessageType.changeStreamParameters);
    });

    test('偏移常量与整条消息的字节位置一致', () {
      expect(CommandControlMessage.pasteFlagFieldOffset, 1);
      expect(CommandControlMessage.clipboardLengthFieldOffset, 2);
      expect(CommandControlMessage.clipboardTextFieldOffset, 6);
      expect(CommandControlMessage.screenPowerModeFieldOffset, 1);

      final bytes = CommandControlMessage.setClipboard(text: '你好').toBuffer();
      expect(
        ByteData.sublistView(bytes).getUint32(
          CommandControlMessage.clipboardLengthFieldOffset,
          Endian.big,
        ),
        6,
      );
      expect(bytes.sublist(CommandControlMessage.clipboardTextFieldOffset), [
        0xE4,
        0xBD,
        0xA0,
        0xE5,
        0xA5,
        0xBD,
      ]);
    });
  });

  group('CommandControlMessage 入参校验', () {
    test('用无负载构造器传带负载命令抛 ValidationException', () {
      expect(
        () => CommandControlMessage(CommandType.setClipboard),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => CommandControlMessage(CommandType.setScreenPowerMode),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => CommandControlMessage(CommandType.changeStreamParameters),
        throwsA(isA<ValidationException>()),
      );
    });

    test('空视频参数抛 ValidationException', () {
      expect(
        () => CommandControlMessage.changeStreamParameters(Uint8List(0)),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
