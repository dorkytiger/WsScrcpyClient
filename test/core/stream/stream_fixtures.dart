/// 测试夹具加载（都是 M0 探测时从真实服务端抓下来的报文，**禁止手改**）。
///
/// 由 `WS_PROBE_WRITE_FIXTURES=1 dart run tools/probe.dart` 重新采集。
library;

import 'dart:io';
import 'dart:typed_data';

/// 十六进制字符串 → 字节。
Uint8List hexToBytes(String hex) {
  final trimmed = hex.trim();
  final bytes = Uint8List(trimmed.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(trimmed.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

/// 投流连接后服务端下发的第一条消息：`scrcpy_initial` 初始信息头。
Uint8List loadInitialInfoFixture() => hexToBytes(
  File('test/fixtures/stream_initial_info.hex').readAsStringSync(),
);

/// 前几条真实视频消息（每行一条，最多保留了前 256 字节）。
List<Uint8List> loadVideoFrameFixture() =>
    File('test/fixtures/stream_first_video_frames.txt')
        .readAsLinesSync()
        .where((String line) => line.trim().isNotEmpty)
        .map(hexToBytes)
        .toList(growable: false);
