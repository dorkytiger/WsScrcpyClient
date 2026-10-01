import 'dart:convert';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/ws/multiplexer_message_type.dart';

/// 通道关闭事件（对应 `MessageType.closeChannel` 的 payload）。
///
/// 字节布局（小端）：`[code:uint16][reasonLength:uint32][reason:utf8]`，
/// 其中 reason 长度字段位于偏移 2，reason 本体从偏移 6 开始。
class ChannelCloseEvent {
  const ChannelCloseEvent({required this.code, this.reason});

  /// WebSocket 关闭码，1000 表示正常关闭。
  final int code;

  final String? reason;

  bool get wasClean => code == 1000;

  @override
  String toString() => 'ChannelCloseEvent(code: $code, reason: $reason)';
}

/// 复用层帧：`[type:uint8][channelId:uint32 LE][payload:...]`。
///
/// 重要实测结论：**一个 WebSocket 消息就是恰好一个复用帧**，
/// 帧头里没有长度字段（长度 = 消息长度 - 5）。因此不存在跨消息的粘包/半包问题，
/// 只需要处理"消息短于 5 字节"的截断非法帧。
class MultiplexerMessage {
  const MultiplexerMessage({
    required this.type,
    required this.channelId,
    required this.payload,
  });

  /// 帧头固定长度：type(1) + channelId(4)。
  static const int headerLength = 5;

  /// 关闭事件里 code 的字节长度。
  static const int closeEventCodeLength = 2;

  /// 关闭事件里 reason 长度字段的偏移。
  static const int closeEventReasonLengthOffset = 2;

  /// 关闭事件里 reason 本体的偏移。
  static const int closeEventReasonOffset = 6;

  final MessageType type;

  /// 逻辑通道 id，采用**小端** uint32。
  final int channelId;

  final Uint8List payload;

  /// 从一条完整的 WebSocket 消息解析复用帧。
  ///
  /// 长度不足或类型未知时返回 [ParsingException]。
  static MultiplexerMessage decode(Uint8List message) {
    if (message.length < headerLength) {
      throw ParsingException(
        message: '复用帧长度不足：收到 ${message.length} 字节，至少需要 $headerLength 字节',
      );
    }
    final header = ByteData.sublistView(message);
    final type = MessageType.fromCode(header.getUint8(0));
    if (type == MessageType.unknown) {
      throw ParsingException(message: '不支持的复用帧类型：${header.getUint8(0)}');
    }
    return MultiplexerMessage(
      type: type,
      channelId: header.getUint32(1, Endian.little),
      payload: Uint8List.sublistView(message, headerLength),
    );
  }

  /// 编码为一条完整 WebSocket 消息。
  Uint8List encode() =>
      encodeFrame(type: type, channelId: channelId, payload: payload);

  /// 按复用层格式编码一帧。
  static Uint8List encodeFrame({
    required MessageType type,
    required int channelId,
    Uint8List? payload,
  }) {
    final payloadLength = payload?.length ?? 0;
    final buffer = Uint8List(headerLength + payloadLength);
    final header = ByteData.sublistView(buffer);
    header.setUint8(0, type.code);
    header.setUint32(1, channelId, Endian.little);
    if (payloadLength > 0) {
      buffer.setRange(headerLength, headerLength + payloadLength, payload!);
    }
    return buffer;
  }

  /// 解析 [MessageType.closeChannel] 的 payload。
  ChannelCloseEvent decodeCloseEvent() {
    if (payload.length < closeEventCodeLength) {
      throw ParsingException(message: '关闭事件长度不足：收到 ${payload.length} 字节');
    }
    final view = ByteData.sublistView(payload);
    final code = view.getUint16(0, Endian.little);
    String? reason;
    if (payload.length > closeEventReasonOffset) {
      final reasonLength = view.getUint32(
        closeEventReasonLengthOffset,
        Endian.little,
      );
      final end = closeEventReasonOffset + reasonLength;
      if (end <= payload.length) {
        reason = utf8.decode(
          Uint8List.sublistView(payload, closeEventReasonOffset, end),
          allowMalformed: true,
        );
      }
    }
    return ChannelCloseEvent(code: code, reason: reason);
  }
}
