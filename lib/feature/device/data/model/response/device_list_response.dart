import 'dart:convert';

import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/feature/device/enum/device_state.dart';

/// 设备的一个网络接口（服务端下发，用于构造直连投流地址）。
class DeviceInterfaceResponse {
  const DeviceInterfaceResponse({required this.name, required this.ipv4});

  final String name;
  final String ipv4;
}

/// 设备描述符（与 `devicelist` 里 `data.list` 的字段一一对应）。
class DeviceDescriptorResponse {
  const DeviceDescriptorResponse({
    required this.udid,
    required this.state,
    required this.model,
    required this.manufacturer,
    required this.androidRelease,
    required this.androidSdk,
    required this.cpuAbi,
    required this.interfaces,
    required this.pid,
    required this.lastUpdateTimestamp,
  });

  final String udid;
  final DeviceState state;
  final String? model;
  final String? manufacturer;
  final String? androidRelease;
  final String? androidSdk;
  final String? cpuAbi;
  final List<DeviceInterfaceResponse> interfaces;
  final int? pid;
  final int? lastUpdateTimestamp;
}

/// 设备列表响应。
///
/// 实测结构（M0 探测，来自真实服务端 GTRC 通道）：
/// ```json
/// {
///   "id": -1,
///   "type": "devicelist",
///   "data": {
///     "list": [ { "udid": "redroid:5555", "state": "device",
///                 "interfaces": [{"name":"eth0","ipv4":"192.168.112.2"}], ... } ],
///     "id": "5131…", "name": "aDevice Tracker […]"
///   }
/// }
/// ```
class DeviceListResponse {
  const DeviceListResponse({
    required this.messageType,
    required this.trackerId,
    required this.trackerName,
    required this.devices,
  });

  /// 服务端消息类型，固定为 `devicelist`。
  static const String expectedMessageType = 'devicelist';

  final String messageType;
  final String? trackerId;
  final String? trackerName;
  final List<DeviceDescriptorResponse> devices;

  /// 唯一解析入口：任何字段缺失/类型不符都抛 [ParsingException]。
  static DeviceListResponse parse(String rawText) {
    final Object? decoded;
    try {
      decoded = jsonDecode(rawText);
    } on FormatException catch (error) {
      throw ParsingException(
        message: '设备列表不是合法 JSON：${error.message}',
        exception: error,
      );
    }
    return fromJson(decoded);
  }

  /// 从已解码的 JSON 解析（供测试与 probe 复用）。
  static DeviceListResponse fromJson(Object? decoded) {
    if (decoded is! Map<String, dynamic>) {
      throw const ParsingException(message: '设备列表响应不是 JSON 对象');
    }
    final type = decoded['type'];
    if (type is! String) {
      throw const ParsingException(message: '设备列表响应缺少 type 字段');
    }
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw const ParsingException(message: '设备列表响应缺少 data 对象');
    }
    final list = data['list'];
    if (list is! List) {
      throw const ParsingException(message: '设备列表响应缺少 data.list 数组');
    }
    final devices = <DeviceDescriptorResponse>[];
    for (var index = 0; index < list.length; index++) {
      final item = list[index];
      if (item is! Map<String, dynamic>) {
        throw ParsingException(message: 'data.list[$index] 不是 JSON 对象');
      }
      devices.add(_parseDescriptor(item, index));
    }
    return DeviceListResponse(
      messageType: type,
      trackerId: data['id'] is String ? data['id'] as String : null,
      trackerName: data['name'] is String ? data['name'] as String : null,
      devices: devices,
    );
  }

  static DeviceDescriptorResponse _parseDescriptor(
    Map<String, dynamic> json,
    int index,
  ) {
    final udid = json['udid'];
    if (udid is! String || udid.isEmpty) {
      throw ParsingException(message: 'data.list[$index] 缺少可用的 udid');
    }
    final state = json['state'];
    if (state is! String) {
      throw ParsingException(message: '设备 $udid 缺少 state 字段');
    }
    final interfaces = <DeviceInterfaceResponse>[];
    final rawInterfaces = json['interfaces'];
    if (rawInterfaces is List) {
      for (final item in rawInterfaces) {
        if (item is Map<String, dynamic>) {
          final name = item['name'];
          final ipv4 = item['ipv4'];
          if (name is String && ipv4 is String && ipv4.isNotEmpty) {
            interfaces.add(DeviceInterfaceResponse(name: name, ipv4: ipv4));
          }
        }
      }
    }
    return DeviceDescriptorResponse(
      udid: udid,
      state: DeviceState.fromCode(state),
      model: json['ro.product.model'] as String?,
      manufacturer: json['ro.product.manufacturer'] as String?,
      androidRelease: json['ro.build.version.release'] as String?,
      androidSdk: json['ro.build.version.sdk']?.toString(),
      cpuAbi: json['ro.product.cpu.abi'] as String?,
      interfaces: interfaces,
      pid: json['pid'] is int ? json['pid'] as int : null,
      lastUpdateTimestamp: json['last.update.timestamp'] is int
          ? json['last.update.timestamp'] as int
          : null,
    );
  }
}
