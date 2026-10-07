import 'package:drift/drift.dart';
import 'package:ws_scrcpy_client/core/database/app_database.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/entity/settings_profile_entity.dart';

/// `connection_profiles` 表的数据边界。
///
/// 只做这一张表的读写与它的表级不变量（**全局最多一个 active**），不掺业务校验。
/// 密码也在这张表里（**明文列**，见 [ConnectionProfiles] 的类文档）。
class ProfileLocalDatasource {
  ProfileLocalDatasource(this._database);

  final AppDatabase _database;
  final AppLogger _logger = AppLogger('ProfileLocalDatasource');

  /// 按"最近更新"倒序列出全部配置（UI 的 profile 列表用它）。
  Future<List<SettingsProfileEntity>> listProfiles() async {
    return _guard('读取连接配置列表失败', () async {
      final query = _database.select(_database.connectionProfiles)
        ..orderBy(<OrderClauseGenerator<$ConnectionProfilesTable>>[
          ($ConnectionProfilesTable table) => OrderingTerm(
            expression: table.updatedAt,
            mode: OrderingMode.desc,
          ),
          ($ConnectionProfilesTable table) =>
              OrderingTerm(expression: table.id, mode: OrderingMode.desc),
        ]);
      final rows = await query.get();
      return rows.map(_toEntity).toList(growable: false);
    });
  }

  /// 当前生效配置；没有任何 active 时返回 null。
  Future<SettingsProfileEntity?> findActive() async {
    return _guard('读取当前连接配置失败', () async {
      final query = _database.select(_database.connectionProfiles)
        ..where(($ConnectionProfilesTable table) => table.isActive.equals(true))
        ..limit(1);
      final row = await query.getSingleOrNull();
      return row == null ? null : _toEntity(row);
    });
  }

  /// 是否已经存在任何连接配置（"首次进入"判定的数据来源）。
  Future<bool> hasAny() async {
    return _guard('检查连接配置失败', () async {
      final count = _database.connectionProfiles.id.count();
      final query = _database.selectOnly(_database.connectionProfiles)
        ..addColumns(<Expression<Object>>[count]);
      final row = await query.getSingle();
      return (row.read(count) ?? 0) > 0;
    });
  }

  /// 按 id 查询。
  Future<SettingsProfileEntity?> findById(int id) async {
    return _guard('读取连接配置失败', () async {
      final query = _database.select(_database.connectionProfiles)
        ..where(($ConnectionProfilesTable table) => table.id.equals(id));
      final row = await query.getSingleOrNull();
      return row == null ? null : _toEntity(row);
    });
  }

  /// 新建配置。
  ///
  /// [makeActive] 为 true 时在**同一个事务**里清掉其它 active 再置位，
  /// 保证"最多一个 active"的表级不变量不被破坏。
  Future<int> insertProfile(
    SettingsProfileEntity draft, {
    required bool makeActive,
  }) async {
    return _guard('新建连接配置失败', () async {
      final now = DateTime.now();
      return _database.transaction(() async {
        if (makeActive) {
          await _clearActive();
        }
        return _database
            .into(_database.connectionProfiles)
            .insert(
              ConnectionProfilesCompanion.insert(
                name: Value(draft.name),
                serverUrl: draft.serverUrl,
                username: Value(draft.username),
                password: Value(draft.password),
                keepScreenOn: Value(draft.keepScreenOn),
                lastUdid: Value(draft.lastUdid),
                isActive: Value(makeActive),
                createdAt: now,
                updatedAt: now,
              ),
            );
      });
    });
  }

  /// 更新已存在配置的可编辑字段（不动 `createdAt`；刷新 `updatedAt`）。
  Future<void> updateProfile(SettingsProfileEntity profile) async {
    if (!profile.isStored) {
      throw const ValidationException(message: '更新连接配置时缺少 id');
    }
    return _guard('更新连接配置失败', () async {
      final affected =
          await (_database.update(_database.connectionProfiles)..where(
                ($ConnectionProfilesTable table) => table.id.equals(profile.id),
              ))
              .write(
                ConnectionProfilesCompanion(
                  name: Value(profile.name),
                  serverUrl: Value(profile.serverUrl),
                  username: Value(profile.username),
                  password: Value(profile.password),
                  keepScreenOn: Value(profile.keepScreenOn),
                  lastUdid: Value(profile.lastUdid),
                  updatedAt: Value(DateTime.now()),
                ),
              );
      if (affected == 0) {
        throw ValidationException(message: '连接配置不存在：id=${profile.id}');
      }
    });
  }

