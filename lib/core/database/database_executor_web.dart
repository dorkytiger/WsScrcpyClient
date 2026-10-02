import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:ws_scrcpy_client/core/database/app_database.dart';

/// web：走 drift 的 WASM 实现。
///
/// 两个资源都放在 `web/` 里（**随包发，不从 CDN 取**）：
/// - `sqlite3.wasm`：SQLite 的 WASM 构建；
/// - `drift_worker.dart.js`：drift 的 worker（用 `dart run drift_dev make-web-worker` 生成）。
///
/// 浏览器会按可用能力自动选后端（OPFS > IndexedDB > 内存），`onResult` 里能看到选了哪个 ——
/// 排查"刷新后配置丢了"时先看这一行。
QueryExecutor openAppDatabaseExecutor() => driftDatabase(
  name: AppDatabase.databaseName,
  web: DriftWebOptions(
    sqlite3Wasm: Uri.parse('sqlite3.wasm'),
    driftWorker: Uri.parse('drift_worker.js'),
    onResult: (WasmDatabaseResult result) {
      // ignore: avoid_print
      print('[WebDB] 打开方式=${result.chosenImplementation} '
          '缺失特性=${result.missingFeatures}');
    },
  ),
);
