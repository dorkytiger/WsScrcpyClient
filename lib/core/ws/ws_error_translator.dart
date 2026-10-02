import 'dart:async';
import 'dart:io';

import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/platform/platform_capabilities.dart';

/// 把 WebSocket 建连阶段的底层异常翻译成带可读文案的业务异常。
///
/// 只在边界（datasource）调用一次，避免各层重复拼错误文案。
GlobalException translateHandshakeError(Object error, StackTrace stackTrace) {
  // "服务端要 Basic Auth / 凭据不对"在两端的**异常类型完全不同**
  // （原生是 `dart:io` 的 WebSocketException，web 是 WebSocketChannelException
  // 包着 DOMException），所以先做一次**平台中立**的文案判定，两端共用同一句话。
  final text = error.toString();
  final looksLikeAuth =
      text.toLowerCase().contains('unauthorized') ||
      text.contains('401') ||
      (error is WebSocketException &&
          error.message.toLowerCase().contains('not upgraded'));

  if (looksLikeAuth) {
    return RemoteException(
      message: browserAuthHint == null
          // 原生：握手时自己带 Authorization 头，被拒就是凭据/地址不对。
          ? '握手被拒绝：请检查 Basic Auth 账号与密码、以及服务地址是否正确'
          // web：**不是**用户填错了，而是浏览器根本不让 WebSocket 带自定义请求头，
          // 凭据只能由浏览器按 origin 代管 —— 必须告诉他"该怎么办"。
          : '需要登录服务端（Basic Auth）。$browserAuthHint',
      exception: error,
      stackTrace: stackTrace,
    );
  }

  if (error is WebSocketException) {
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
    // web 上补一句"该怎么办"：浏览器不给 WebSocket 带自定义请求头，
    // 凭据只能由浏览器代管，用户看到的现象就是反复弹 Basic Auth 登录框。
    message: browserAuthHint == null
        ? '连接失败：$error'
        : '连接失败：$error\n$browserAuthHint',
    exception: error,
    stackTrace: stackTrace,
  );
}
