import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ws_scrcpy_client/core/database/app_database.dart';

/// 原生平台（Android / iOS / Windows / macOS / Linux）：落一个真实的 SQLite 文件。
///
/// 目录优先级：编译期 `WS_DATA_DIR` > `getApplicationSupportDirectory()`。
QueryExecutor openAppDatabaseExecutor() => driftDatabase(
  name: AppDatabase.databaseName,
  native: DriftNativeOptions(
    databasePath: () async => (await resolveDatabaseFile()).path,
  ),
);

/// 解析数据库文件路径（目录不存在时创建）。
Future<File> resolveDatabaseFile() async {
  final directory = await resolveDataDirectory();
  return File('${directory.path}/${AppDatabase.databaseFileName}');
}

/// 解析数据目录：`WS_DATA_DIR` 优先，其次应用支持目录。
Future<Directory> resolveDataDirectory() async {
  final override = AppDatabase.dataDirDefine.trim();
  if (override.isNotEmpty) {
    return _ensureDirectory(Directory(override));
  }
  final supportDirectory = await getApplicationSupportDirectory();
  return _ensureDirectory(supportDirectory);
}

Future<Directory> _ensureDirectory(Directory directory) async {
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory;
}
