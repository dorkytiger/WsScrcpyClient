import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/feature/settings/application/service/settings_service.dart';

import 'settings_test_support.dart';

void main() {
  late SettingsTestContext context;

  setUp(() {
    context = SettingsTestContext();
  });

  tearDown(() async {
    await context.dispose();
  });

  group('SettingsService 校验', () {
    test('地址不合法时返回 ValidationException', () async {
      final result = await context.service.save(
        settingsDto(
          serverUrl: 'android.dorkytiger.top',
          username: '',
          password: '',
        ),
      );
      expect(result.isError, isTrue);
      expect(result.error, isA<ValidationException>());
      expect(result.error!.message, contains('服务地址不合法'));
    });

    test('非 http(s) 协议被拒绝', () async {
      final result = await context.service.save(
        settingsDto(
          serverUrl: 'ftp://example.com/',
          username: '',
          password: '',
        ),
      );
      expect(result.isError, isTrue);
      expect(result.error!.message, contains('http'));
    });

    test('原生端：只填账号不填密码被拒绝（成对填写）', () async {
      final result = await context.service.save(
        settingsDto(
          serverUrl: 'https://android.dorkytiger.top/',
          username: 'u',
          password: '',
        ),
      );
      expect(result.isError, isTrue);
      expect(result.error!.message, contains('同时填写'));
    });

    test('★ web 端：只填账号能保存（密码由浏览器代管，表单里本来就没有密码框）', () async {
      // 用户实测："你这不是自相矛盾了吗" —— 表单把密码框藏了，校验却要求成对填写，
      // 于是 web 上永远存不下配置。web 上"有账号没密码"是正常状态。
      final web = SettingsTestContext(isWeb: true);
      addTearDown(web.dispose);
      final result = await web.service.save(
        settingsDto(
          serverUrl: 'https://android.dorkytiger.top/',
          username: 'u758272094',
          password: '',
        ),
      );
      expect(result.isError, isFalse, reason: result.isError ? result.error!.message : '');
      final saved = await web.service.load();
      expect(saved.isSuccess, isTrue);
      expect(saved.data!.username, 'u758272094');
      expect(saved.data!.password, isEmpty);
    });

    test('★ web 端：填了密码却没账号仍然拒绝（那是把账号填进密码框了）', () async {
      final web = SettingsTestContext(isWeb: true);
      addTearDown(web.dispose);
      final result = await web.service.save(
        settingsDto(
          serverUrl: 'https://android.dorkytiger.top/',
          username: '',
          password: 'oops',
        ),
      );
      expect(result.isError, isTrue);
      expect(result.error!.message, contains('同时填写'));
    });

    test('空的设备序列号无法记住', () async {
      final result = await context.service.rememberLastDevice('');
      expect(result.isError, isTrue);
      expect(result.error, isA<ValidationException>());
    });

    test('校验失败时不落库（不会留下半套配置）', () async {
      await context.service.save(settingsDto(serverUrl: 'bad-url'));

      expect((await context.service.hasAnyProfile()).data, isFalse);
      expect((await context.service.listProfiles()).data, isEmpty);
    });

    test('createProfile / activateProfile / deleteProfile 拦下非法 id', () async {
      expect((await context.service.activateProfile(0)).isError, isTrue);
      expect((await context.service.deleteProfile(-1)).isError, isTrue);
    });
  });

  group('SettingsService 默认值', () {
    test('默认指向文档里的公网入口，且默认开启常亮', () {
      expect(
        SettingsService.defaults.serverUrl,
        'https://android.dorkytiger.top/',
      );
      expect(SettingsService.defaults.keepScreenOn, isTrue);
      expect(SettingsService.defaults.hasBasicAuth, isFalse);
      expect(SettingsService.defaults.basicAuthorizationHeader, isNull);
    });

    test('未配置任何 profile 时 load 返回默认值且 profileId 为空', () async {
      final loaded = (await context.service.load()).data!;

      expect(loaded.profileId, isNull);
      expect(loaded.profileName, isNull);
      expect(loaded.serverUrl, SettingsService.defaults.serverUrl);
      expect(loaded.hasBasicAuth, isFalse);
    });
  });

  group('SettingsService 首次进入判定', () {
    test('hasAnyProfile 在新建前后翻转', () async {
      expect((await context.service.hasAnyProfile()).data, isFalse);
      await context.createProfile();
      expect((await context.service.hasAnyProfile()).data, isTrue);
    });

    test(
      '新建后 load 带回 profileId / profileName 与 basicAuthorizationHeader',
      () async {
        await context.createProfile(
          serverUrl: 'https://android.dorkytiger.top/',
          username: 'user',
          password: 'pass',
        );

        final loaded = (await context.service.load()).data!;

        expect(loaded.profileId, isNotNull);
        expect(loaded.profileName, 'android.dorkytiger.top');
        expect(loaded.hasBasicAuth, isTrue);
        expect(loaded.basicAuthorizationHeader, startsWith('Basic '));
      },
    );
  });
}
