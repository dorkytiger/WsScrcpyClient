import 'dart:async';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';
import 'package:ws_scrcpy_client/core/ws/ws_error_translator.dart';

/// 一条已建立的投流连接。
///
/// 投流通道**不走复用层**（实测：`action=stream` 直接返回裸 H.264 与初始信息头），
/// 控制消息也直接以二进制帧发在同一条连接上。
class StreamSession {
  StreamSession._(this.uri, this._transport);

  /// 用任意传输实现构造会话。
  ///
  /// 给单元测试与嵌入式用法留的口子：这样可以拿假传输驱动整条会话逻辑
  /// （初始信息头解析、视频帧分发、控制消息下发）而不碰真实网络。
  factory StreamSession.fromTransport(Uri uri, WebSocketTransport transport) =>
      StreamSession._(uri, transport);

  final Uri uri;
  final WebSocketTransport _transport;

  Stream<Object> get messages => _transport.messages;

  bool get isOpen => _transport.isOpen;

  void send(Uint8List data) => _transport.sendBinary(data);

  Future<void> close() => _transport.close();
}

/// 投流远程数据源：只负责"连上并收发字节"，不理解消息语义。
class StreamRemoteDatasource {
  StreamRemoteDatasource({AppLogger? logger})
    : _logger = logger ?? AppLogger('StreamRemoteDatasource');

  final AppLogger _logger;

  Future<Result<StreamSession>> connect({
    required Uri uri,
    String? authorization,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final transport = await IoWebSocketTransport.connect(
        uri,
        authorization: authorization,
        timeout: timeout,
      );
      _logger.info('投流连接已建立：$uri');
      return Result.success(StreamSession._(uri, transport));
    } catch (error, stackTrace) {
      _logger.warn('投流连接失败：$uri', error, stackTrace);
      return Result.failure(translateHandshakeError(error, stackTrace));
    }
  }
}
