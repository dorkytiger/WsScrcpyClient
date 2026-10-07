import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ws_scrcpy_client/core/database/app_database.dart';
import 'package:ws_scrcpy_client/feature/device/application/service/device_list_service.dart';
import 'package:ws_scrcpy_client/feature/device/data/remote/device_list_remote_datasource.dart';
import 'package:ws_scrcpy_client/feature/device/presentation/viewmodel/device_list_viewmodel.dart';
import 'package:ws_scrcpy_client/feature/settings/application/repository/settings_repository.dart';
import 'package:ws_scrcpy_client/feature/settings/application/service/settings_service.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/profile_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/recent_device_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/data/local/secret_local_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/presentation/viewmodel/settings_viewmodel.dart';
import 'package:ws_scrcpy_client/feature/stream/application/service/stream_session_service.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/stream_remote_datasource.dart';

/// 应用唯一的安全存储实例（只存密码）。
///
/// **macOS 必须显式关掉 data protection keychain**（`useDataProtectionKeyChain: false`），
/// 否则本机开发时写入**必定失败**：
///
/// ```
/// PlatformException(Unexpected security result code, Code: -34018,
///                   Message: A required entitlement is not present.)
/// ```
///
/// **根因**（2026-10-07 本机实测，见 AGENTS.md §9.2）：`flutter_secure_storage_macos` 9.x
/// 默认把 `kSecUseDataProtectionKeychain` 置为 `true`，而**数据保护钥匙串要求进程带
/// `keychain-access-groups` / `com.apple.application-identifier` 授权**——这两样只能由
/// provisioning profile 提供。Flutter 的 macOS 模板把 Runner 设成
/// `CODE_SIGN_IDENTITY = "-"`（ad-hoc，实测 `TeamIdentifier=not set`），所以 `SecItemAdd`
/// 直接返回 `errSecMissingEntitlement`。退回**文件式（login）钥匙串**后一切正常：
/// 本机用"最小 .app + 同款 `app-sandbox` 授权 + ad-hoc 签名"的探针验证过，
/// `add / read / delete` 全部返回 0，而同进程改用数据保护钥匙串就是 -34018。
///
/// **代价**：ad-hoc 签名的 cdhash 每次重建都会变，钥匙串 ACL 因此在**重建之后**可能多问一次
/// 访问权限；用真实证书签名分发（Developer ID / App Store）时不存在这个提示。
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
  mOptions: MacOsOptions(useDataProtectionKeyChain: false),
);

/// 依赖装配（composition root）：所有 service / datasource / viewmodel 只在这里构造。
///
/// 业务代码禁止在方法体内临时 `new SomeService()`，一律从这里取。
class AppDependencies {
  AppDependencies._({
    required this.database,
    required this.settingsService,
    required this.deviceListService,
    required this.streamSessionService,
    required this.settingsViewModel,
    required this.deviceListViewModel,
  });

  /// 按真实运行依赖装配。
  factory AppDependencies.create() {
    // 数据库路径由 WS_DATA_DIR / 应用支持目录决定（见 AppDatabase.resolveDataDirectory）。
    final database = AppDatabase.open();
    final settingsService = SettingsService(
      SettingsRepository(
        ProfileLocalDatasource(database),
        RecentDeviceLocalDatasource(database),
        SecretLocalDatasource(appSecureStorage),
      ),
    );
    final deviceListService = DeviceListService(
      DeviceListRemoteDatasource(),
      settingsService,
    );
    return AppDependencies._(
      database: database,
      settingsService: settingsService,
      deviceListService: deviceListService,
      streamSessionService: StreamSessionService(StreamRemoteDatasource()),
      settingsViewModel: SettingsViewModel(settingsService),
      deviceListViewModel: DeviceListViewModel(deviceListService),
    );
  }

  /// 本地库（配置 / 最近设备）；关库由 [dispose] 负责。
  final AppDatabase database;

  final SettingsService settingsService;
  final DeviceListService deviceListService;
  final StreamSessionService streamSessionService;

  /// 跨页面共享的视图模型（设置与设备列表状态在切页后仍然保留）。
  final SettingsViewModel settingsViewModel;
  final DeviceListViewModel deviceListViewModel;

  /// 每次进入投流页新建一个会话 viewmodel（会话生命周期与页面一致）。
  void dispose() {
    settingsViewModel.dispose();
    deviceListViewModel.dispose();
    streamSessionService.dispose();
    database.close();
  }
}

/// 把 [AppDependencies] 注入组件树。
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.dependencies, required super.child});

  final AppDependencies dependencies;

  static AppDependencies of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未注入：请确认组件在 AppScope 之下');
    return scope!.dependencies;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      dependencies != oldWidget.dependencies;
}
