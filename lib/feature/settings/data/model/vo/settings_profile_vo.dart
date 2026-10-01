import 'package:ws_scrcpy_client/feature/settings/data/model/entity/settings_profile_entity.dart';

/// 连接配置的展示对象（跨层/UI 只认它）。
class SettingsProfileVo {
  const SettingsProfileVo({
    required this.id,
    required this.name,
    required this.serverUrl,
    required this.username,
    required this.lastUdid,
    required this.keepScreenOn,
    required this.isActive,
  });

  final int id;
  final String name;
  final String serverUrl;
  final String username;
  final String? lastUdid;
  final bool keepScreenOn;
  final bool isActive;

  /// 展示名：优先用用户填写的 [name]，为空时回落服务地址的 host，再回落完整地址。
  String get displayName {
    if (name.isNotEmpty) {
      return name;
    }
    final host = Uri.tryParse(serverUrl)?.host ?? '';
    return host.isNotEmpty ? host : serverUrl;
  }

  /// 实体 → 展示对象。
  factory SettingsProfileVo.fromEntity(SettingsProfileEntity entity) {
    return SettingsProfileVo(
      id: entity.id,
      name: entity.name,
      serverUrl: entity.serverUrl,
      username: entity.username,
      lastUdid: entity.lastUdid,
      keepScreenOn: entity.keepScreenOn,
      isActive: entity.isActive,
    );
  }

  @override
  String toString() =>
      'SettingsProfileVo(id: $id, name: $name, serverUrl: $serverUrl, '
      'isActive: $isActive)';
}
