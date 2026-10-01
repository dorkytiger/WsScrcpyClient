// M0 协议探测脚本（纯 Dart，可脱离 Flutter 运行）：
//
//   set WS_PROBE_USER=xxx && set WS_PROBE_PASSWORD=xxx
//   dart run tools/probe.dart
//
// 可选环境变量：
//   WS_PROBE_URL      服务端入口，默认 https://android.dorkytiger.top/
//   WS_PROBE_SECONDS  每个阶段采集时长（秒），默认 8
//   WS_PROBE_OUT      报告输出路径，默认 .probe/probe-report.txt
//
// 产出：设备列表明细、每个候选投流地址的首帧结构、H.264 起始码/SPS 判定。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/control/command_control_message.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/stream_initial_info.dart';
import 'package:ws_scrcpy_client/core/stream/video_settings.dart';
import 'package:ws_scrcpy_client/core/ws/multiplexed_socket.dart';
import 'package:ws_scrcpy_client/core/ws/ws_action.dart';
import 'package:ws_scrcpy_client/core/ws/ws_url_builder.dart';
import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';

const String _defaultUrl = 'https://android.dorkytiger.top/';

final StringBuffer _report = StringBuffer();

void main(List<String> args) async {
  final serverUrl = Platform.environment['WS_PROBE_URL'] ?? _defaultUrl;
  final username = Platform.environment['WS_PROBE_USER'];
  final password = Platform.environment['WS_PROBE_PASSWORD'];
  final seconds = int.tryParse(Platform.environment['WS_PROBE_SECONDS'] ?? '');
  final outPath =
      Platform.environment['WS_PROBE_OUT'] ?? '.probe/probe-report.txt';
  _capturePath = Platform.environment['WS_PROBE_CAPTURE'];

  if (username == null || password == null) {
    stderr.writeln('缺少凭据：请设置 WS_PROBE_USER / WS_PROBE_PASSWORD 环境变量。');
    exitCode = 2;
    return;
  }

  final serverUri = Uri.parse(serverUrl);
  final authorization = WsUrlBuilder.basicAuthorization(username, password);

  _log('== M0 协议探测 ==');
  _log('服务端入口：$serverUri');
  _log('');

  final descriptors = await _probeDeviceList(
    serverUri,
    authorization,
    Duration(seconds: seconds ?? 6),
  );
  if (descriptors.isEmpty) {
    _log('未取到设备描述符，跳过投流探测。');
  } else {
    await _probeStreams(serverUri, authorization, descriptors, seconds ?? 8);
  }

  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(_report.toString());
  stdout.writeln('\n报告已写入：${file.absolute.path}');
}

// ---------------------------------------------------------------------------
// 阶段 A：设备列表（复用层 GTRC 通道）
// ---------------------------------------------------------------------------

Future<List<Map<String, dynamic>>> _probeDeviceList(
  Uri serverUri,
  String authorization,
  Duration window,
) async {
  _log('--- 阶段 A：复用层设备列表 ---');
  final multiplexUri = WsUrlBuilder.multiplex(serverUri);
  _log('连接：$multiplexUri');

  final WebSocketTransport transport;
  try {
    transport = await IoWebSocketTransport.connect(
      multiplexUri,
      authorization: authorization,
    );
  } catch (error) {
    _log('握手失败：$error');
    return const <Map<String, dynamic>>[];
  }

  final socket = MultiplexedSocket(transport);
  final channelResult = socket.createChannel(
    Uint8List.fromList(ascii.encode(ChannelCode.gtrc.code)),
  );
  if (channelResult.isError) {
    _log('打开 GTRC 通道失败：${channelResult.error!.message}');
    await socket.dispose();
    return const <Map<String, dynamic>>[];
  }
  final channel = channelResult.data!;
  _log(
    '已发送 CreateChannel：channelId=${channel.id} 通道码=${ChannelCode.gtrc.code}',
  );

  final frames = <String>[];
  final jsonMessages = <String>[];
  final completer = Completer<void>();
  var frameCount = 0;

  final subscription = channel.messages.listen((message) {
    frameCount++;
    if (frames.length < 20) {
      frames.add(
        '  #$frameCount type=${message.type.name} 字节=${message.payload.length} '
        '前 64B=${_hex(message.payload, 64)}',
      );
    }
    jsonMessages.add(message.decodeText());
  });

  Timer(window, () {
    if (!completer.isCompleted) {
      completer.complete();
    }
  });

  await completer.future;
  await subscription.cancel();
  await socket.dispose();

  _log('共收到 $frameCount 条通道消息：');
  frames.forEach(_log);

  final descriptors = <Map<String, dynamic>>[];
  for (final raw in jsonMessages) {
    final decoded = _tryDecodeJson(raw);
    if (decoded == null) {
      _log('非 JSON 文本消息：$raw');
      continue;
    }
    _log('JSON 消息：${const JsonEncoder.withIndent('  ').convert(decoded)}');
    _writeFixture('device_list.json', raw);
    // 实测结构：{"id":-1,"type":"devicelist","data":{"list":[...],"id":"...","name":"..."}}
    final data = decoded['data'];
    final list = data is Map<String, dynamic> ? data['list'] : data;
    if (list is List) {
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          descriptors.add(item);
        }
      }
    }
  }

  _log('设备描述符数量：${descriptors.length}');
  for (final descriptor in descriptors) {
    _log('  字段：${descriptor.keys.join(', ')}');
  }
  _log('');
  return descriptors;
}

