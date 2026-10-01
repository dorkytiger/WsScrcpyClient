import 'package:ws_scrcpy_client/feature/device/enum/device_state.dart';

/// 设备接口（UI 展示与投流直连地址构造共用）。
class DeviceInterfaceVo {
  const DeviceInterfaceVo({required this.name, required this.ipv4});

  final String name;
  final String ipv4;
}

/// 设备展示对象：UI 只认它，不再直接接触服务端 JSON。
class DeviceVo {
  const DeviceVo({
    required this.udid,
    required this.state,
    required this.name,
    required this.model,
    required this.androidRelease,
    required this.cpuAbi,
    required this.interfaces,
  });

  final String udid;
  final DeviceState state;

  /// 展示名（无型号时回落为 udid）。
  final String name;
  final String? model;
  final String? androidRelease;
  final String? cpuAbi;
  final List<DeviceInterfaceVo> interfaces;

  /// 是否可投流。
  bool get isUsable => state.isUsable;

  /// 直连投流所需的内网 IP 候选（公网入口下要用服务端代理转发）。
  List<String> get interfaceHosts =>
      interfaces.map((item) => item.ipv4).toList(growable: false);

  @override
  String toString() =>
      'DeviceVo(udid: $udid, state: ${state.code}, name: $name)';
}
