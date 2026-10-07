import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/platform/platform_capabilities.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/feature/settings/application/repository/settings_repository.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/dto/save_settings_dto.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/entity/settings_profile_entity.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/vo/app_settings_vo.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/vo/settings_profile_vo.dart';

/// 设置用例：校验入参、决定"保存到哪套配置"、把多套配置的存储编排成 Result。
///
/// 构造需要一个 [SettingsRepository]（组合 profile 表 / 最近设备表 / 安全存储）。
/// 密码只在安全存储里，写失败会降级为"仅本次会话有效"，
/// 具体状态通过 [AppSettingsVo.passwordPersisted] 暴露给 UI。
class SettingsService {
  /// [isWeb] 只给测试用（VM 里 `isWebPlatform` 恒为 false，验不了 web 分支）；
  /// 生产代码不传，取编译期常量。
  SettingsService(this._repository, {AppLogger? logger, bool? isWeb})
    : _logger = logger ?? AppLogger('SettingsService'),
      _isWeb = isWeb ?? isWebPlatform;

  final SettingsRepository _repository;
  final AppLogger _logger;
  final bool _isWeb;

  /// 出厂默认设置。
  static const AppSettingsVo defaults = AppSettingsVo(
    serverUrl: AppDefaults.serverUrl,
    username: '',
    password: '',
    lastUdid: null,
    keepScreenOn: true,
  );

  /// 读取当前生效配置（含密码）。
  ///
  /// 还没有任何配置时返回 [defaults]（`profileId` 为 null），
  /// UI 据此走"首次进入"引导。
  Future<Result<AppSettingsVo>> load() async {
    final active = await _repository.findActiveProfile();
    if (active.isError) {
      return Result.failure(active.error!);
    }
    final profile = active.data;
    if (profile == null) {
      return Result.success(defaults);
    }
    return _toSettingsVo(profile);
  }

  /// 保存到当前生效配置；没有 active 配置时**新建一套并置为 active**。
  ///
  /// [SaveSettingsDto.id] 非空时保存到指定配置。
  /// 密码未持久化不属于失败：返回值仍是成功，状态见随后 [load] 的
  /// `passwordPersisted`（或直接用 [saveAndLoad]）。
  Future<Result<void>> save(SaveSettingsDto dto) async {
    final normalized = _normalize(dto);
    if (normalized.isError) {
      return Result.failure(normalized.error!);
    }
    final prepared = normalized.data!;

    // 显式指定 id → 直接更新该配置。
    if (prepared.id != null) {
      return _repository.updateProfile(prepared.id!, prepared);
    }

    final active = await _repository.findActiveProfile();
    if (active.isError) {
      return Result.failure(active.error!);
    }
    final profile = active.data;
    if (profile == null) {
      final created = await _repository.createProfile(prepared);
      if (created.isError) {
        return Result.failure(created.error!);
      }
      _logger.info('已创建并激活连接配置：id=${created.data}');
      return successVoid();
    }
    final updated = await _repository.updateProfile(profile.id, prepared);
    if (updated.isError) {
      return Result.failure(updated.error!);
    }
    _logger.info('已保存到连接配置：id=${profile.id}');
    return successVoid();
  }

  /// 保存后立刻回读：UI 一次调用即可拿到含 `passwordPersisted` 的最新状态。
  Future<Result<AppSettingsVo>> saveAndLoad(SaveSettingsDto dto) async {
    final saved = await save(dto);
    if (saved.isError) {
      return Result.failure(saved.error!);
    }
    return load();
  }

  /// 记住上次使用的设备（更新 active 配置的 `lastUdid` + 最近设备表）。
  Future<Result<void>> rememberLastDevice(
    String udid, {
    String? displayName,
  }) async {
    if (udid.isEmpty) {
      return Result.failure(const ValidationException(message: '设备序列号不能为空'));
    }
    return _repository.rememberLastDevice(udid: udid, displayName: displayName);
  }

  /// 是否已经存在任何连接配置（"首次进入"判定）。
  Future<Result<bool>> hasAnyProfile() => _repository.hasAnyProfile();

  /// 全部配置（按最近更新倒序）。
  Future<Result<List<SettingsProfileVo>>> listProfiles() async {
    final result = await _repository.listProfiles();
    if (result.isError) {
      return Result.failure(result.error!);
    }
    return Result.success(
      result.data!.map(SettingsProfileVo.fromEntity).toList(growable: false),
    );
  }

  /// 新建配置并置为 active，返回新配置 id。
  Future<Result<int>> createProfile(SaveSettingsDto dto) async {
    final normalized = _normalize(dto);
    if (normalized.isError) {
      return Result.failure(normalized.error!);
    }
    return _repository.createProfile(normalized.data!);
  }