// ---------------------------------------------------------------------------
// 阶段 B：投流地址探测
// ---------------------------------------------------------------------------

Future<void> _probeStreams(
  Uri serverUri,
  String authorization,
  List<Map<String, dynamic>> descriptors,
  int seconds,
) async {
  _log('--- 阶段 B：投流地址探测 ---');
  for (final descriptor in descriptors) {
    final udid = descriptor['udid']?.toString();
    final state = descriptor['state']?.toString();
    if (udid == null || state != 'device') {
      _log('跳过 udid=$udid state=$state（非在线设备）');
      continue;
    }
    _log('设备 udid=$udid 型号=${descriptor['ro.product.model']}');

    for (final candidate in _streamCandidates(serverUri, descriptor, udid)) {
      await _probeOneStream(candidate, authorization, seconds);
    }
  }
}

/// 候选地址：优先服务端代理（公网场景），再试设备直连地址。
List<_StreamCandidate> _streamCandidates(
  Uri serverUri,
  Map<String, dynamic> descriptor,
  String udid,
) {
  final candidates = <_StreamCandidate>[];
  final interfaces = descriptor['interfaces'];
  final ipv4List = <String>[];
  if (interfaces is List) {
    for (final item in interfaces) {
      if (item is Map && item['ipv4'] is String) {
        ipv4List.add(item['ipv4'] as String);
      }
    }
  }
  if (ipv4List.isEmpty) {
    final host = serverUri.host;
    ipv4List.add(host);
  }

  for (final ipv4 in ipv4List) {
    final direct = WsUrlBuilder.directStream(
      hostname: ipv4,
      udid: udid,
      pathname: serverUri.path.isEmpty ? '/' : serverUri.path,
    );
    candidates.add(
      _StreamCandidate(
        '服务端代理（内层 $direct）',
        WsUrlBuilder.proxyWs(serverUri, direct),
      ),
    );
    candidates.add(_StreamCandidate('设备直连', direct));
  }
  return candidates;
}

