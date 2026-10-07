/// web 上的 Dart 日志落盘：**空实现**。
///
/// 浏览器里没有可写的文件系统（也不该往用户磁盘写日志），日志面板
/// （[AppLogger.onRecord]）与控制台照常工作 —— 与 `database_executor_web.dart`
/// 是同一个"接口一致、实现按平台分派"的套路。
class AppLogFile {
  static const String fileName = 'ws_scrcpy_client_app.log';

  static const int defaultMaxBytes = 2 * 1024 * 1024;

  static bool get isStarted => false;

  static String? get path => null;

  static Future<void> start({String? directory, int maxBytes = defaultMaxBytes}) async {}

  static void write(String line) {}

  static void stop() {}

  static void resetForTest() {}
}
