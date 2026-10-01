import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/feature/device/data/model/response/device_list_response.dart';
import 'package:ws_scrcpy_client/feature/device/enum/device_state.dart';

void main() {
  group('DeviceListResponse 解析（真实报文）', () {
    late DeviceListResponse response;

    setUpAll(() {
      // M0 探测时从真实服务端 GTRC 通道抓到的一条 devicelist 消息。
      final raw = File('test/fixtures/device_list.json').readAsStringSync();
      response = DeviceListResponse.parse(raw);
    });

    test('消息类型为 devicelist 且带 tracker 标识', () {
      expect(response.messageType, DeviceListResponse.expectedMessageType);
      expect(response.trackerName, isNotNull);
      expect(response.trackerId, isNotNull);
    });

    test('解析出设备、状态与网卡', () {
      expect(response.devices, isNotEmpty);
      final device = response.devices.first;
      expect(device.udid, isNotEmpty);
      expect(device.state, DeviceState.device);
      expect(device.model, isNotNull);
      expect(device.interfaces, isNotEmpty);
      expect(device.interfaces.first.ipv4, isNotEmpty);
    });
  });

  group('DeviceListResponse 异常与兜底', () {
    test('不是 JSON 时抛 ParsingException', () {
      expect(
        () => DeviceListResponse.parse('not json'),
        throwsA(isA<ParsingException>()),
      );
    });

    test('缺少 data.list 时抛 ParsingException', () {
      expect(
        () => DeviceListResponse.parse('{"type":"devicelist","data":{}}'),
        throwsA(isA<ParsingException>()),
      );
    });

    test('缺少 udid 时抛 ParsingException', () {
      expect(
        () => DeviceListResponse.parse(
          '{"type":"devicelist","data":{"list":[{"state":"device"}]}}',
        ),
        throwsA(isA<ParsingException>()),
      );
    });

    test('未知 state 回落为 unknown 而不是抛错', () {
      final parsed = DeviceListResponse.parse(
        '{"type":"devicelist","data":{"list":['
        '{"udid":"x","state":"something-new","interfaces":[]}]}}',
      );
      expect(parsed.devices.single.state, DeviceState.unknown);
      expect(parsed.devices.single.state.isUsable, isFalse);
    });

    test('缺失的可选字段按 null 处理，不抛错', () {
      final parsed = DeviceListResponse.parse(
        '{"type":"devicelist","data":{"list":[{"udid":"x","state":"offline"}]}}',
      );
      final device = parsed.devices.single;
      expect(device.model, isNull);
      expect(device.interfaces, isEmpty);
      expect(device.pid, isNull);
    });
  });

  group('DeviceState.fromCode', () {
    test('逐个取值映射', () {
      expect(DeviceState.fromCode('device'), DeviceState.device);
      expect(DeviceState.fromCode('offline'), DeviceState.offline);
      expect(DeviceState.fromCode('unauthorized'), DeviceState.unauthorized);
      expect(DeviceState.fromCode(null), DeviceState.unknown);
    });
  });
}