  /// 切换生效配置（事务内先清后置）。
  Future<void> activateProfile(int id) async {
    return _guard('切换连接配置失败', () async {
      await _database.transaction(() async {
        final exists =
            await (_database.selectOnly(_database.connectionProfiles)
                  ..addColumns(<Expression<Object>>[
                    _database.connectionProfiles.id,
                  ])
                  ..where(_database.connectionProfiles.id.equals(id)))
                .getSingleOrNull();
        if (exists == null) {
          throw ValidationException(message: '连接配置不存在：id=$id');
        }
        await _clearActive();
        await (_database.update(_database.connectionProfiles)
              ..where(($ConnectionProfilesTable table) => table.id.equals(id)))
            .write(
              ConnectionProfilesCompanion(
                isActive: const Value(true),
                updatedAt: Value(DateTime.now()),
              ),
            );
      });
    });
  }

  /// 删除配置，并在同一事务里维护 active 不变量。
  ///
  /// 回落规则：被删的是 active 时，把**最近更新**的一条剩余配置提升为 active；
  /// 没有剩余配置了，就不存在 active（上层据此走"首次进入"引导）。
  ///
  /// 返回被删的是否是 active（供上层记日志/决定提示）。
  Future<bool> deleteProfile(int id) async {
    return _guard('删除连接配置失败', () async {
      return _database.transaction(() async {
        final row =
            await (_database.select(_database.connectionProfiles)..where(
                  ($ConnectionProfilesTable table) => table.id.equals(id),
                ))
                .getSingleOrNull();
        if (row == null) {
          throw ValidationException(message: '连接配置不存在：id=$id');
        }
        await (_database.delete(
          _database.connectionProfiles,
        )..where(($ConnectionProfilesTable table) => table.id.equals(id))).go();
        if (!row.isActive) {
          return false;
        }
        final next =
            await (_database.select(_database.connectionProfiles)
                  ..orderBy(<OrderClauseGenerator<$ConnectionProfilesTable>>[
                    ($ConnectionProfilesTable table) => OrderingTerm(
                      expression: table.updatedAt,
                      mode: OrderingMode.desc,
                    ),
                    ($ConnectionProfilesTable table) => OrderingTerm(
                      expression: table.id,
                      mode: OrderingMode.desc,
                    ),
                  ])
                  ..limit(1))
                .getSingleOrNull();
        if (next != null) {
          await (_database.update(_database.connectionProfiles)..where(
                ($ConnectionProfilesTable table) => table.id.equals(next.id),
              ))
              .write(
                ConnectionProfilesCompanion(
                  isActive: const Value(true),
                  updatedAt: Value(DateTime.now()),
                ),
              );
        }
        return true;
      });
    });
  }

  /// 只更新"上次使用的设备"，避免保存设置时覆盖其它字段。
  Future<void> updateLastUdid({
    required int profileId,
    required String udid,
  }) async {
    return _guard('保存上次设备失败', () async {
      final affected =
          await (_database.update(_database.connectionProfiles)..where(
                ($ConnectionProfilesTable table) => table.id.equals(profileId),
              ))
              .write(
                ConnectionProfilesCompanion(
                  lastUdid: Value(udid),
                  updatedAt: Value(DateTime.now()),
                ),
              );
      if (affected == 0) {
        throw ValidationException(message: '连接配置不存在：id=$profileId');
      }
    });
  }

  Future<void> _clearActive() {
    return (_database.update(_database.connectionProfiles)..where(
          ($ConnectionProfilesTable table) => table.isActive.equals(true),
        ))
        .write(const ConnectionProfilesCompanion(isActive: Value(false)));
  }

  SettingsProfileEntity _toEntity(ConnectionProfile row) {
    return SettingsProfileEntity(
      id: row.id,
      name: row.name,
      serverUrl: row.serverUrl,
      username: row.username,
      password: row.password,
      keepScreenOn: row.keepScreenOn,
      lastUdid: row.lastUdid,
      isActive: row.isActive,
    );
  }

  /// 统一把底层数据库异常翻译成 [LocalStorageException]。
  ///
  /// [action] 里允许抛 [GlobalException]（例如 id 不存在），原样透传。
  Future<T> _guard<T>(String message, Future<T> Function() action) async {
    try {
      return await action();
    } on GlobalException {
      rethrow;
    } catch (error, stackTrace) {
      _logger.error(message, error, stackTrace);
      throw LocalStorageException(
        message: '$message：$error',
        exception: error,
        stackTrace: stackTrace,
      );
    }
  }
}
