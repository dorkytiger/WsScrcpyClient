import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/database/app_database.dart';

void main() {
  group('AppDatabase 结构', () {
    late AppDatabase database;

    setUp(() {
      database = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() => database.close());

    test('包含 connection_profiles 与 recent_devices 两张表', () async {
      final tables = await database
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
          )
          .get();
      final names = tables
          .map((row) => row.read<String>('name'))
          .toList(growable: false);
      expect(names, contains('connection_profiles'));
      expect(names, contains('recent_devices'));
    });

    test('recent_devices.udid 有唯一约束（同一设备只留一条）', () async {
      Future<void> insert(String udid) => database
          .into(database.recentDevices)
          .insert(
            RecentDevicesCompanion.insert(
              udid: udid,
              displayName: const Value('x'),
              lastConnectedAt: DateTime.now(),
            ),
          );

      await insert('a:1');
      await expectLater(insert('a:1'), throwsA(isA<Exception>()));

      final rows = await database.select(database.recentDevices).get();
      expect(rows, hasLength(1));
    });

    test('schemaVersion 为 1 且能建表（onCreate 走通）', () async {
      expect(database.schemaVersion, 1);
      // 能查就说明 onCreate 的 createAll 成功执行了。
      expect(await database.select(database.connectionProfiles).get(), isEmpty);
    });
  });

  group('数据目录解析', () {
    test('WS_DATA_DIR 非空时必须使用它，并自动创建目录', () async {
      final override = AppDatabase.dataDirDefine;
      if (override.isEmpty) {
        // 该断言依赖编译期常量，未传 --dart-define 时跳过（见报告里的执行命令）。
        markTestSkipped('未设置 --dart-define=WS_DATA_DIR');
        return;
      }

      final directory = await AppDatabase.resolveDataDirectory();
      final file = await AppDatabase.resolveDatabaseFile();

      expect(directory.path, override);
      expect(await directory.exists(), isTrue);
      expect(file.path, '${directory.path}/${AppDatabase.databaseFileName}');
      expect(AppDatabase.databaseFileName, 'ws_scrcpy_client.sqlite');
    });
  });
}
