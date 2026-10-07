import 'dart:developer' as developer;

import 'package:ws_scrcpy_client/core/log/app_log_file.dart';

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
    // 前缀带上**毫秒时间戳**：用户报"旋转后卡了几十秒"这类问题时，
    // 日志里的"时间缺口"是唯一能分清两种原因的证据 ——
    // 每秒一条的统计行断了几十秒 = 我们自己的 UI/引擎被卡住；
    // 统计行一直在、只有画面不动 = 卡在视频管线（服务端没给帧 / 解码器没解出来）。
    final line =
        '[${_timestamp()}] [$tag] ${level.description}: $message'
        '${error == null ? '' : ' | cause: $error'}';
    developer.log(
      line,
      name: tag,
      level: _levelValue(level),
      error: error,
      stackTrace: stackTrace,
    );
    onRecord?.call(line);
    // 同时落盘（web 上是空操作；没启动/写不进去时也是空操作）。
    //
    // 为什么必须有：2026-10-08 判"低延迟开关到底改了没改"时，Dart 侧那两行
    // （`服务端初始头给的 VideoSettings` / `首发视频参数`）只在应用内面板里看得到，
    // 于是只能靠"感觉"下结论 —— 那是排查里最不该出现的东西（§16.5）。
    AppLogFile.write(line);
  }

  /// `HH:mm:ss.SSS`（本地时间）。
  static String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
        '.${three(now.millisecond)}';
  }

  int _levelValue(AppLogLevel level) => switch (level) {
    AppLogLevel.debug => 500,
    AppLogLevel.info => 800,
    AppLogLevel.warn => 900,
    AppLogLevel.error => 1000,
  };
}
