import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';

/// 密码写入安全存储的结果。
enum SecretWriteOutcome {
  /// 已持久化到安全存储。
  persisted,

  /// 写入失败，密码只保留在内存中（本次会话有效）。
  sessionOnly,
}

/// 密码（Basic Auth）的本地数据边界：按 `profileId` 存取。
///
/// 设计要点（**降级而非崩溃**）：受限环境里 `flutter_secure_storage` 会抛异常，
/// - 读失败 → 当作"没有密码"（用户重新填一次即可）；
/// - 写失败 → 密码留在内存里，本次会话仍然可用，并返回
///   [SecretWriteOutcome.sessionOnly] 让上层提示"未持久化"。
///
/// 密码**不入库**（不进 drift），只落在系统安全存储里。
class SecretLocalDatasource {
  SecretLocalDatasource(this._storage);

  final FlutterSecureStorage _storage;
  final AppLogger _logger = AppLogger('SecretLocalDatasource');

  /// 仅本次会话有效的密码（安全存储写失败时的兜底）。
  final Map<int, String> _sessionOnlyPasswords = <int, String>{};

  /// 存储键：以 profileId 为后缀，一个配置一个密码。
  static String keyFor(int profileId) => 'settings.password.$profileId';

  /// 读取已持久化的密码；不存在或读取失败都返回 null（按"没有密码"处理）。
  Future<String?> readPersisted(int profileId) async {
    try {
      final value = await loadPassword(profileId);
      return (value == null || value.isEmpty) ? null : value;
    } catch (error, stackTrace) {
      _logger.warn('读取安全存储失败，按"没有密码"处理', error, stackTrace);
      return null;
    }
  }

  /// 读取只存在于内存中的密码（安全存储写失败后的兜底）。
  String? readSessionOnly(int profileId) => _sessionOnlyPasswords[profileId];

  /// 写入密码。
  ///
  /// 空密码表示"清除密码"，等价于 [delete]。
  Future<SecretWriteOutcome> write(int profileId, String password) async {
    if (password.isEmpty) {
      await delete(profileId);
      return SecretWriteOutcome.persisted;
    }
    try {
      await persistPassword(profileId, password);
      _sessionOnlyPasswords.remove(profileId);
      return SecretWriteOutcome.persisted;
    } catch (error, stackTrace) {
      _sessionOnlyPasswords[profileId] = password;
      _logger.warn('写入安全存储失败，密码仅在本次会话有效', error, stackTrace);
      return SecretWriteOutcome.sessionOnly;
    }
  }

  /// 删除密码（同时清掉内存兜底）。返回是否成功清掉持久化数据。
  Future<bool> delete(int profileId) async {
    _sessionOnlyPasswords.remove(profileId);
    try {
      await removePassword(profileId);
      return true;
    } catch (error, stackTrace) {
      _logger.warn('删除安全存储中的密码失败', error, stackTrace);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 存储后端钩子：下面三个方法才真正触碰 flutter_secure_storage。
  // 测试可以覆写它们来模拟"平台不可用"，从而验证上面的降级逻辑。
  // ---------------------------------------------------------------------------

  /// 读取原始密文。
  Future<String?> loadPassword(int profileId) =>
      _storage.read(key: keyFor(profileId));

  /// 写入原始密文。
  Future<void> persistPassword(int profileId, String password) =>
      _storage.write(key: keyFor(profileId), value: password);

  /// 删除原始密文。
  Future<void> removePassword(int profileId) =>
      _storage.delete(key: keyFor(profileId));
}
