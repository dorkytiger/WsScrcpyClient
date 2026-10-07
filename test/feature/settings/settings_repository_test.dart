import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/vo/settings_profile_vo.dart';

import 'settings_test_support.dart';

void main() {
  late SettingsTestContext context;

  setUp(() {
    context = SettingsTestContext();
  });

  tearDown(() async {
    await context.dispose();
  });

  group('profile 表：新建与 active 不变量', () {
    test('新建的配置立即成为唯一 active', () async {
      expect((await context.service.hasAnyProfile()).data, isFalse);

      final id = await context.createProfile(name: '家里');

      expect(id, greaterThan(0));
      expect((await context.service.hasAnyProfile()).data, isTrue);
      expect(await singleActiveId(context.database), id);

      final profiles = (await context.service.listProfiles()).data!;
      expect(profiles, hasLength(1));
      expect(profiles.single.isActive, isTrue);
      expect(profiles.single.name, '家里');
    });

    test('再建一套时只有新的一套是 active（旧的必须被清掉）', () async {
      final first = await context.createProfile(
        serverUrl: 'https://a.example/',
      );
      final second = await context.createProfile(
        serverUrl: 'https://b.example/',
      );

      expect(await singleActiveId(context.database), second);
      final profiles = (await context.service.listProfiles()).data!;
      expect(profiles, hasLength(2));
      expect(
        profiles.where((SettingsProfileVo vo) => vo.isActive),
        hasLength(1),
      );
      expect(profiles.firstWhere((vo) => vo.id == first).isActive, isFalse);
    });

    test('名称缺失时用服务地址的 host 兜底', () async {
      await context.createProfile(serverUrl: 'https://android.dorkytiger.top/');
      final vo = (await context.service.listProfiles()).data!.single;
      expect(vo.name, 'android.dorkytiger.top');
      expect(vo.displayName, 'android.dorkytiger.top');
    });

    test('displayName：name 为空 → host；host 也为空 → 原样返回地址', () {
      const byName = SettingsProfileVo(
        id: 1,
        name: '公司',
        serverUrl: 'https://a.example/',
        username: '',
        lastUdid: null,
        keepScreenOn: true,
        isActive: true,
      );
      const byHost = SettingsProfileVo(
        id: 2,
        name: '',
        serverUrl: 'https://b.example:8000/',
        username: '',
        lastUdid: null,
        keepScreenOn: true,
        isActive: false,
      );
      const byRaw = SettingsProfileVo(
        id: 3,
        name: '',
        serverUrl: 'not-a-url',
        username: '',
        lastUdid: null,
        keepScreenOn: true,
        isActive: false,
      );

      expect(byName.displayName, '公司');
      expect(byHost.displayName, 'b.example');
      expect(byRaw.displayName, 'not-a-url');
    });
  });

  group('save：写入 active 配置', () {
    test('没有配置时 save 会新建并置为 active', () async {
      final result = await context.service.save(
        settingsDto(
          serverUrl: 'https://one.example/',
          username: 'u1',
          password: 'p1',
        ),
      );

      expect(result.isSuccess, isTrue);
      expect((await context.service.hasAnyProfile()).data, isTrue);
      final loaded = (await context.service.load()).data!;
      expect(loaded.serverUrl, 'https://one.example/');
      expect(loaded.username, 'u1');
      expect(loaded.password, 'p1');
      expect(loaded.profileId, isNotNull);
      expect(loaded.profileName, 'one.example');
    });

    test('已有 active 时 save 覆盖而不是新增', () async {
      await context.createProfile(serverUrl: 'https://one.example/', name: '旧');
      final id = (await context.service.load()).data!.profileId;

      await context.service.save(
        settingsDto(
          serverUrl: 'https://two.example/',
          username: 'u2',
          password: 'p2',
          keepScreenOn: false,
        ),
      );

      final profiles = (await context.service.listProfiles()).data!;
      expect(profiles, hasLength(1));
      expect(profiles.single.id, id);
      final loaded = (await context.service.load()).data!;
      expect(loaded.serverUrl, 'https://two.example/');
      expect(loaded.username, 'u2');
      expect(loaded.password, 'p2');
      expect(loaded.keepScreenOn, isFalse);
    });

    test('指定 id 时保存到该配置而不动 active', () async {
      final first = await context.createProfile(
        serverUrl: 'https://a.example/',
      );
      final second = await context.createProfile(
        serverUrl: 'https://b.example/',
      );
      expect(await singleActiveId(context.database), second);

      final result = await context.service.save(
        settingsDto(
          serverUrl: 'https://a2.example/',
          username: 'ua',
          password: 'pa',
          id: first,
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(await singleActiveId(context.database), second);
      final profiles = (await context.service.listProfiles()).data!;
      expect(
        profiles.firstWhere((SettingsProfileVo vo) => vo.id == first).serverUrl,
        'https://a2.example/',
      );
    });
  });

  group('activateProfile / deleteProfile', () {
    test('activateProfile 切换生效配置', () async {
      final first = await context.createProfile(
        serverUrl: 'https://a.example/',
      );
      await context.createProfile(serverUrl: 'https://b.example/');

      final result = await context.service.activateProfile(first);

      expect(result.isSuccess, isTrue);
      expect(await singleActiveId(context.database), first);
      expect(
        (await context.service.load()).data!.serverUrl,
        'https://a.example/',
      );
    });

    test('删除 active 时把最近更新的剩余配置提升为 active', () async {
      final first = await context.createProfile(
        serverUrl: 'https://a.example/',
      );
      final second = await context.createProfile(
        serverUrl: 'https://b.example/',
      );
      expect(await singleActiveId(context.database), second);

      final result = await context.service.deleteProfile(second);

      expect(result.isSuccess, isTrue);
      expect(await singleActiveId(context.database), first);
      expect((await context.service.load()).data!.profileId, first);
    });

    test('删除最后一套配置后：无 active，hasAnyProfile 为 false，load 回落默认值', () async {
      final only = await context.createProfile(serverUrl: 'https://a.example/');

      await context.service.deleteProfile(only);

      expect(await singleActiveId(context.database), isNull);
      expect((await context.service.hasAnyProfile()).data, isFalse);
      final loaded = (await context.service.load()).data!;
      expect(loaded.profileId, isNull);
      expect(loaded.serverUrl, 'https://android.dorkytiger.top/');
      expect(loaded.password, isEmpty);
    });

    test('删除配置时同时删除它的密码（同一条记录）', () async {
      final id = await context.createProfile(password: 'secret');

      await context.service.deleteProfile(id);

      final rows = await context.database
          .select(context.database.connectionProfiles)
          .get();
      expect(rows.where((row) => row.id == id), isEmpty);
    });

    test('删除不存在的配置返回失败而不是静默成功', () async {
      final result = await context.service.deleteProfile(999);
      expect(result.isError, isTrue);
    });
  });

  group('rememberLastDevice', () {
    test('写入 active 配置的 lastUdid，并记录到最近设备表', () async {
      await context.createProfile();

      final result = await context.service.rememberLastDevice(
        'redroid:5555',
        displayName: 'redroid',
      );

      expect(result.isSuccess, isTrue);
      expect((await context.service.load()).data!.lastUdid, 'redroid:5555');
      expect(await context.recentDevices.listRecentUdis(), <String>[
        'redroid:5555',
      ]);
    });

    test('同一设备重复记录只保留一条，并刷新到最后连接时间', () async {
      await context.createProfile();

      await context.service.rememberLastDevice('a:1');
      await context.service.rememberLastDevice('b:2');
      await context.service.rememberLastDevice('a:1');

      expect(await context.recentDevices.listRecentUdis(), <String>[
        'a:1',
        'b:2',
      ]);
    });

    test('同一设备重复记录都必须成功（回归：udid 唯一约束导致的假失败）', () async {
      await context.createProfile();

      // 真机上第二次连接同一台设备曾报
      // `UNIQUE constraint failed: recent_devices.udid`：
      // upsert 的冲突目标写的是主键 id，而真正冲突的是 udid 唯一索引。
      final first = await context.service.rememberLastDevice(
        'redroid:5555',
        displayName: 'redroid',
      );
      final second = await context.service.rememberLastDevice(
        'redroid:5555',
        displayName: 'redroid',
      );

      expect(first.isSuccess, isTrue);
      expect(second.isSuccess, isTrue, reason: second.error?.message);
      expect(await context.recentDevices.listRecentUdis(), <String>[
        'redroid:5555',
      ]);
    });

    test('没有 active 配置时仍记录最近设备，不报错', () async {
      final result = await context.service.rememberLastDevice('x:1');
      expect(result.isSuccess, isTrue);
      expect(await context.recentDevices.listRecentUdis(), <String>['x:1']);
    });

    test('空序列号被校验拦下', () async {
      final result = await context.service.rememberLastDevice('');
      expect(result.isError, isTrue);
    });
  });

  group('密码：明文随配置一起落库', () {
    test('新建配置时密码写进 connection_profiles.password', () async {
      final id = await context.createProfile(password: 'p@ss');

      final rows = await context.database
          .select(context.database.connectionProfiles)
          .get();
      expect(rows.single.id, id);
      expect(rows.single.password, 'p@ss');

      // drift 默认把 Dart 字段名转成 snake_case 作为 SQL 列名
      final columnNames = context.database.connectionProfiles.$columns
          .map((column) => column.name)
          .toList();
      expect(columnNames, contains('password'));
      expect(
        columnNames,
        containsAll(<String>[
          'server_url',
          'username',
          'last_udid',
          'is_active',
          'keep_screen_on',
        ]),
      );
    });

    test('load 能把密码读回来（重启后依然可用）', () async {
      await context.createProfile(password: 'p@ss');

      final loaded = (await context.service.load()).data!;

      expect(loaded.password, 'p@ss');
      expect(loaded.hasBasicAuth, isTrue);
    });

    test('saveAndLoad 更新密码', () async {
      await context.createProfile(password: 'old');

      final updated =
          (await context.service.saveAndLoad(settingsDto(password: 'new'))).data!;

      expect(updated.password, 'new');
      expect((await context.service.load()).data!.password, 'new');
    });

    test('清空密码会把它从记录里抹掉', () async {
      final id = await context.createProfile(password: 'p@ss');

      await context.service.save(settingsDto(username: '', password: ''));

      final rows = await context.database
          .select(context.database.connectionProfiles)
          .get();
      expect(rows.single.id, id);
      expect(rows.single.password, isEmpty);
      expect((await context.service.load()).data!.password, isEmpty);
    });

    test('删除配置会连密码一起删（同一条记录）', () async {
      final id = await context.createProfile(password: 'p@ss');

      expect((await context.service.deleteProfile(id)).isSuccess, isTrue);

      expect(
        await context.database.select(context.database.connectionProfiles).get(),
        isEmpty,
      );
    });
  });
}
