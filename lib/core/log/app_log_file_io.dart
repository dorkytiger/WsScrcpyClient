import 'dart:io';

import 'package:ws_scrcpy_client/core/database/database_executor_io.dart';

/// Dart 侧日志文件（原生平台）。
///
/// **落盘位置**：优先与数据库同一个数据目录（`WS_DATA_DIR` 或应用支持目录，
/// 复用 [resolveDataDirectory] —— 不维护第二份"数据目录规则"），目录拿不到时退到
/// exe 同目录（与原生 `scrcpy_decoder.log` 并排，Windows 开发机上最方便），最后退 `%TEMP%`。
///
/// **纪律**（与原生日志对齐，§12.2）：
/// - 启动时打一条带**日期 + pid** 的分隔行，方便和原生日志按时间对齐；
/// - 单文件超过 [defaultMaxBytes] 就地截断重开（不滚动历史，避免占用无界）；
/// - **日志永远不能影响业务**：任何 IO 异常都静默降级成"不落盘"，绝不抛给调用方；
/// - 每条**同步写**：`write()` 返回后数据已在 OS 页缓存里，进程被杀也读得到
///   （不需要 per-line fsync，那是原生侧为了"崩了也留下面包屑"的更强要求）。
class AppLogFile {
  static const String fileName = 'ws_scrcpy_client_app.log';

  /// 单文件上限（与原生 `scrcpy_decoder.log` 的 2 MB 一致）。
  static const int defaultMaxBytes = 2 * 1024 * 1024;

  static RandomAccessFile? _file;
  static String? _path;
  static int _bytes = 0;
  static int _maxBytes = defaultMaxBytes;
  static bool _disabled = false;

  /// 是否已经在写文件（没落盘时为 false —— 日志面板照常工作）。
  static bool get isStarted => _file != null;

  /// 实际落盘的路径（没落盘时为 null）。
  static String? get path => _path;

  /// 启动落盘；**幂等**（重复调用只生效一次）。
  ///
  /// [directory] / [maxBytes] 只给测试用（生产走默认值）。
  static Future<void> start({String? directory, int maxBytes = defaultMaxBytes}) async {
    if (isStarted || _disabled) {
      return;
    }
    _maxBytes = maxBytes;
    final candidates = <String>[];
    if (directory != null) {
      candidates.add('$directory${Platform.pathSeparator}$fileName');
    } else {
      // 1) 与数据库同一个数据目录（复用同一条规则）；
      // 2) exe 同目录（与原生 scrcpy_decoder.log 并排）；
      // 3) %TEMP%。
      try {
        final dataDirectory = await resolveDataDirectory();
        candidates.add('${dataDirectory.path}${Platform.pathSeparator}$fileName');
      } catch (_) {
        // 拿不到（例如没有 path_provider 的宿主）→ 试后面的候选。
      }
      try {
        candidates.add(
          '${File(Platform.resolvedExecutable).parent.path}'
          '${Platform.pathSeparator}$fileName',
        );
      } catch (_) {}
      final temp = Platform.environment['TEMP'] ?? Platform.environment['TMP'];
      if (temp != null && temp.isNotEmpty) {
        candidates.add('$temp${Platform.pathSeparator}$fileName');
      }
    }

    for (final candidate in candidates) {
      if (_tryOpen(candidate)) {
        break;
      }
    }
    if (_file == null) {
      _disabled = true; // 一个都写不进去：静默不落盘
      return;
    }
    write('==== Dart 日志启动 ${DateTime.now().toIso8601String()} pid=$pid ====');
  }

  static bool _tryOpen(String candidate) {
    try {
      final file = File(candidate);
      final parent = file.parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }
      var handle = file.openSync(mode: FileMode.append);
      var length = handle.lengthSync();
      if (length > _maxBytes) {
        // 上次跑留下的太大：就地截断重开（与原生日志同一条纪律）。
        handle.closeSync();
        handle = file.openSync(mode: FileMode.write);
        length = 0;
      }
      _file = handle;
      _path = file.path;
      _bytes = length;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 写一行（没落盘时是个空操作）。
  static void write(String line) {
    final handle = _file;
    if (handle == null) {
      return;
    }
    try {
      final text = '$line\n';
      handle.writeStringSync(text);
      // 只用于判断"要不要截断"，按字符数近似（中文 3 字节，阈值上差一点无所谓）。
      _bytes += text.length;
      if (_bytes > _maxBytes) {
        _rotate();
      }
    } catch (_) {
      // 写失败（磁盘满 / 文件被删）：降级成不落盘，绝不打扰业务。
      _disabled = true;
      _file = null;
    }
  }

  static void _rotate() {
    final currentPath = _path;
    if (currentPath == null) {
      return;
    }
    try {
      _file?.closeSync();
      _file = File(currentPath).openSync(mode: FileMode.write);
      _bytes = 0;
    } catch (_) {
      _disabled = true;
      _file = null;
    }
  }

  /// 收尾（测试用；应用运行期不需要调用）。
  static void stop() {
    try {
      _file?.closeSync();
    } catch (_) {
      // 忽略：收尾失败没有可做的事。
    }
    _file = null;
    _path = null;
    _bytes = 0;
  }

  /// 测试用：把"已放弃落盘"的状态清掉（否则同一进程里第二个用例启动不起来）。
  static void resetForTest() {
    stop();
    _disabled = false;
    _maxBytes = defaultMaxBytes;
  }
}