Future<void> _probeOneStream(
  _StreamCandidate candidate,
  String authorization,
  int seconds,
) async {
  _log('');
  _log('尝试投流地址（${candidate.label}）：${candidate.uri}');
  final WebSocketTransport transport;
  try {
    transport = await IoWebSocketTransport.connect(
      candidate.uri,
      authorization: authorization,
      timeout: const Duration(seconds: 10),
    );
  } catch (error) {
    _log('  连接失败：$error');
    return;
  }

  final frames = <int>[];
  final firstFrames = <String>[];
  final fixtureFrames = <String>[];
  final done = Completer<void>();
  var totalBytes = 0;
  var videoFrames = 0;
  var settingsSent = false;
  final subscription = transport.messages.listen((Object raw) {
    final bytes = raw is String
        ? Uint8List.fromList(utf8.encode(raw))
        : raw is Uint8List
        ? raw
        : Uint8List.fromList(raw as List<int>);
    totalBytes += bytes.length;

    if (StreamInitialInfo.matches(bytes)) {
      final settings = _handleInitialInfo(bytes);
      // 关键：每条连接**只回发一次**视频参数。若每收到一次初始头就回一次，
      // 会与服务端形成"改参数 → 重发初始头 → 再改参数"的反馈循环，
      // 服务端一直在重启编码器，反而永远拿不到视频帧。
      if (settings != null && !settingsSent) {
        settingsSent = true;
        transport.sendBinary(
          CommandControlMessage.changeStreamParameters(settings.toBuffer())
              .toBuffer(),
        );
        _log('  已下发 CHANGE_STREAM_PARAMETERS：$settings');
      }
      return;
    }

    if (!settingsSent && videoFrames == 0) {
      _log('  首条消息非初始信息头：${_hex(bytes, 32)}');
    }
    if (videoFrames < 12) {
      firstFrames.add(
        '  #${videoFrames + 1} 字节=${bytes.length} 前 32B=${_hex(bytes, 32)} '
        '起始码=${_hasStartCode(bytes)} NAL=${_scanNalTypes(bytes)}',
      );
    }
    // 只留前 3 条视频消息的前 256 字节作为 M2 的解析夹具，避免夹具过大。
    if (fixtureFrames.length < 3) {
      fixtureFrames.add(
        _fullHex(
          Uint8List.sublistView(
            bytes,
            0,
            bytes.length < 256 ? bytes.length : 256,
          ),
        ),
      );
    }
    _captureBytesIfRequested(bytes);
    frames.add(bytes.length);
    videoFrames++;
  });

  Timer(Duration(seconds: seconds), () {
    if (!done.isCompleted) {
      done.complete();
    }
  });

  await done.future;
  await subscription.cancel();
  await transport.close();
  _flushCapture();

  _log('  收到 $videoFrames 条视频/数据消息，合计 $totalBytes 字节');
  firstFrames.forEach(_log);
  if (frames.isNotEmpty) {
    _log('  消息长度分布（前 12 条）：${frames.take(12).join(', ')}');
    _log('  平均消息长度：${(totalBytes / videoFrames).toStringAsFixed(1)} 字节');
    _writeFixture('stream_first_video_frames.txt', fixtureFrames.join('\n'));
  }
}

/// 抓帧（`WS_PROBE_CAPTURE=<路径>`）：把每条视频消息按
/// `WSCAP001` + 重复{uint32 小端长度, 帧字节} 写进文件，供离线复现工具读取。
///
/// 为什么需要它：真机上的解码问题（例如"喂入 13 帧含 IDR、输出 0 帧"）必须能在
/// **没有设备和 App** 的情况下离线复现，否则只能靠猜。抓下来的帧可以喂给
/// `tools/mft_replay_test.cmd`（同一套 Media Foundation 序列）反复试验。
final BytesBuilder _capture = BytesBuilder();
String? _capturePath;

void _captureBytesIfRequested(Uint8List bytes) {
  if (_capturePath == null) {
    return;
  }
  final length = bytes.length;
  _capture.add(<int>[
    length & 0xFF,
    (length >> 8) & 0xFF,
    (length >> 16) & 0xFF,
    (length >> 24) & 0xFF,
  ]);
  _capture.add(bytes);
}

void _flushCapture() {
  final path = _capturePath;
  if (path == null) {
    return;
  }
  final file = File(path);
  file.parent.createSync(recursive: true);
  final sink = file.openSync(mode: FileMode.write);
  sink.writeFromSync(utf8.encode('WSCAP001'));
  sink.writeFromSync(_capture.takeBytes());
  sink.closeSync();
  _log('  抓帧已写入 ${file.absolute.path}');
}

/// `WS_PROBE_BOUNDS=1280x575`：覆盖下发的编码边界。
///
/// 用途：App 会把 UI 视口收敛后作为 bounds 下发（§12.7），而网页端不这么做。
/// 用同一个服务端分别抓"带 bounds / 不带 bounds"两次，就能判断
/// **某个 bounds 是否会让编码器产出解码器不认的码流**。
VideoSize? _boundsOverride() {
  final raw = Platform.environment['WS_PROBE_BOUNDS'];
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final parts = raw.split(RegExp('[xX,]'));
  if (parts.length != 2) {
    return null;
  }
  final width = int.tryParse(parts[0]);
  final height = int.tryParse(parts[1]);
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return VideoSize(width, height);
}

