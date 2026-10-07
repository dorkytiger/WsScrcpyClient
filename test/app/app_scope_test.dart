import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/app/app_scope.dart';

/// 守住依赖装配里的安全存储选项——它直接决定"密码能不能持久化"。
///
/// 背景（2026-10-07 本机实测）：`flutter_secure_storage_macos` 9.x 默认走
/// **data protection keychain**（`kSecUseDataProtectionKeychain = true`），
/// 而那需要 `keychain-access-groups` / `com.apple.application-identifier` 授权，
/// 只能由 provisioning profile 提供。Flutter 的 macOS 模板是 ad-hoc 签名
/// （`CODE_SIGN_IDENTITY = "-"`，`TeamIdentifier=not set`），于是每次写入都返回
/// `-34018 errSecMissingEntitlement` → 密码只剩"本次会话有效"。
///
/// 用最小 `.app`（同款 `app-sandbox` 授权 + ad-hoc 签名）做的探针证实：
/// 关掉该开关后 `SecItemAdd / CopyMatching / Delete` 全部成功（0），开着就是 -34018。
/// 所以这条断言**不是风格偏好**，改回去会让 macOS 上的密码持久化再次失效。
void main() {
  group('appSecureStorage', () {
    test('macOS 关掉 data protection keychain（ad-hoc 签名下 -34018）', () {
      expect(
        appSecureStorage.mOptions.toMap()['useDataProtectionKeyChain'],
        'false',
        reason: '开着它需要 provisioned 的 keychain-access-groups 授权；'
            'Flutter macOS 模板是 ad-hoc 签名，写入会以 PlatformException(-34018) 失败',
      );
    });

    test('Android 仍走 EncryptedSharedPreferences', () {
      expect(
        appSecureStorage.aOptions.toMap()['encryptedSharedPreferences'],
        'true',
      );
    });
  });
}
