import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/feature/settings/application/service/settings_service.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/dto/save_settings_dto.dart';

/// 诊断用启动引导：用 `--dart-define` 注入一条连接配置，让应用能"零人工操作"直连服务端。
///
/// **为什么要它**（理由与 `device_list_page.dart` 的 `WS_SCRCPY_AUTOSTART` 同源）：
/// 投流问题必须**反复跑、还得能一边跑一边读日志**，而"首次进入要手填表单"这件事在
/// 自动化环境里根本没法完成——iOS 模拟器上没有可靠的方式模拟三次文本输入 + 点击保存。
///
/// **为什么不用环境变量**：`WS_SCRCPY_AUTOSTART` 读的是 `Platform.environment`，
/// 而 iOS 应用进程拿不到宿主 shell 的环境变量；`--dart-define` 是编译期常量，跨平台都可靠。
///
/// 用法（只用于本地诊断）：
///
/// ```sh
/// flutter run -d <ios-simulator-id> \
///   --dart-define=WS_BOOTSTRAP_URL=https://example.invalid/ \
///   --dart-define=WS_BOOTSTRAP_USER=<用户名> \
///   --dart-define=WS_BOOTSTRAP_PASSWORD=<密码>
/// ```
///
/// **默认关闭**：不传 `WS_BOOTSTRAP_URL` 时 `isEnabled` 为 false，[ensureProfile] 直接返回，
/// 行为与以前完全一致。注意 `--dart-define` 的值会被编译进产物，
/// 因此**不要把凭据写进仓库或长期复用这个构建产物**。
class DebugBootstrap {
  const DebugBootstrap._();

  static const String url = String.fromEnvironment('WS_BOOTSTRAP_URL');
  static const String username = String.fromEnvironment('WS_BOOTSTRAP_USER');
  static const String password = String.fromEnvironment(
    'WS_BOOTSTRAP_PASSWORD',
  );

  /// 是否启用了诊断引导。
  static bool get isEnabled => url.isNotEmpty;

  /// 本地诊断用的自动投流开关（`--dart-define=WS_SCRCPY_AUTOSTART=1`）。
  ///
  /// 与设备列表页读 `Platform.environment` 的那条并存：桌面端用环境变量、
  /// iOS/Android 用 dart-define，两条都写同一个语义。
  static const String autostart = String.fromEnvironment('WS_SCRCPY_AUTOSTART');

  static bool get isAutostartEnabled => autostart == '1';

  /// 还没有任何连接配置时，用 dart-define 里的值建一条并置为 active。
  ///
  /// 已有配置就**什么都不做**——避免覆盖用户自己填的东西。
  static Future<void> ensureProfile(
    SettingsService service, {
    AppLogger? logger,
  }) async {
    if (!isEnabled) {
      return;
    }
    final log = logger ?? AppLogger('DebugBootstrap');

    final hasProfile = await service.hasAnyProfile();
    if (hasProfile.isError) {
      log.warn('诊断引导：读取"是否已有配置"失败，跳过', hasProfile.error);
      return;
    }
    if (hasProfile.data == true) {
      log.info('诊断引导：已有连接配置，不覆盖');
      return;
    }

    final result = await service.save(
      SaveSettingsDto(
        serverUrl: url,
        username: username,
        password: password,
        keepScreenOn: true,
        name: '诊断引导',
      ),
    );
    if (result.isError) {
      log.warn('诊断引导：写入连接配置失败', result.error);
      return;
    }
    log.info('诊断引导：已用 dart-define 注入连接配置（$url / $username）');
  }
}