/// 解析并打印初始信息头，返回"应当回发的视频参数"（无法启动时返回 null）。
///
/// 只做解析与决策，**不发送**——发送由调用方按"每条连接只发一次"控制，
/// 避免把服务端拖进参数变更的反馈循环。
VideoSettings? _handleInitialInfo(Uint8List bytes) {
  final StreamInitialInfo info;
  try {
    info = StreamInitialInfo.parse(bytes);
  } catch (error) {
    _log('  初始信息头解析失败：$error');
    _log('  原始字节：${_hex(bytes, 128)}');
    return null;
  }

  final display = info.displays.isEmpty ? null : info.displays.first;
  _log(
    '  初始信息头：设备=${info.deviceName} clientId=${info.clientId} '
    'display=${display?.displayInfo.displayId} '
    '分辨率=${display?.displayInfo.size} 连接数=${display?.connectionCount} '
    '服务端参数=${display?.videoSettings}',
  );
  _writeFixture('stream_initial_info.hex', _fullHex(bytes));
  if (display == null) {
    _log('  未发现任何显示器，无法启动投流');
    return null;
  }

  // 与服务端网页端一致：首次收到 displayInfo 就回一次视频参数；
  // 已有服务端参数时原样沿用（只把 sendFrameMeta 关掉，便于观察裸 H.264）。
  final serverSettings = display.videoSettings;
  final base = serverSettings == null
      ? VideoSettings(
          displayId: display.displayInfo.displayId,
          bitrate: VideoSettings.defaultBitrate,
          sendFrameMeta: false,
        )
      : serverSettings.copyWith(
          displayId: display.displayInfo.displayId,
          sendFrameMeta: false,
        );
  final bounds = _boundsOverride();
  if (bounds == null) {
    return base;
  }
  _log('  按 WS_PROBE_BOUNDS 覆盖编码边界：$bounds（原 ${base.bounds}）');
  return base.copyWith(bounds: bounds);
}

// ---------------------------------------------------------------------------

class _StreamCandidate {
  const _StreamCandidate(this.label, this.uri);

  final String label;
  final Uri uri;
}

Map<String, dynamic>? _tryDecodeJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

bool _hasStartCode(Uint8List bytes) {
  for (var i = 0; i + 3 < bytes.length && i < 16; i++) {
    if (bytes[i] == 0 &&
        bytes[i + 1] == 0 &&
        bytes[i + 2] == 0 &&
        bytes[i + 3] == 1) {
      return true;
    }
  }
  return false;
}

/// 扫描 H.264 Annex-B 起始码后的 NAL 类型（低 5 位）。
/// 常见值：1=非 IDR 片、5=IDR 片、6=SEI、7=SPS、8=PPS。
String _scanNalTypes(Uint8List bytes) {
  final types = <int>[];
  var i = 0;
  while (i + 4 < bytes.length) {
    if (bytes[i] == 0 &&
        bytes[i + 1] == 0 &&
        bytes[i + 2] == 0 &&
        bytes[i + 3] == 1) {
      types.add(bytes[i + 4] & 0x1F);
      i += 4;
      continue;
    }
    i++;
  }
  if (types.isEmpty) {
    return '无';
  }
  return types.take(8).join('/');
}

/// 完整的十六进制字符串（用于把真实报文写成测试夹具）。
String _fullHex(Uint8List bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// 在设置 `WS_PROBE_WRITE_FIXTURES=1` 时把真实报文写入 `test/fixtures/`，
/// 供单元测试以真实数据回归（避免手写"想当然"的样本）。
void _writeFixture(String name, String content) {
  if (Platform.environment['WS_PROBE_WRITE_FIXTURES'] != '1') {
    return;
  }
  final file = File('test/fixtures/$name');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  _log('  （已写入夹具 test/fixtures/$name）');
}

String _hex(Uint8List bytes, int maxBytes) {
  final limit = bytes.length < maxBytes ? bytes.length : maxBytes;
  final buffer = StringBuffer();
  for (var i = 0; i < limit; i++) {
    buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    if (i != limit - 1) {
      buffer.write(' ');
    }
  }
  if (bytes.length > limit) {
    buffer.write(' …(+${bytes.length - limit}B)');
  }
  return buffer.toString();
}

void _log(String message) {
  stdout.writeln(message);
  _report.writeln(message);
}
