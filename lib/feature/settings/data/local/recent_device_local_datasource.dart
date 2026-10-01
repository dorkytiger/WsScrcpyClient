import 'package:drift/drift.dart';
import 'package:ws_scrcpy_client/core/database/app_database.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';

/// `recent_devices` 表的数据边界（"最近连接过的设备"）。
///
/// 与 profile 表分开成两个 datasource：它服务的是"最近设备"这个聚合根，
/// 生命周期与连接配置无关（切换 profile 也要保留最近设备列表）。
class RecentDeviceLocalDatasource {
  RecentDeviceLocalDatasource(this._database);

  final AppDatabase _database;
  final AppLogger _logger = AppLogger('RecentDeviceLocalDatasource');

  /// 记录一次成功连接：同一 udid 覆盖（`udid` 上有唯一约束），刷新最后连接时间。
  ///
  /// 冲突目标必须显式写成 `udid`：`insertOnConflictUpdate` 默认按**主键 id** 处理冲突，
  /// 而这里真正会撞的是 `udid` 的唯一索引，否则第二次连接同一台设备会直接
  /// `UNIQUE constraint failed: recent_devices.udid`（真机上已复现）。
  Future<void> upsert({
    required String udid,
    required String displayName,
    DateTime? connectedAt,
  }) async {
    try {
      await _database
          .into(_database.recentDevices)
          .insert(
            RecentDevicesCompanion.insert(
              udid: udid,
              displayName: Value(displayName),
              lastConnectedAt: connectedAt ?? DateTime.now(),
            ),
            onConflict: DoUpdate(
              (_) => RecentDevicesCompanion(
                displayName: Value(displayName),
                lastConnectedAt: Value(connectedAt ?? DateTime.now()),
              ),
              target: <Column<Object>>[_database.recentDevices.udid],
            ),
          );
    } catch (error, stackTrace) {
      _logger.error('写入最近设备失败', error, stackTrace);
      throw LocalStorageException(
        message: '写入最近设备失败：$error',
        exception: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 最近连接的设备序列号，按最后连接时间倒序。
  Future<List<String>> listRecentUdis({int limit = 10}) async {
    try {
      final query = _database.select(_database.recentDevices)
        ..orderBy(<OrderClauseGenerator<$RecentDevicesTable>>[
          ($RecentDevicesTable table) => OrderingTerm(
            expression: table.lastConnectedAt,
            mode: OrderingMode.desc,
          ),
        ])
        ..limit(limit);
      final rows = await query.get();
      return rows.map((RecentDevice row) => row.udid).toList(growable: false);
    } catch (error, stackTrace) {
      _logger.error('读取最近设备失败', error, stackTrace);
      throw LocalStorageException(
        message: '读取最近设备失败：$error',
        exception: error,
        stackTrace: stackTrace,
      );
    }
  }
}
