import 'dart:io';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';

/// 基于 `dart:io` 的实现（Android / iOS / Windows / macOS / Linux + 命令行工具）。
class IoWebSocketTransport implements WebSocketTransport {
  IoWebSocketTransport._(this._socket);

  final WebSocket _socket;

  /// 建立连接。[authorization] 为完整的 `Authorization` 头取值（如 `Basic xxx=`）。
  ///
  /// 关闭 permessage-deflate：视频码流是已压缩数据，再压一层只会增加延迟与 CPU 开销。
  static Future<WebSocketTransport> connect(
    Uri uri, {
    String? authorization,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: authorization == null
          ? null
          : <String, dynamic>{'Authorization': authorization},
      compression: CompressionOptions.compressionOff,
    ).timeout(timeout);
    return IoWebSocketTransport._(socket);
  }

  @override
  bool get isOpen => _socket.readyState == WebSocket.open;

  @override
  Stream<Object> get messages => _socket.map<Object>(
    (event) => event is String
        ? event
        : event is Uint8List
        ? event
        : Uint8List.fromList((event as List<int>)),
  );

  @override
  void sendBinary(Uint8List data) => _socket.add(data);

  @override
  Future<void> close([int code = 1000, String? reason]) =>
      _socket.close(code, reason);
}

/// 原生平台的工厂函数（与 web 版**同名**，由条件导出二选一）。
Future<WebSocketTransport> connectWebSocketTransport(
  Uri uri, {
  String? authorization,
  Duration timeout = const Duration(seconds: 15),
}) => IoWebSocketTransport.connect(
  uri,
  authorization: authorization,
  timeout: timeout,
);
