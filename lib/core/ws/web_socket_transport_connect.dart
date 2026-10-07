/// WebSocket 传输的**平台分派**入口。
///
/// 上层（`device_list_remote_datasource` / `stream_remote_datasource`）**只 import 这个文件**，
/// 拿到的是当前平台的那份 `connectWebSocketTransport`：
/// - 原生：`dart:io` 的 `WebSocket`，支持 `Authorization` 头；
/// - web：`web_socket_channel`，**不支持自定义请求头**（见 web 实现的类注释）。
library;

export 'web_socket_transport.dart';
export 'web_socket_transport_io.dart'
    if (dart.library.js_interop) 'web_socket_transport_web.dart';
