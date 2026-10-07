import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';

/// web 上的 WebSocket 传输。
///
/// ## ★ 一个绕不过去的平台差异：**浏览器不给 WebSocket 自定义请求头**
///
/// 原生端的做法是握手时带 `Authorization: Basic ...`（[IoWebSocketTransport]）。
/// 浏览器里**没有这个能力** —— `WebSocket` 构造器不接受 headers，
/// 所以 [authorization] 参数在这里**只能被忽略**。
///
/// 那服务端开了 Basic Auth 怎么办？两条路，**服务端自己的网页播放器走的是第 2 条**：
///
/// 1. 把凭据塞进 URL（`wss://user:pass@host/...`）—— 不可靠，浏览器对带 userinfo 的
///    WebSocket URL 支持不一致，且会把密码留在 URL 里；
/// 2. **交给浏览器的 HTTP 认证缓存**：页面先被服务端以 `401 + WWW-Authenticate: Basic`
///    挑战一次（浏览器弹出原生登录框），用户答对之后，浏览器会把凭据缓存到该 realm，
///    之后**包括 WebSocket 握手在内**的所有请求都自动带上。
///    我把服务端 bundle 反查过：它是 `new WebSocket(url)`，全文没有任何 auth 处理
///    —— 所以这条路是上游验证过的可行路径。
///
/// 结论（对产品形态有影响，别当成实现细节）：
/// **web 端不需要、也拿不到密码**，因此 web 端不做凭据存储，
/// 界面上只填"服务端地址"，鉴权交给浏览器那一次原生弹框。
class WebWebSocketTransport implements WebSocketTransport {
  WebWebSocketTransport._(this._channel) {
    // 用 sink.done 维护 isOpen：WebSocketChannel 没有公开的 readyState，
    // 而 sink 的 done 在连接关闭（含服务端主动关）时完成。
    _done = _channel.sink.done
        .then<void>((_) => _open = false)
        .catchError((Object _) => _open = false);
  }

  final WebSocketChannel _channel;
  late final Future<void> _done;
  bool _open = true;

  /// 建立连接。
  ///
  /// [authorization] 见类注释：浏览器不支持，这里**忽略**它（保留参数是为了与原生端
  /// 共用同一个调用签名）。
  static Future<WebSocketTransport> connect(
    Uri uri, {
    String? authorization,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final channel = WebSocketChannel.connect(uri);
    // ready 会在握手失败（含 401）时抛错，正好当超时/鉴权失败信号用。
    await channel.ready.timeout(timeout);
    return WebWebSocketTransport._(channel);
  }

  @override
  bool get isOpen => _open;

  @override
  Stream<Object> get messages => _channel.stream.map<Object>(
    (Object? event) => event is String
        ? event
        : event is Uint8List
        ? event
        : Uint8List.fromList((event! as List<Object?>).cast<int>()),
  );

  @override
  void sendBinary(Uint8List data) => _channel.sink.add(data);

  @override
  Future<void> close([int code = 1000, String? reason]) async {
    _open = false;
    await _channel.sink.close(code, reason);
    // 等 done 收尾，避免上层在连接还没关干净时就复用状态。
    await _done;
  }
}

/// web 平台的工厂函数（与原生版**同名**，由条件导出二选一）。
Future<WebSocketTransport> connectWebSocketTransport(
  Uri uri, {
  String? authorization,
  Duration timeout = const Duration(seconds: 15),
}) => WebWebSocketTransport.connect(
  uri,
  authorization: authorization,
  timeout: timeout,
);
