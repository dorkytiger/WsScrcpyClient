/// 投流会话状态。
enum StreamConnectionStatus {
  /// 未连接。
  idle('idle', '未连接'),

  /// 正在建立连接。
  connecting('connecting', '连接中'),

  /// 已收到初始信息头（服务端已确认会话）。
  connected('connected', '已连接'),

  /// 正在重连（指数退避）。
  reconnecting('reconnecting', '重连中'),

  /// 已收到视频数据（真正的推流中）。
  streaming('streaming', '推流中'),

  /// 连接失败（终态，需要用户重试）。
  failed('failed', '连接失败');

  const StreamConnectionStatus(this.code, this.description);

  final String code;
  final String description;

  bool get isBusy =>
      this == StreamConnectionStatus.connecting ||
      this == StreamConnectionStatus.reconnecting;

  bool get isUsable =>
      this == StreamConnectionStatus.connected ||
      this == StreamConnectionStatus.streaming;
}
