/// 保存设置入参（字段 >3 个，按规范必须建 DTO）。
class SaveSettingsDto {
  const SaveSettingsDto({
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.keepScreenOn,
    this.name,
    this.id,
  });

  final String serverUrl;
  final String username;
  final String password;
  final bool keepScreenOn;

  /// 配置展示名；为空时由 service 用服务地址的 host 兜底。
  final String? name;

  /// 要保存到的配置 id；为 null 时保存到当前 active 配置（没有则新建并置为 active）。
  final int? id;
}
