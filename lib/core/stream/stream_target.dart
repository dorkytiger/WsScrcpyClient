import 'package:ws_scrcpy_client/core/platform/platform_capabilities.dart';
import 'package:ws_scrcpy_client/core/ws/ws_action.dart';
import 'package:ws_scrcpy_client/core/ws/ws_url_builder.dart';

/// 一次投流的连接目标：包含"服务端代理地址"与"设备直连地址"两类候选。
///
/// 实测结论（M0）：公网入口下设备的内网 IP（如 Docker 网段）客户端无法直连，
/// 必须走 `action=proxy-ws` 由服务端转发；同一局域网内则可以直连 8886 端口。
class StreamTarget {
  const StreamTarget({
    required this.serverUri,
    required this.udid,
    required this.interfaceHosts,
  });

  /// 服务端入口（http/https 均可，内部会转成 ws/wss）。
  final Uri serverUri;

  /// 设备序列号。
  final String udid;

  /// 设备侧网卡 IPv4 候选（来自设备描述符 `interfaces`）。
  final List<String> interfaceHosts;

  /// 设备直连地址候选。
  List<Uri> get directUris => interfaceHosts
      .map(
        (host) => WsUrlBuilder.directStream(
          hostname: host,
          udid: udid,
          pathname: serverUri.path.isEmpty ? '/' : serverUri.path,
        ),
      )
      .toList(growable: false);

  /// 经服务端代理的地址候选（按优先级排在直连之前）。
  List<Uri> get proxiedUris => directUris
      .map((inner) => WsUrlBuilder.proxyWs(serverUri, inner))
      .toList(growable: false);

  /// 按优先级排列的候选地址：代理优先，其次直连。
  ///
  /// **web 上只给代理地址**（2026-10-02 实测）：浏览器不给 WebSocket 加自定义请求头，
  /// Basic 凭据只能由浏览器按 origin 代管；而设备直连地址（`192.168.x.x:8000`）
  /// 与服务端入口**不是同一个 origin**，每试一个都会**单独弹一次登录框**，
  /// 公网入口下这些地址本来也不可达 —— 用户看到的就是"每次点击都要 basic auth"。
  List<Uri> get candidateUris =>
      isWebPlatform ? proxiedUris : <Uri>[...proxiedUris, ...directUris];

  /// 网页端投流页的深链：在 WebView 里打开它就**直接**进入该设备的投流页。
  ///
  /// 参数逐条实测自服务端 bundle：`StreamClientScrcpy.parseParameters` 需要
  /// `action=stream` / `udid` / `player` / `ws`，基类还需要
  /// `secure` / `hostname` / `port` / `pathname` / `useProxy`；
  /// 而 `StreamReceiverScrcpy.buildDirectWebSocketUrl` 只把 `ws` 当连接地址，
  /// `useProxy=true` 时再由页面用 `?action=proxy-ws&ws=<内层>` 包一层（公网场景必需）。
  Uri webPlayerUri({String playerCodeName = defaultWebPlayerCodeName}) {
    final host = interfaceHosts.isEmpty ? serverUri.host : interfaceHosts.first;
    final path = serverUri.path.isEmpty ? '/' : serverUri.path;
    final inner = WsUrlBuilder.directStream(
      hostname: host,
      udid: udid,
      pathname: path,
    );
    final parameters = <String, String>{
      'action': WsAction.stream.code,
      'udid': udid,
      'player': playerCodeName,
      'secure': 'false',
      'hostname': host,
      'port': kWsScrcpyServerPort.toString(),
      'pathname': path,
      'useProxy': 'true',
      'ws': inner.toString(),
    };
    final query = parameters.entries
        .map(
          (MapEntry<String, String> entry) =>
              '${entry.key}=${Uri.encodeComponent(entry.value)}',
        )
        .join('&');
    // 页面读的是 location.hash（去掉开头的 `#!`），因此这里手工拼 fragment。
    return Uri.parse('${serverUri.toString()}#!$query');
  }

  /// 默认播放器代号：`mse`（页面里的 H264 Converter + MSE），
  /// 在 Android WebView 上兼容性最好；其它可选值见服务端 bundle：
  /// `tinyh264` / `webcodecs` / `broadway`。
  static const String defaultWebPlayerCodeName = 'mse';

  /// 投流使用 `action=stream`（见 [WsAction.stream]）。
  @override
  String toString() =>
      'StreamTarget(udid: $udid, serverUri: $serverUri, hosts: $interfaceHosts)';
}
