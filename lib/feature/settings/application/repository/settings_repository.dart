import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/profile_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/recent_device_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/secret_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/dto/save_settings_dto.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/entity/settings_profile_entity.dart';

/// 连接配置的仓储：把"配置表 / 最近设备表 / 安全存储"三个数据源编排起来，
/// 并在这一层统一把异常翻译成 `Result`（上层不再接触裸异常）。
class SettingsRepository {
  SettingsRepository(
    this._profiles,
    this._recentDevices,
    this._secrets, {
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger('SettingsRepository');

  final ProfileLocalDatasource _profiles;
  final RecentDeviceLocalDatasource _recentDevices;
  final SecretLocalDatasource _secrets;
  final AppLogger _logger;

  /// 全部配置，按最近更新倒序。
  Future<Result<List<SettingsProfileEntity>>> listProfiles() =>
      _guard('读取连接配置列表失败', _profiles.listProfiles);

  /// 当前生效配置（没有则为 null）。
  Future<Result<SettingsProfileEntity?>> findActiveProfile() =>
      _guard('读取当前连接配置失败', _profiles.findActive);

  /// 按 id 查询配置。
  Future<Result<SettingsProfileEntity?>> findProfile(int id) =>
      _guard('读取连接配置失败', () => _profiles.findById(id));

  /// 是否已有任何配置（"首次进入"判定）。
  Future<Result<bool>> hasAnyProfile() => _guard('检查连接配置失败', _profiles.hasAny);

  /// 新建配置并置为 active，同时写入密码；返回新配置 id。
  ///
  /// 注意顺序：先落库再写密码——密码写失败只降级（返回 sessionOnly），
  /// 不会留下"有密码但没配置"的孤儿数据。
  Future<Result<int>> createProfile(SaveSettingsDto dto) async {
    final draft = SettingsProfileEntity.draft(
      name: dto.name ?? '',
      serverUrl: dto.serverUrl,
      username: dto.username,
      keepScreenOn: dto.keepScreenOn,
    );
    final created = await _guard(
      '新建连接配置失败',
      () => _profiles.insertProfile(draft, makeActive: true),
    );
    if (created.isError) {
      return Result.failure(created.error!);
    }
    final id = created.data!;
    final secret = await writePassword(id, dto.password);
    if (secret.isError) {
      // 配置已经建好，只是密码没落盘：把降级结果如实返回，避免上层误判为完全失败。
      return Result.failure(secret.error!);
    }
    _logger.info('新建连接配置成功：id=$id');
    return Result.success(id);
  }

  /// 更新指定配置，并同步密码。
  Future<Result<void>> updateProfile(int id, SaveSettingsDto dto) async {
    final existing = await findProfile(id);
    if (existing.isError) {
      return Result.failure(existing.error!);
    }
    final profile = existing.data;
    if (profile == null) {
      return Result.failure(ValidationException(message: '连接配置不存在：id=$id'));
    }
    final updated = await _guard(
      '更新连接配置失败',
      () => _profiles.updateProfile(
        profile.copyWith(
          name: dto.name ?? profile.name,
          serverUrl: dto.serverUrl,
          username: dto.username,
          keepScreenOn: dto.keepScreenOn,
        ),
      ),
    );
    if (updated.isError) {
      return Result.failure(updated.error!);
    }
    final secret = await writePassword(id, dto.password);
    if (secret.isError) {
      return Result.failure(secret.error!);
    }
    return successVoid();
  }

  /// 切换生效配置。
  Future<Result<void>> activateProfile(int id) =>
      _guard('切换连接配置失败', () => _profiles.activateProfile(id));

  /// 删除配置：先删库（含 active 回落），再删对应密码。
  ///
  /// 密码删除失败不影响整体成功（配置已经没了，残留密文无害），只记日志。
  Future<Result<bool>> deleteProfile(int id) async {
    final deleted = await _guard('删除连接配置失败', () => _profiles.deleteProfile(id));
    if (deleted.isError) {
      return Result.failure(deleted.error!);
    }
    final removed = await _secrets.delete(id);
    if (!removed) {
      _logger.warn('配置已删除，但其密码未能从安全存储清除：profileId=$id');
    }
    return Result.success(deleted.data!);
  }

  /// 记录"上次使用的设备"：更新 active 配置的 lastUdid + 写最近设备表。
  ///
  /// 没有 active 配置时只写最近设备表（首次引导期间也可能先记住设备）。
  Future<Result<void>> rememberLastDevice({
    required String udid,
    String? displayName,
  }) async {
    final recent = await _guard(
      '写入最近设备失败',
      () => _recentDevices.upsert(udid: udid, displayName: displayName ?? udid),
    );
    if (recent.isError) {
      return Result.failure(recent.error!);
    }
    final active = await findActiveProfile();
    if (active.isError) {
      return Result.failure(active.error!);
    }
    final profile = active.data;
    if (profile == null) {
      return successVoid();
    }
    return _guard(
      '保存上次设备失败',
      () => _profiles.updateLastUdid(profileId: profile.id, udid: udid),
    );
  }

  /// 读取指定配置的密码：先看安全存储，再看"仅本次会话"的兜底。
  Future<Result<String?>> readPassword(int profileId) async {
    final persisted = await _secrets.readPersisted(profileId);
    if (persisted != null) {
      return Result.success(persisted);
    }
    return Result.success(_secrets.readSessionOnly(profileId));
  }

  /// 指定配置的密码是否只存在于内存（安全存储写失败后的降级状态）。
  Future<Result<bool>> hasSessionOnlyPassword(int profileId) async {
    return Result.success(_secrets.readSessionOnly(profileId) != null);
  }

  /// 写入指定配置的密码（可能降级为"仅本次会话有效"）。
  Future<Result<SecretWriteOutcome>> writePassword(
    int profileId,
    String password,
  ) async {
    try {
      return Result.success(await _secrets.write(profileId, password));
    } catch (error, stackTrace) {
      _logger.error('写入密码失败', error, stackTrace);
      return Result.failure(
        LocalStorageException(
          message: '写入密码失败：$error',
          exception: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  /// 统一异常 → `Result` 翻译（[GlobalException] 原样透传）。
  Future<Result<T>> _guard<T>(
    String message,
    Future<T> Function() action,
  ) async {
    try {
      return Result.success(await action());
    } on GlobalException catch (error) {
      return Result.failure(error);
    } catch (error, stackTrace) {
      _logger.error(message, error, stackTrace);
      return Result.failure(
        LocalStorageException(
          message: '$message：$error',
          exception: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }
}