  /// 切换生效配置。
  Future<Result<void>> activateProfile(int id) async {
    if (id <= 0) {
      return Result.failure(const ValidationException(message: '配置 id 不合法'));
    }
    return _repository.activateProfile(id);
  }

  /// 删除配置（连同它的密码）。
  ///
  /// 删除的是 active 配置时，仓储会在同一事务里把**最近更新**的一条剩余配置
  /// 提升为 active；没有剩余配置就不存在 active，[hasAnyProfile] 随即返回 false。
  Future<Result<void>> deleteProfile(int id) async {
    if (id <= 0) {
      return Result.failure(const ValidationException(message: '配置 id 不合法'));
    }
    final deleted = await _repository.deleteProfile(id);
    if (deleted.isError) {
      return Result.failure(deleted.error!);
    }
    if (deleted.data ?? false) {
      _logger.info('已删除当前生效配置：id=$id，若仍有其它配置则已自动切换');
    }
    return successVoid();
  }

  /// 组装 VO（含密码与其持久化状态）。
  Future<Result<AppSettingsVo>> _toSettingsVo(
    SettingsProfileEntity profile,
  ) async {
    final passwordResult = await _repository.readPassword(profile.id);
    if (passwordResult.isError) {
      return Result.failure(passwordResult.error!);
    }
    final password = passwordResult.data ?? '';
    var passwordPersisted = true;
    if (password.isNotEmpty) {
      final sessionOnly = await _repository.hasSessionOnlyPassword(profile.id);
      if (sessionOnly.isError) {
        return Result.failure(sessionOnly.error!);
      }
      passwordPersisted = !(sessionOnly.data ?? false);
      if (!passwordPersisted) {
        _logger.warn('密码仅本次会话有效（安全存储不可写）：profileId=${profile.id}');
      }
    }
    return Result.success(
      AppSettingsVo(
        serverUrl: profile.serverUrl,
        username: profile.username,
        password: password,
        lastUdid: profile.lastUdid,
        keepScreenOn: profile.keepScreenOn,
        profileId: profile.id,
        profileName: profile.name.isEmpty
            ? _hostOf(profile.serverUrl)
            : profile.name,
        passwordPersisted: passwordPersisted,
      ),
    );
  }

  /// 校验并规整入参：返回可直接落库的 DTO（名称已补默认值、字段已 trim）。
  Result<SaveSettingsDto> _normalize(SaveSettingsDto dto) {
    final serverUrl = dto.serverUrl.trim();
    final username = dto.username.trim();
    final validation = _validate(serverUrl, username, dto.password);
    if (validation != null) {
      return Result.failure(validation);
    }
    final name = (dto.name ?? '').trim();
    return Result.success(
      SaveSettingsDto(
        serverUrl: serverUrl,
        username: username,
        password: dto.password,
        keepScreenOn: dto.keepScreenOn,
        name: name.isEmpty ? _hostOf(serverUrl) : name,
        id: dto.id,
      ),
    );
  }

  /// 从服务地址取展示名（兜底规则：host）。
  String _hostOf(String serverUrl) {
    final host = Uri.tryParse(serverUrl)?.host ?? '';
    return host.isEmpty ? serverUrl : host;
  }

  /// 校验服务地址与凭据，返回 null 表示通过。
  GlobalException? _validate(
    String serverUrl,
    String username,
    String password,
  ) {
    final uri = Uri.tryParse(serverUrl);
    if (uri == null || uri.host.isEmpty) {
      return const ValidationException(
        message: '服务地址不合法，示例：https://android.dorkytiger.top/',
      );
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return const ValidationException(
        message: '服务地址必须以 http:// 或 https:// 开头',
      );
    }
    // 服务端要么不开鉴权，要么账号密码成对填写；只填一个几乎必然是笔误。
    //
    // **web 例外**（2026-10-07 用户实测："你这不是自相矛盾了吗"）：
    // web 上密码框是**故意隐藏**的——浏览器不给 WebSocket 加自定义请求头，凭据由浏览器
    // 在 Basic Auth 挑战里代管（见 AGENTS §9.3）。所以"只填账号"在 web 上是**正常状态**，
    // 按笔误拒绝就会出现"表单说密码不用填、保存却说你没填密码"这种自相矛盾。
    // 反方向（填了密码却没账号）两边都是笔误：多半是把账号填进了密码框。
    final hasUsername = username.trim().isNotEmpty;
    final hasPassword = password.isNotEmpty;
    if (hasPassword && !hasUsername) {
      return const ValidationException(message: 'Basic Auth 的账号与密码需要同时填写');
    }
    if (!_isWeb && hasUsername && !hasPassword) {
      return const ValidationException(message: 'Basic Auth 的账号与密码需要同时填写');
    }
    return null;
  }
}
