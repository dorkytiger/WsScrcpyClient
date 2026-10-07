import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/database/app_database.dart';
import 'package:ws_scrcpy_client/feature/settings/application/repository/settings_repository.dart';
import 'package:ws_scrcpy_client/feature/settings/application/service/settings_service.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/profile_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/recent_device_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/dto/save_settings_dto.dart';

/// 内存数据库：走真实 SQLite，因此表约束（唯一索引等）与 SQL 语义都被真实执行。
AppDatabase createMemoryDatabase() => AppDatabase(NativeDatabase.memory());

/// 测试用的一整套依赖。
class SettingsTestContext {
  SettingsTestContext({bool? isWeb}) : database = createMemoryDatabase() {
    profiles = ProfileLocalDatasource(database);
    recentDevices = RecentDeviceLocalDatasource(database);
    repository = SettingsRepository(profiles, recentDevices);
    service = SettingsService(repository, isWeb: isWeb);
  }

  final AppDatabase database;
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
