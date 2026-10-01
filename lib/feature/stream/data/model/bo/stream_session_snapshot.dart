import 'package:ws_scrcpy_client/core/stream/stream_initial_info.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/stream_connection_status.dart';

/// 投流会话快照（不可变，UI 只读）。
class StreamSessionSnapshot {
  const StreamSessionSnapshot({
    required this.status,
    this.activeUri,
    this.deviceName,
    this.clientId,
    this.display,
    this.videoFrameCount = 0,
    this.videoBytes = 0,
    this.encoders = const <String>[],
  });

  const StreamSessionSnapshot.idle()
    : this(status: StreamConnectionStatus.idle);

  final StreamConnectionStatus status;

  /// 当前实际使用的连接地址（代理或直连），排查问题时很有用。
  final Uri? activeUri;

  final String? deviceName;
  final int? clientId;

  /// 主显示器的投流状态（分辨率/编码参数）。
  final DisplayStreamState? display;

  final int videoFrameCount;
  final int videoBytes;

  /// 设备可用编码器列表。
  final List<String> encoders;

  /// 是否已经收到视频数据（M0 实测：服务端 scrcpy-server 异常时这里会一直是 0）。
  bool get hasVideo => videoFrameCount > 0;

  StreamSessionSnapshot copyWith({
    StreamConnectionStatus? status,
    Uri? activeUri,
    String? deviceName,
    int? clientId,
    DisplayStreamState? display,
    int? videoFrameCount,
    int? videoBytes,
    List<String>? encoders,
  }) {
    return StreamSessionSnapshot(
      status: status ?? this.status,
      activeUri: activeUri ?? this.activeUri,
      deviceName: deviceName ?? this.deviceName,
      clientId: clientId ?? this.clientId,
      display: display ?? this.display,
      videoFrameCount: videoFrameCount ?? this.videoFrameCount,
      videoBytes: videoBytes ?? this.videoBytes,
      encoders: encoders ?? this.encoders,
    );
  }

  @override
  String toString() =>
      'StreamSessionSnapshot(status: ${status.code}, deviceName: $deviceName, '
      'frames: $videoFrameCount, bytes: $videoBytes)';
}
