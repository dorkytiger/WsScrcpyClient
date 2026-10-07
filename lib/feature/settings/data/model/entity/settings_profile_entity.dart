/// 连接配置（profile）的持久化实体。
///
/// 与 drift 生成的行类型解耦：datasource 负责把数据库行映射成它，
/// 上层（repository/service）不再接触 drift 类型。
///
/// 不含 `createdAt`/`updatedAt`：时间戳是数据库的内部记账字段
/// （用于"删除 active 后提升最近更新的一条"这类排序），上层用不到。
class SettingsProfileEntity {
  const SettingsProfileEntity({
    required this.id,
    required this.name,
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.keepScreenOn,
    required this.lastUdid,
    required this.isActive,
  });

  /// 新建草稿：`id` 与 `isActive` 由 datasource 决定。
  const SettingsProfileEntity.draft({
    required this.name,
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.keepScreenOn,
    this.lastUdid,
  }) : id = unstoredId,
       isActive = false;

  /// 尚未落库的 id。
  static const int unstoredId = 0;

  final int id;

  /// 展示名；可能为空串（由上层/UI 回落为服务地址的 host）。
  final String name;

  final String serverUrl;
  final String username;

  /// Basic Auth 密码（**明文**，随配置一起落库；见 `ConnectionProfiles` 的类文档）。
  final String password;

  final bool keepScreenOn;
  final String? lastUdid;

  /// 是否为当前生效配置。
  final bool isActive;

  bool get isStored => id != unstoredId;

  SettingsProfileEntity copyWith({
    int? id,
    String? name,
    String? serverUrl,
    String? username,
    String? password,
    bool? keepScreenOn,
    String? lastUdid,
    bool? isActive,
  }) {
    return SettingsProfileEntity(
      id: id ?? this.id,
      name: name ?? this.name,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      lastUdid: lastUdid ?? this.lastUdid,
      isActive: isActive ?? this.isActive,
    );
  }

  @override
  String toString() =>
      'SettingsProfileEntity(id: $id, name: $name, serverUrl: $serverUrl, '
      'username: $username, password: ${password.isEmpty ? '' : '***'}, '
      'keepScreenOn: $keepScreenOn, lastUdid: $lastUdid, isActive: $isActive)';
}
