/// 控制消息测试的公共断言工具。
///
/// 之所以单独放一个文件：所有消息测试都要做"逐字节 vs 期望十六进制"的比对，
/// 若每个测试各写一份，字节序/长度这类断言会各处不一致。
///
/// 把期望值写成十六进制字符串是刻意的：它让测试本身就是一份协议文档，
/// 可以直接和 `.probe/bundle.js` 的 `toBuffer()` 写序列逐行对照。
library;

import 'package:flutter_test/flutter_test.dart';

/// 解析形如 `'02 00 FF'` / `'02,00,FF'` 的十六进制串为字节数组。
///
/// 分隔符为空格或逗号，允许换行与缩进；长度必须是偶数个十六进制字符。
List<int> hexBytes(String source) {
  final normalized = source.replaceAll(RegExp(r'[\s,]+'), '');
  if (normalized.isEmpty) {
    return const <int>[];
  }
  if (normalized.length.isOdd) {
    throw ArgumentError('十六进制串长度必须是偶数：$source');
  }
  final bytes = <int>[];
  for (var i = 0; i < normalized.length; i += 2) {
    bytes.add(int.parse(normalized.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

/// 把字节数组格式化为便于阅读的十六进制串（用于失败信息与调试输出）。
String hexOf(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

/// 逐字节断言：先比长度，再比每个偏移的取值，失败信息里带上十六进制视图。
///
/// 不用一次性的 `expect(actual, expected)`：逐偏移比对能在失败时直接指出
/// "第几字节不对"，而字节序错误往往只错一个字段。
void expectBytes(List<int> actual, List<int> expected) {
  expect(
    actual.length,
    expected.length,
    reason: '字节数不一致\n实际: ${hexOf(actual)}\n期望: ${hexOf(expected)}',
  );
  for (var offset = 0; offset < expected.length; offset++) {
    expect(
      actual[offset],
      expected[offset],
      reason: '偏移 $offset 字节不一致\n实际: ${hexOf(actual)}\n期望: ${hexOf(expected)}',
    );
  }
}
