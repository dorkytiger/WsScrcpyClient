import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';

void main() {
  group('StreamTarget', () {
    final target = StreamTarget(
      serverUri: Uri.parse('https://android.dorkytiger.top/'),
      udid: 'redroid:5555',
      interfaceHosts: const <String>['192.168.112.2', '10.0.0.5'],
    );

    test('直连地址使用设备网卡与 8886 端口', () {
      expect(target.directUris, hasLength(2));
      expect(
        target.directUris.first.toString(),
        'ws://192.168.112.2:8886/?action=stream&udid=redroid%3A5555',
      );
    });

    test('代理地址基于服务端入口并保留内层地址', () {
      expect(target.proxiedUris, hasLength(2));
      final first = target.proxiedUris.first;
      expect(first.scheme, 'wss');
      expect(first.queryParameters['action'], 'proxy-ws');
      expect(first.queryParameters['ws'], target.directUris.first.toString());
    });

    test('候选顺序为代理优先（实测公网下设备内网 IP 不可直连）', () {
      final candidates = target.candidateUris;
      expect(candidates, hasLength(4));
      expect(candidates.first, target.proxiedUris.first);
      expect(candidates.last, target.directUris.last);
    });

    test('没有网卡信息时没有候选地址', () {
      final empty = StreamTarget(
        serverUri: Uri.parse('https://android.dorkytiger.top/'),
        udid: 'x',
        interfaceHosts: const <String>[],
      );
      expect(empty.candidateUris, isEmpty);
    });
  });

  group('StreamTarget.webPlayerUri（网页投流深链）', () {
    final target = StreamTarget(
      serverUri: Uri.parse('https://android.dorkytiger.top/'),
      udid: 'redroid:5555',
      interfaceHosts: const <String>['192.168.112.2'],
    );

    test('带齐网页端 parseParameters 需要的全部参数', () {
      final uri = target.webPlayerUri();
      expect(uri.path, '/');
      expect(uri.fragment.startsWith('!'), isTrue);

      final parameters = Uri.splitQueryString(uri.fragment.substring(1));
      expect(parameters['action'], 'stream');
      expect(parameters['udid'], 'redroid:5555');
      expect(parameters['player'], 'mse');
      expect(parameters['secure'], 'false');
      expect(parameters['hostname'], '192.168.112.2');
      expect(parameters['port'], '8886');
      expect(parameters['pathname'], '/');
      // 公网入口下必须走服务端代理，否则页面里连的是不可达的内网 IP。
      expect(parameters['useProxy'], 'true');
      expect(
        parameters['ws'],
        'ws://192.168.112.2:8886/?action=stream&udid=redroid%3A5555',
      );
    });

    test('可以指定其它播放器代号', () {
      final uri = target.webPlayerUri(playerCodeName: 'tinyh264');
      final parameters = Uri.splitQueryString(uri.fragment.substring(1));
      expect(parameters['player'], 'tinyh264');
    });

    test('没有网卡信息时回落到服务端 host', () {
      final fallback = StreamTarget(
        serverUri: Uri.parse('https://android.dorkytiger.top/'),
        udid: 'x',
        interfaceHosts: const <String>[],
      );
      final parameters = Uri.splitQueryString(
        fallback.webPlayerUri().fragment.substring(1),
      );
      expect(parameters['hostname'], 'android.dorkytiger.top');
    });
  });
}
