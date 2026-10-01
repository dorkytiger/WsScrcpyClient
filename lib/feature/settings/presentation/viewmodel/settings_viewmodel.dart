import 'package:flutter/foundation.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';
import 'package:ws_scrcpy_client/feature/settings/application/service/settings_service.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/dto/save_settings_dto.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/vo/app_settings_vo.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/vo/settings_profile_vo.dart';

/// 设置视图模型：加载三态、保存 pending、配置（profile）列表与切换。
///
/// 业务校验与持久化都在 [SettingsService]，这里只维护展示状态与交互触发。
class SettingsViewModel extends ChangeNotifier {
  SettingsViewModel(this._service);

  final SettingsService _service;

  AsyncState<AppSettingsVo> _state = const AsyncLoading();
  List<SettingsProfileVo> _profiles = const <SettingsProfileVo>[];
  bool _isSaving = false;
  int? _busyProfileId;

  /// 是否已有任何配置：`null` 表示还在判定（首次进入的判定用它）。
  bool? _hasProfile;

  /// 设置加载三态。
  AsyncState<AppSettingsVo> get state => _state;

  /// 是否正在保存（保存按钮据此进入 pending 并禁用）。
  bool get isSaving => _isSaving;

  /// 是否已有配置；`false` 时应用应引导用户走初始化表单。
  bool? get hasProfile => _hasProfile;

  /// 全部配置（设置页展示、切换）。
  List<SettingsProfileVo> get profiles => _profiles;

  /// 正在切换/删除的配置 id（对应按钮 pending）。
  int? get busyProfileId => _busyProfileId;

  /// 加载设置 + 判定"是否已有配置" + 拉取配置列表。
  Future<void> load() async {
    _state = const AsyncLoading();
    notifyListeners();

    final hasProfileResult = await _service.hasAnyProfile();
    if (hasProfileResult.isError) {
      _state = AsyncFailure<AppSettingsVo>(hasProfileResult.error!);
      notifyListeners();
      return;
    }
    _hasProfile = hasProfileResult.data;

    final result = await _service.load();
    _state = result.isError
        ? AsyncFailure<AppSettingsVo>(result.error!)
        : AsyncSuccess<AppSettingsVo>(result.data!);

    if (_hasProfile ?? false) {
      final profilesResult = await _service.listProfiles();
      _profiles = profilesResult.isError
          ? const <SettingsProfileVo>[]
          : profilesResult.data!;
    } else {
      _profiles = const <SettingsProfileVo>[];
    }
    notifyListeners();
  }

  /// 保存到当前配置；成功/失败的 UI 反馈由 view 负责（viewmodel 不碰 context）。
  Future<Result<void>> save(SaveSettingsDto dto) async {
    if (_isSaving) {
      return Result.failure(const BusinessException(message: '正在保存，请稍候'));
    }
    _isSaving = true;
    notifyListeners();
    try {
      final result = await _service.save(dto);
      if (result.isSuccess) {
        await _reloadAfterMutation();
      }
      return result;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  /// 新建一套配置并置为当前（初始化表单与"新增配置"共用）。
  Future<Result<int>> createProfile(SaveSettingsDto dto) async {
    if (_isSaving) {
      return Result.failure(const BusinessException(message: '正在保存，请稍候'));
    }
    _isSaving = true;
    notifyListeners();
    try {
      final result = await _service.createProfile(dto);
      if (result.isSuccess) {
        await _reloadAfterMutation();
      }
      return result;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  /// 切换当前配置。
  Future<Result<void>> activateProfile(int id) async {
    if (_busyProfileId != null) {
      return Result.failure(const BusinessException(message: '正在处理，请稍候'));
    }
    _busyProfileId = id;
    notifyListeners();
    try {
      final result = await _service.activateProfile(id);
      if (result.isSuccess) {
        await _reloadAfterMutation();
      }
      return result;
    } finally {
      _busyProfileId = null;
      notifyListeners();
    }
  }

  /// 删除配置（调用方负责二次确认）。
  Future<Result<void>> deleteProfile(int id) async {
    if (_busyProfileId != null) {
      return Result.failure(const BusinessException(message: '正在处理，请稍候'));
    }
    _busyProfileId = id;
    notifyListeners();
    try {
      final result = await _service.deleteProfile(id);
      if (result.isSuccess) {
        await _reloadAfterMutation();
      }
      return result;
    } finally {
      _busyProfileId = null;
      notifyListeners();
    }
  }

  /// 变更后刷新列表与当前设置（不在变更过程中重置 pending 标记）。
  Future<void> _reloadAfterMutation() async {
    final settingsResult = await _service.load();
    if (settingsResult.isSuccess) {
      _state = AsyncSuccess<AppSettingsVo>(settingsResult.data!);
    }
    final profilesResult = await _service.listProfiles();
    if (profilesResult.isSuccess) {
      _profiles = profilesResult.data!;
      _hasProfile = _profiles.isNotEmpty;
    }
  }
}
