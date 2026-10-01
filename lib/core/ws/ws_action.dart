/// ws-scrcpy 连接查询参数 `action` 的取值。
///
/// 取值来自真实服务端 bundle 里的 `ACTION` 枚举，禁止自行改动。
enum WsAction {
  listHosts('list-hosts'),
  applDeviceList('appl-device-list'),
  googDeviceList('goog-device-list'),

  /// 复用层入口：所有需要多通道的连接都先连这个 action。
  multiplex('multiplex'),
  shell('shell'),
  proxyWs('proxy-ws'),
  proxyAdb('proxy-adb'),
  devtools('devtools'),

  /// scrcpy 投流（裸 H.264，非复用）。
  stream('stream'),
  streamQvh('stream-qvh'),
  streamMjpeg('stream-mjpeg'),
  proxyWda('proxy-wda'),
  fileListing('list-files');

  const WsAction(this.code);

  final String code;
}

/// 复用层逻辑通道的通道码（`CreateChannel` 的 payload，4 字节 ASCII）。
///
/// 客户端先连 `action=multiplex`，再用通道码打开具体能力通道。
enum ChannelCode {
  /// 文件列表。
  fsls('FSLS'),

  /// 主机列表。
  hsts('HSTS'),

  /// 终端 shell。
  shel('SHEL'),

  /// 谷歌设备列表（Android 设备）。
  gtrc('GTRC'),

  /// 苹果设备列表（iOS 设备）。
  atrc('ATRC'),
  wdap('WDAP'),
  qvhs('QVHS');

  const ChannelCode(this.code);

  final String code;
}
