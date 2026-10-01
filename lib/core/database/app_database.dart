import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

/// 连接配置（profile）表：一套"服务端 + 凭据 + 偏好"的组合。
///
/// 密码**不入库**（见 `SecretLocalDatasource`），因此这里没有 password 列。
class ConnectionProfiles extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 展示名；为空时由 service 用服务地址的 host 兜底。
  TextColumn get name => text().withDefault(const Constant(''))();

  /// 服务端入口（http/https）。
  TextColumn get serverUrl => text()();

  /// Basic Auth 用户名；服务端未开鉴权时为空串。
  TextColumn get username => text().withDefault(const Constant(''))();

  /// 投流/操作期间是否保持屏幕常亮。
  BoolColumn get keepScreenOn => boolean().withDefault(const Constant(true))();

  /// 该配置下上次使用的设备序列号。
  TextColumn get lastUdid => text().nullable()();

  /// 是否为当前生效配置；**全局最多一个为 true**，由 repository 用事务保证。
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}

/// 最近连接过的设备（跨 profile 共享的"最近使用"列表）。
class RecentDevices extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 设备序列号，唯一：同一台设备只保留一条记录（重连时更新时间）。
  TextColumn get udid => text().unique()();

  TextColumn get displayName => text().withDefault(const Constant(''))();

  DateTimeColumn get lastConnectedAt => dateTime()();
}

/// 应用数据库（drift/SQLite）。
///
/// 打开方式有两种：
/// - 生产：`AppDatabase.open()`，路径优先取编译期常量 `WS_DATA_DIR`，
///   为空时用 path_provider 的应用支持目录；
/// - 测试：`AppDatabase(NativeDatabase.memory())`，不触碰平台通道。
@DriftDatabase(tables: <Type>[ConnectionProfiles, RecentDevices])
class AppDatabase extends _$AppDatabase {
  /// 注入式构造：测试传 `NativeDatabase.memory()`，生产由 [open] 构造。
  // 生成的父类构造参数名是 `e`；改成 super 参数会让公开签名显示成 `e`，这里保留可读名。
  // ignore: use_super_parameters
  AppDatabase(QueryExecutor executor) : super(executor);

  /// 数据库文件名（固定；位置见 [resolveDataDirectory]）。
  static const String databaseFileName = 'ws_scrcpy_client.sqlite';

  /// drift 用于后台 isolate 端口映射的逻辑名（与文件名分开，避免平台差异）。
  static const String databaseName = 'ws_scrcpy_client';

  /// 编译期覆盖的数据目录（`--dart-define=WS_DATA_DIR=<绝对路径>`）。
  ///
  /// 为什么需要它：受限环境（沙箱 / 受限令牌）里 `%APPDATA%` 不可写，
  /// 把目录指到工作区后 App 才能正常落盘。
  static const String dataDirDefine = String.fromEnvironment('WS_DATA_DIR');

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
    },
  );

  /// 生产环境的连接：交给 `drift_flutter` 处理平台差异（后台 isolate / 原生库加载）。
  ///
  /// 显式提供 `databasePath`，因此文件位置完全由 [resolveDatabaseFile] 决定；
  /// `name` 只用于多个 isolate 打开同一库时的端口映射。
  static AppDatabase open() {
    return AppDatabase(
      driftDatabase(
        name: databaseName,
        native: DriftNativeOptions(
          databasePath: () async => (await resolveDatabaseFile()).path,
        ),
      ),
    );
  }

  /// 解析数据库文件路径（目录不存在时创建）。
  static Future<File> resolveDatabaseFile() async {
    final directory = await resolveDataDirectory();
    return File('${directory.path}/$databaseFileName');
  }

  /// 解析数据目录：`WS_DATA_DIR` 优先，其次应用支持目录。
  static Future<Directory> resolveDataDirectory() async {
    final override = dataDirDefine.trim();
    if (override.isNotEmpty) {
      return _ensureDirectory(Directory(override));
    }
    final supportDirectory = await getApplicationSupportDirectory();
    return _ensureDirectory(supportDirectory);
  }

  static Future<Directory> _ensureDirectory(Directory directory) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }
}
