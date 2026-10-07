import 'dart:async';
import 'dart:typed_data';

/// WebSocket 传输抽象：复用层只依赖这个接口，便于用假实现在单元测试里验证协议。
///
/// **本文件是纯 Dart**（不 import `dart:io`，也不 import Flutter）：
/// 它在 web 上要能原样编。具体实现按平台分派，见 `web_socket_transport_connect.dart`。
abstract interface class WebSocketTransport {
  /// 收到的原始消息：`String`（文本帧）或 [Uint8List]（二进制帧）。
  Stream<Object> get messages;

  bool get isOpen;

  void sendBinary(Uint8List data);

  Future<void> close([int code = 1000, String? reason]);
}
