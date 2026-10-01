import 'dart:convert';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/control/control_message.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

/// 无类型参数的命令集合，对应 bundle 里 `ControlMessage.Commands` 表
/// （模块 5994 的 `CommandControlMessage.Commands`，实测原文）：
///
/// ```js
/// t.Commands=new Map([
///   [TYPE_EXPAND_NOTIFICATION_PANEL,"Expand notifications"],
///   [TYPE_EXPAND_SETTINGS_PANEL,"Expand settings"],
///   [TYPE_COLLAPSE_PANELS,"Collapse panels"],
///   [TYPE_GET_CLIPBOARD,"Get clipboard"],
///   [TYPE_SET_CLIPBOARD,"Set clipboard"],
///   [TYPE_ROTATE_DEVICE,"Rotate device"],
///   [TYPE_CHANGE_STREAM_PARAMETERS,"Change video settings"]
/// ])
/// ```
///
/// `setScreenPowerMode`（`TYPE_SET_SCREEN_POWER_MODE = 10`）**不在**这张表里，
/// 因为它需要 1 字节负载：实测自同模块的 `createSetScreenPowerModeCommand(on)`
/// （`Buffer.alloc(2)`，第 2 字节写 `on?1:0`），调用点在网页端的屏幕开关复选框
/// （`k.checked` → 1=开、0=关）。
enum CommandType {
  /// 展开通知面板（`TYPE_EXPAND_NOTIFICATION_PANEL = 5`）。
  expandNotificationPanel(
    ControlMessageType.expandNotificationPanel,
    'Expand notifications',
    '展开通知面板',
  ),

  /// 展开快捷设置面板（`TYPE_EXPAND_SETTINGS_PANEL = 6`）。
  expandSettingsPanel(
    ControlMessageType.expandSettingsPanel,
    'Expand settings',
    '展开设置面板',
  ),

  /// 收起所有面板（`TYPE_COLLAPSE_PANELS = 7`）。
  collapsePanels(ControlMessageType.collapsePanels, 'Collapse panels', '收起面板'),

  /// 索取设备剪贴板（`TYPE_GET_CLIPBOARD = 8`），设备会以文本消息回发内容。
  getClipboard(ControlMessageType.getClipboard, 'Get clipboard', '获取设备剪贴板'),

  /// 写入设备剪贴板（`TYPE_SET_CLIPBOARD = 9`），需 paste 标志 + 文本负载。
  setClipboard(ControlMessageType.setClipboard, 'Set clipboard', '同步剪贴板到设备'),

  /// 开关设备屏幕（`TYPE_SET_SCREEN_POWER_MODE = 10`），需 1 字节模式负载。
  setScreenPowerMode(
    ControlMessageType.setScreenPowerMode,
    'Set screen power mode',
    '开关设备屏幕',
  ),

  /// 旋转设备（`TYPE_ROTATE_DEVICE = 11`）。
  rotateDevice(ControlMessageType.rotateDevice, 'Rotate device', '旋转设备'),

  /// 动态修改视频参数（`TYPE_CHANGE_STREAM_PARAMETERS = 101`），负载为视频参数结构。
  changeStreamParameters(
    ControlMessageType.changeStreamParameters,
    'Change video settings',
    '动态修改视频参数',
  );

  const CommandType(this.type, this.label, this.description);

  /// 对应的线上消息类型，也是 `type` 字节取值的**单一事实来源**。
  final ControlMessageType type;

  /// bundle 里给该命令的原文名称；保留英文便于与服务端/网页端日志逐条对照。
  final String label;

  /// 中文说明（UI 与日志用）。
  final String description;

  /// 线上 `type` 字段取值，等价于 `type.code`。
  int get code => type.code;

  /// 该命令是否必须附带负载；无负载命令才能用 [CommandControlMessage.new] 直接构造。
  bool get requiresPayload => switch (this) {
    CommandType.setClipboard => true,
    CommandType.setScreenPowerMode => true,
    CommandType.changeStreamParameters => true,
    _ => false,
  };
}

/// 命令消息（bundle 的 `CommandControlMessage`）。
///
/// **实测字节布局**（模块 5994，类上 `PAYLOAD_LENGTH = 0`，
/// 其 `toBuffer()` 为 `Buffer.alloc(PAYLOAD_LENGTH + 1)` 后写 `type`；
/// 带负载的命令由各静态工厂自行拼装；多字节字段全部**大端**）：
///
/// ```text
/// 无负载命令（expand notifications/settings、collapse panels、
///            get clipboard、rotate device）：
///   offset  size  field
///   0       1     type
///
/// setScreenPowerMode（createSetScreenPowerModeCommand，alloc(2)）：
///   offset  size  field
///   0       1     type = 10
///   1       1     mode 0=关屏 1=开屏（bundle: on?1:0）
///
/// setClipboard（createSetClipboardCommand，alloc(6 + 文本字节数)）：
///   offset  size      field
///   0       1         type = 9
///   1       1         paste 1=直接粘贴到设备焦点输入框，0=只写剪贴板
///   2       4         length 文本 utf8 字节数
///   6       length    文本本体（utf8）
///
/// changeStreamParameters：type 后紧跟调用方已编码好的视频参数字节，
///                         本层不透解其内部结构（见对应工厂的说明）
/// ```
class CommandControlMessage extends ControlMessage {
  /// 私有主构造：所有工厂都经此，保证 `type` 字段与 [_command] 永远同源。
  CommandControlMessage._(this._command, this._payload) : super(_command.type);

