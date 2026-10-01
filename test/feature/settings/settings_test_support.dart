import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/database/app_database.dart';
import 'package:ws_scrcpy_client/feature/settings/application/repository/settings_repository.dart';
import 'package:ws_scrcpy_client/feature/settings/application/service/settings_service.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/profile_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/recent_device_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/secret_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/dto/save_settings_dto.dart';

/// 内存数据库：走真实 SQLite，因此表约束（唯一索引等）与 SQL 语义都被真实执行。
AppDatabase createMemoryDatabase() => AppDatabase(NativeDatabase.memory());

/// 假的安全存储：只覆写底层三个钩子，降级逻辑仍跑真实实现。
///
/// [failReads] / [failWrites] / [failDeletes] 用来模拟受限环境里
/// `flutter_secure_storage` 抛异常的情况。
class FakeSecretLocalDatasource extends SecretLocalDatasource {
  FakeSecretLocalDatasource({
    this.failReads = false,
    this.failWrites = false,
    this.failDeletes = false,
  }) : super(const FlutterSecureStorage());

  final Map<int, String> stored = <int, String>{};

  bool failReads;
  bool failWrites;
  bool failDeletes;

  @override
  Future<String?> loadPassword(int profileId) async {
    if (failReads) {
      throw StateError('模拟安全存储读取失败');
    }
    return stored[profileId];
  }

  @override
  Future<void> persistPassword(int profileId, String password) async {
    if (failWrites) {
      throw StateError('模拟安全存储写入失败');
    }
    stored[profileId] = password;
  }

  @override
  Future<void> removePassword(int profileId) async {
    if (failDeletes) {
      throw StateError('模拟安全存储删除失败');
    }
    stored.remove(profileId);
  }
}

/// 测试用的一整套依赖。
class SettingsTestContext {
  SettingsTestContext({FakeSecretLocalDatasource? secrets})
    : secrets = secrets ?? FakeSecretLocalDatasource(),
      database = createMemoryDatabase() {
    profiles = ProfileLocalDatasource(database);
    recentDevices = RecentDeviceLocalDatasource(database);
    repository = SettingsRepository(profiles, recentDevices, this.secrets);
    service = SettingsService(repository);
  }

  final AppDatabase database;
  final FakeSecretLocalDatasource secrets;
  late final ProfileLocalDatasource profiles;
  late final RecentDeviceLocalDatasource recentDevices;
  late final SettingsRepository repository;
  late final SettingsService service;

  Future<void> dispose() => database.close();

  /// 建一套配置（走 service，保证与真实流程一致）。
  Future<int> createProfile({
    String serverUrl = 'https://android.dorkytiger.top/',
    String username = 'u',
    String password = 'p',
    bool keepScreenOn = true,
    String? name,
  }) async {
    final result = await service.createProfile(
      SaveSettingsDto(
        serverUrl: serverUrl,
        username: username,
        password: password,
        keepScreenOn: keepScreenOn,
        name: name,
      ),
    );
    if (result.isError) {
      throw StateError('测试准备失败：${result.error}');
    }
    return result.data!;
  }
}

/// 常用入参，减少每个用例里的样板。
SaveSettingsDto settingsDto({
  String serverUrl = 'https://android.dorkytiger.top/',
  String username = 'u',
  String password = 'p',
  bool keepScreenOn = true,
  String? name,
  int? id,
}) {
  return SaveSettingsDto(
    serverUrl: serverUrl,
    username: username,
    password: password,
    keepScreenOn: keepScreenOn,
    name: name,
    id: id,
  );
}

/// 断言"最多一个 active"。返回当前 active 的 id（没有则 null）。
Future<int?> singleActiveId(AppDatabase database) async {
  final rows = await database.select(database.connectionProfiles).get();
  final actives = rows.where((ConnectionProfile row) => row.isActive).toList();
  expect(
    actives.length,
    lessThanOrEqualTo(1),
    reason: 'connection_profiles 的 active 不变量被破坏：${actives.map((e) => e.id)}',
  );
  return actives.isEmpty ? null : actives.single.id;
}
