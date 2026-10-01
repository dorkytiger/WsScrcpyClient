/// 设备在线状态（服务端下发的 `state` 字段）。
///
/// 禁止在业务代码里直接比较字符串，解析只在这里做一次。
enum DeviceState {
  /// 可用。
  device('device', '在线'),

  /// 掉线。
  offline('offline', '离线'),

  /// 未授权（设备上未确认 USB 调试）。
  unauthorized('unauthorized', '未授权'),

  /// 未知取值：安全兜底，UI 上按"不可用"处理并提示。
  unknown('unknown', '未知状态');

  const DeviceState(this.code, this.description);

  final String code;
  final String description;

  bool get isUsable => this == DeviceState.device;

  /// 服务端字符串 → 枚举的唯一解析入口。
  static DeviceState fromCode(String? code) {
    for (final value in DeviceState.values) {
      if (value.code == code) {
        return value;
      }
    }
    return DeviceState.unknown;
  }
}
