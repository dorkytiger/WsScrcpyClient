import 'dart:developer' as developer;

/// 日志级别。
enum AppLogLevel {
  debug('调试'),
  info('信息'),
  warn('警告'),
  error('错误');

  const AppLogLevel(this.description);

  final String description;
}

/// 全局日志实现：统一走 `dart:developer`，禁止在业务代码里用 `print`。
///
/// 通过 [AppLogger.onRecord] 可以把日志接到 UI 日志面板（M4 可观测性）。
class AppLogger {
  AppLogger(this.tag);

  /// 全局日志广播，供日志面板订阅。
  static void Function(String line)? onRecord;

  static bool verbose = false;

  final String tag;

  void debug(String message) => _log(AppLogLevel.debug, message);

  void info(String message) => _log(AppLogLevel.info, message);

  void warn(String message, [Object? error, StackTrace? stackTrace]) =>
      _log(AppLogLevel.warn, message, error, stackTrace);

  void error(String message, [Object? error, StackTrace? stackTrace]) =>
      _log(AppLogLevel.error, message, error, stackTrace);

  void _log(
    AppLogLevel level,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (level == AppLogLevel.debug && !verbose) {
      return;
    }
    final line =
        '[$tag] ${level.description}: $message'
        '${error == null ? '' : ' | cause: $error'}';
    developer.log(
      line,
      name: tag,
      level: _levelValue(level),
      error: error,
      stackTrace: stackTrace,
    );
    onRecord?.call(line);
  }

  int _levelValue(AppLogLevel level) => switch (level) {
    AppLogLevel.debug => 500,
    AppLogLevel.info => 800,
    AppLogLevel.warn => 900,
    AppLogLevel.error => 1000,
  };
}
