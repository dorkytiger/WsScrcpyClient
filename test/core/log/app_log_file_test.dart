import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/log/app_log_file.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';

/// Dart 侧日志落盘（见 `app_log_file_io.dart` 的类注释）。
///
/// 为什么要这些用例：这段代码唯一的职责是"**日志永远不能影响业务**" ——
/// 所以每条断言都在钉两件事之一：要么真的写进去了（能用来排查），
/// 要么在写不进去/超限时**安静地降级**（绝不抛异常、绝不无界增长）。
void main() {
  late Directory directory;

  setUp(() {
    AppLogFile.resetForTest();
    directory = Directory('.tmp/logtest')..createSync(recursive: true);
    for (final entity in directory.listSync()) {
      entity.deleteSync(recursive: true);
    }
  });

  tearDown(() {
    AppLogFile.stop();
  });

  File logFile() => File('${directory.path}/${AppLogFile.fileName}');

  test('启动后 AppLogger 的每条日志都落到文件里（含 tag 与级别）', () async {
    await AppLogFile.start(directory: directory.path);
    expect(AppLogFile.isStarted, isTrue);

    AppLogger('UnitTest').info('第一行');
    AppLogger('UnitTest').warn('第二行');

    final text = logFile().readAsStringSync();
    expect(text, contains('==== Dart 日志启动'));
    expect(text, contains('[UnitTest] 信息: 第一行'));
    expect(text, contains('[UnitTest] 警告: 第二行'));
  });

  test('没启动时写日志是空操作（不创建文件、不抛异常）', () {
    AppLogger('UnitTest').info('没有落盘');
    expect(AppLogFile.isStarted, isFalse);
    expect(logFile().existsSync(), isFalse);
  });

  test('start 幂等：重复调用只打一次启动分隔行', () async {
    await AppLogFile.start(directory: directory.path);
    await AppLogFile.start(directory: directory.path);

    final starts = logFile()
        .readAsLinesSync()
        .where((String line) => line.contains('==== Dart 日志启动'))
        .length;
    expect(starts, 1, reason: '重复 start 不该重复打开文件或重复打分隔行');
  });

  test('★ 超过上限：就地截断重开，文件不无界增长', () async {
    // 上限设得很小（真实值是 2 MB），这样几条日志就能触发一次轮转。
    await AppLogFile.start(directory: directory.path, maxBytes: 200);
    for (var i = 0; i < 50; i++) {
      AppLogger('UnitTest').info('很占地方的一行日志 $i（用来把文件顶过上限）');
    }
    final size = logFile().lengthSync();
    // 轮转是"就地重开"（不是滚动多份），所以文件大小必须仍在上限附近，
    // 而不是 50 行的累加。
    expect(
      size,
      lessThan(200 * 3),
      reason: '超过上限后应当截断重开，实际大小 $size',
    );
    final text = logFile().readAsStringSync();
    expect(text, contains('很占地方的一行日志 49'), reason: '截断后新的日志仍要能写进去');
  });

  test('★ 目录写不进去：静默降级，绝不抛给业务', () async {
    // 用一个不可能创建的路径（把普通文件当目录用）。
    final blocker = File('${directory.path}/blocker')..writeAsStringSync('x');
    await AppLogFile.start(directory: '${blocker.path}/sub');

    // 两个结果都算通过：要么找到了别的可写候选（exe 目录 / TEMP），要么彻底放弃。
    // 关键是**不抛异常**，且 write() 之后进程仍然正常。
    AppLogger('UnitTest').info('写不进去也要活着');
    expect(() => AppLogFile.write('再写一行'), returnsNormally);
  });
}
