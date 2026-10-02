/// 打开本地数据库的**平台分支**（条件导出）。
///
/// 为什么要拆：`dart:io` 在 web 上只是一份"能编译、一调用就抛"的桩，
/// 而 `AppDatabase.open()` 是在**启动路径**上被调用的（`AppDependencies.create()`），
/// 所以只要让 web 走到 `dart:io`，整个 App 就白屏 —— 这是 2026-10-02 实测到的第一道墙。
///
/// 拆法：`app_database.dart` 只留表定义与常量（纯 Dart），
/// 真正"怎么打开"交给这里按平台分派：
/// - 原生：`drift_flutter` + path_provider（`WS_DATA_DIR` 可覆盖目录）；
/// - web：drift 的 WASM 实现（`sqlite3.wasm` + `drift_worker.dart.js`，都放在 `web/`）。
///
/// **两端共用同一套表结构与同一份 drift DAO** —— 不写第二套存储或第二份业务逻辑。
library;

export 'database_executor_io.dart'
    if (dart.library.js_interop) 'database_executor_web.dart';
