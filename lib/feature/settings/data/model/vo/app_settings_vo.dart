import 'package:ws_scrcpy_client/core/ws/ws_url_builder.dart';

/// 应用设置（跨模块读取的只读视图对象）。
class AppSettingsVo {
  const AppSettingsVo({
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.lastUdid,
    required this.keepScreenOn,
    this.profileId,
    this.profileName,
  });

  /// 服务端入口，形如 `https://android.dorkytiger.top/`（http/https 均可）。
  final String serverUrl;

  /// Basic Auth 用户名（服务端未开启鉴权时可为空）。
  final String username;

  /// Basic Auth 密码（**明文**，与配置同存本地数据库；见 `ConnectionProfiles`）。
  final String password;

  /// 上次使用的设备序列号（"记住上次设备"）。
  final String? lastUdid;

  /// 投流/操作期间是否保持屏幕常亮。
  final bool keepScreenOn;

  /// 当前生效配置的 id；尚未创建任何配置时为 null。
  final int? profileId;

  /// 当前生效配置的展示名；未配置时为 null。
  final String? profileName;

  /// 是否配置了 Basic Auth 凭据。
  bool get hasBasicAuth => username.isNotEmpty && password.isNotEmpty;

  /// WebSocket 握手用的 `Authorization` 头取值；未配置凭据时为 null。
  String? get basicAuthorizationHeader =>
      hasBasicAuth ? WsUrlBuilder.basicAuthorization(username, password) : null;

  /// 服务入口 URI（非法地址在保存时已被拦截，这里直接解析）。
  Uri get serverUri => Uri.parse(serverUrl);

  AppSettingsVo copyWith({
    String? serverUrl,
    String? username,
    String? password,
    String? lastUdid,
    bool? keepScreenOn,
    int? profileId,
    String? profileName,
  }) {
    return AppSettingsVo(
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      lastUdid: lastUdid ?? this.lastUdid,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      profileId: profileId ?? this.profileId,
      profileName: profileName ?? this.profileName,
    );
  }

  @override
  String toString() =>
      'AppSettingsVo(serverUrl: $serverUrl, username: $username, '
      'password: ${password.isEmpty ? '' : '***'}, lastUdid: $lastUdid, '
      'keepScreenOn: $keepScreenOn, profileId: $profileId, '
      'profileName: $profileName)';
}
