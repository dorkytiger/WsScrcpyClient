import 'package:drift/drift.dart';
import 'package:ws_scrcpy_client/core/database/database_executor.dart';

part 'app_database.g.dart';

/// 连接配置（profile）表：一套"服务端 + 凭据 + 偏好"的组合。
///
/// **密码明文入库**（2026-10-07 用户的决定："flutter_secure_storage 不要了，明文存就行"）。
/// 此前密码走 `flutter_secure_storage`，但它有两个持续的成本：
/// ① macOS 上需要 data protection keychain 授权（`-34018`，见 AGENTS §16.1）；
/// ② 它不支持 Swift Package Manager → 会把 iOS/macOS 整个工程拖回去用 CocoaPods（§3.3）。
/// **代价**：能读到应用数据目录的人就能看到密码 —— 私有服务端自用可接受。
/// 将来若要重新加密，只要换掉这一列的读写（[ProfileLocalDatasource] 是唯一入口）。
class ConnectionProfiles extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 展示名；为空时由 service 用服务地址的 host 兜底。
  TextColumn get name => text().withDefault(const Constant(''))();

  /// 服务端入口（http/https）。
  TextColumn get serverUrl => text()();

  /// Basic Auth 用户名；服务端未开鉴权时为空串。
  TextColumn get username => text().withDefault(const Constant(''))();

  /// Basic Auth 密码（**明文**，见类文档）。
  TextColumn get password => text().withDefault(const Constant(''))();

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
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
    },
    // v1 → v2：密码从"系统安全存储"搬进 `connection_profiles.password`。
    // 老库里的密码搬不过来（安全存储里的密文没动），用户重填一次即可 ——
    // 但**必须补列**，否则老库会因 schema 与代码不一致而打不开。
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) {
        await m.addColumn(connectionProfiles, connectionProfiles.password);
      }
    },
  );

  /// 生产环境的连接：**按平台分派**（原生落文件 / web 走 WASM）。
  ///
  /// 具体实现见 [openAppDatabaseExecutor]（`database_executor.dart` 的条件导出）——
  /// 这里刻意不 import `dart:io`：它在本文件被 web 复用时只是一份"一调用就抛"的桩，
  /// 而 `open()` 是在**启动路径**上跑的，踩到就是整个 App 白屏。
  static AppDatabase open() {
    return AppDatabase(openAppDatabaseExecutor());
  }
}
