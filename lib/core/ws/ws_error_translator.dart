import 'dart:async';
import 'dart:io';

import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

/// 把 WebSocket 建连阶段的底层异常翻译成带可读文案的业务异常。
///
/// 只在边界（datasource）调用一次，避免各层重复拼错误文案。
GlobalException translateHandshakeError(Object error, StackTrace stackTrace) {
  if (error is WebSocketException) {
    final message = error.message.toLowerCase();
    // dart:io 在服务端返回非 101 时统一抛 "Connection to '...' was not upgraded
    // to websocket"，ws-scrcpy 开了 Basic Auth 时最常见的原因就是凭据不对。
    if (message.contains('not upgraded') || message.contains('401')) {
      return RemoteException(
        message: '握手被拒绝：请检查 Basic Auth 账号与密码、以及服务地址是否正确',
        exception: error,
        stackTrace: stackTrace,
      );
    }
    return RemoteException(
      message: 'WebSocket 握手失败：${error.message}',
      exception: error,
      stackTrace: stackTrace,
    );
  }
  if (error is SocketException) {
    return RemoteException(
      message: '网络不可达或地址错误：${error.message}',
      exception: error,
      stackTrace: stackTrace,
    );
  }
  if (error is TimeoutException) {
    return RemoteException(
      message: '连接超时，请确认服务端可访问（内网调试地址仅在同网段可用）',
      exception: error,
      stackTrace: stackTrace,
    );
  }
  if (error is HandshakeException) {
    return RemoteException(
      message: 'TLS 握手失败：证书不受信任或系统时间不正确',
      exception: error,
      stackTrace: stackTrace,
    );
  }
  return RemoteException(
    message: '连接失败：$error',
    exception: error,
    stackTrace: stackTrace,
  );
}