  /// 构造无负载命令（展开/收起面板、取剪贴板、旋转设备）。
  ///
  /// 带负载的命令传进来会抛 [ValidationException]：漏传负载的字节流虽能发出，
  /// 但服务端会按错误长度解析，属于必须尽早拦下的错误。
  factory CommandControlMessage(CommandType command) {
    if (command.requiresPayload) {
      throw ValidationException(
        message: '命令 ${command.label} 需要负载，请用对应的具名构造函数',
      );
    }
    return CommandControlMessage._(command, Uint8List(0));
  }

  /// 构造开关屏幕命令，负载 1 字节：1=开（NORMAL），0=关（OFF）。
  factory CommandControlMessage.setScreenPowerMode({required bool screenOn}) {
    final payload = Uint8List(ControlMessage.uint8FieldLength);
    payload[screenPowerModePayloadOffset] = screenOn
        ? screenOnModeValue
        : screenOffModeValue;
    return CommandControlMessage._(CommandType.setScreenPowerMode, payload);
  }

  /// 构造写剪贴板命令。
  ///
  /// [text] 为 `null` 或空串时长度字段写 0（与 bundle 的 `e ? ... : null` 一致）；
  /// [paste] 为 true 表示设备端直接粘贴到焦点输入框（bundle 默认 false）。
  factory CommandControlMessage.setClipboard({
    String? text,
    bool paste = false,
  }) {
    final textBytes = (text == null || text.isEmpty)
        ? const <int>[]
        : utf8.encode(text);
    if (textBytes.length > ControlMessage.maxUint32Value) {
      throw ValidationException(
        message:
            '剪贴板文本过长：${textBytes.length} 字节，上限 ${ControlMessage.maxUint32Value}',
      );
    }
    final payload = Uint8List(clipboardTextPayloadOffset + textBytes.length);
    final header = ByteData.sublistView(payload);
    header.setUint8(pasteFlagPayloadOffset, paste ? 1 : 0);
    header.setUint32(
      clipboardLengthPayloadOffset,
      textBytes.length,
      Endian.big,
    );
    payload.setRange(clipboardTextPayloadOffset, payload.length, textBytes);
    return CommandControlMessage._(CommandType.setClipboard, payload);
  }

  /// 构造动态改视频参数命令。
  ///
  /// [parameters] 是调用方（视频设置层）已编码好的结构字节；本层只负责拼 `type` 前缀，
  /// 不透解其内部结构，避免编码层和视频设置模型耦合。
  factory CommandControlMessage.changeStreamParameters(Uint8List parameters) {
    if (parameters.isEmpty) {
      throw const ValidationException(message: '视频参数不能为空');
    }
    return CommandControlMessage._(
      CommandType.changeStreamParameters,
      Uint8List.fromList(parameters),
    );
  }

  /// 开屏模式取值（bundle: `on?1:0`，Android `ScreenPowerMode.NORMAL`）。
  static const int screenOnModeValue = 1;

  /// 关屏模式取值（Android `ScreenPowerMode.OFF`）。
  static const int screenOffModeValue = 0;

  /// `paste` 标志在**负载**中的偏移（相对偏移 1 处即整条消息的 `pasteFlagFieldOffset`）。
  static const int pasteFlagPayloadOffset = 0;

  /// 剪贴板文本长度字段在负载中的偏移。
  static const int clipboardLengthPayloadOffset =
      pasteFlagPayloadOffset + ControlMessage.uint8FieldLength;

  /// 剪贴板文本本体在负载中的偏移（= 拼接前的前缀长度 5）。
  static const int clipboardTextPayloadOffset =
      clipboardLengthPayloadOffset + ControlMessage.uint32FieldLength;

  /// 电源模式字段在负载中的偏移。
  static const int screenPowerModePayloadOffset = 0;

  /// 整条消息中 `paste` 标志的偏移（含 `type`）。
  static const int pasteFlagFieldOffset =
      ControlMessage.typeFieldLength + pasteFlagPayloadOffset;

  /// 整条消息中剪贴板长度字段的偏移。
  static const int clipboardLengthFieldOffset =
      ControlMessage.typeFieldLength + clipboardLengthPayloadOffset;

  /// 整条消息中剪贴板文本本体的偏移。
  static const int clipboardTextFieldOffset =
      ControlMessage.typeFieldLength + clipboardTextPayloadOffset;

  /// 整条消息中电源模式字段的偏移。
  static const int screenPowerModeFieldOffset =
      ControlMessage.typeFieldLength + screenPowerModePayloadOffset;

  final CommandType _command;

  /// 负载（不含 `type` 字段），由各工厂按 bundle 写序列拼好。
  final Uint8List _payload;

  /// 命令语义与原文名称，日志里比裸 type 数字可读得多。
  CommandType get command => _command;

  /// 负载字节数（不含 `type` 字段）。
  int get payloadLength => _payload.length;

  @override
  Uint8List toBuffer() {
    final buffer = Uint8List(ControlMessage.typeFieldLength + _payload.length);
    buffer[0] = type.code;
    buffer.setRange(ControlMessage.typeFieldLength, buffer.length, _payload);
    return buffer;
  }

  @override
  String toString() =>
      'CommandControlMessage(command: ${_command.label}, '
      'length: ${ControlMessage.typeFieldLength + _payload.length})';
}
