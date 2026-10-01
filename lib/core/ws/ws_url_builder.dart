import 'dart:convert';

import 'package:ws_scrcpy_client/core/ws/ws_action.dart';

/// ws-scrcpy 服务端自身监听的端口（设备直连地址里使用）。
const int kWsScrcpyServerPort = 8886;

/// 构造与服务端交互的 WebSocket 地址。
///
/// 实测（真实服务端 bundle `BaseClient.buildDirectWebSocketUrl` / `wrapInProxy`）：
/// - 复用/设备列表：`wss://host/<path>?action=multiplex`
/// - 投流（直连设备）：`ws://<设备IPv4>:8886/<path>?action=stream&udid=<udid>`
/// - 经服务端代理转发：`wss://host/<path>?action=proxy-ws&ws=<内层地址>`
class WsUrlBuilder {
  const WsUrlBuilder._();

  /// 打开复用层入口地址。
  static Uri multiplex(Uri serverUri) =>
      _withAction(serverUri, WsAction.multiplex.code);

  /// 打开指定 action 的地址（无额外参数）。
  static Uri action(Uri serverUri, WsAction action) =>
      _withAction(serverUri, action.code);

  /// 直连设备的投流地址（ws-scrcpy 服务端在同一台设备的 8886 端口）。
  static Uri directStream({
    required String hostname,
    required String udid,
    int port = kWsScrcpyServerPort,
    String pathname = '/',
    bool secure = false,
  }) {
    final scheme = secure ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: hostname,
      port: port,
      path: pathname,
      queryParameters: <String, String>{
        'action': WsAction.stream.code,
        'udid': udid,
      },
    );
  }

  /// 把内层地址包成服务端代理地址（用于公网入口，浏览器/客户端无法直连设备内网 IP 时）。
  static Uri proxyWs(Uri serverUri, Uri inner) {
    final base = toWebSocketUri(serverUri).replace(
      queryParameters: <String, String>{
        'action': WsAction.proxyWs.code,
        'ws': inner.toString(),
      },
    );
    return base;
  }

  /// 生成 `Authorization` 头取值。
  static String basicAuthorization(String username, String password) =>
      'Basic ${base64.encode(utf8.encode('$username:$password'))}';

  static Uri _withAction(Uri serverUri, String action) {
    final query = Map<String, String>.from(serverUri.queryParameters);
    query['action'] = action;
    return toWebSocketUri(serverUri).replace(queryParameters: query);
  }

  /// 把 HTTP(S) 入口地址转换成对应的 WebSocket 地址（http→ws，https→wss）。
  static Uri toWebSocketUri(Uri uri) {
    final scheme = switch (uri.scheme) {
      'http' => 'ws',
      'https' => 'wss',
      _ => uri.scheme,
    };
    return scheme == uri.scheme ? uri : uri.replace(scheme: scheme);
  }
}
