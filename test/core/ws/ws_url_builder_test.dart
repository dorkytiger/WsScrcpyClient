import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/ws/ws_action.dart';
import 'package:ws_scrcpy_client/core/ws/ws_url_builder.dart';

void main() {
  group('WsUrlBuilder', () {
    test('multiplex 把 https 转成 wss 并带上 action=multiplex', () {
      final uri = WsUrlBuilder.multiplex(
        Uri.parse('https://android.dorkytiger.top/'),
      );
      expect(uri.toString(), 'wss://android.dorkytiger.top/?action=multiplex');
    });

    test('内网 http 入口转成 ws', () {
      final uri = WsUrlBuilder.action(
        Uri.parse('http://192.168.11.132:8000/'),
        WsAction.googDeviceList,
      );
      expect(
        uri.toString(),
        'ws://192.168.11.132:8000/?action=goog-device-list',
      );
    });

    test('directStream 按实测构造 ws://设备IPv4:8886/?action=stream&udid=…', () {
      final uri = WsUrlBuilder.directStream(
        hostname: '192.168.112.2',
        udid: 'redroid:5555',
      );
      expect(
        uri.toString(),
        'ws://192.168.112.2:8886/?action=stream&udid=redroid%3A5555',
      );
    });

    test('proxyWs 把内层地址包进 action=proxy-ws 的 ws 参数', () {
      final inner = WsUrlBuilder.directStream(
        hostname: '192.168.112.2',
        udid: 'redroid:5555',
      );
      final proxied = WsUrlBuilder.proxyWs(
        Uri.parse('https://android.dorkytiger.top/'),
        inner,
      );
      expect(proxied.scheme, 'wss');
      expect(proxied.queryParameters['action'], 'proxy-ws');
      expect(proxied.queryParameters['ws'], inner.toString());
    });

    test('basicAuthorization 生成标准 Basic 头', () {
      expect(
        WsUrlBuilder.basicAuthorization('user', 'pass'),
        // base64("user:pass")
        'Basic dXNlcjpwYXNz',
      );
    });
  });
}
