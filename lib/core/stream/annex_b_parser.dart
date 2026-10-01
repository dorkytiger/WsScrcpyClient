import 'dart:typed_data';

/// 一个 H.264 NAL 单元（Annex-B 格式）。
class H264NalUnit {
  const H264NalUnit({
    required this.type,
    required this.data,
    required this.startCodeLength,
  });

  /// 非 IDR 片。
  static const int typeNonIdrSlice = 1;

  /// 关键帧（IDR 片）。
  static const int typeIdrSlice = 5;

  /// 补充增强信息。
  static const int typeSei = 6;

  /// 序列参数集。
  static const int typeSps = 7;

  /// 图像参数集。
  static const int typePps = 8;

  /// NAL 类型（首字节低 5 位）。
  final int type;

  /// NAL 负载（**不含**起始码）。
  final Uint8List data;

  /// 该 NAL 之前起始码的长度（3 或 4）。
  final int startCodeLength;

  bool get isKeyFrame => type == typeIdrSlice;

  bool get isSps => type == typeSps;

  bool get isPps => type == typePps;

  bool get isSlice => type == typeIdrSlice || type == typeNonIdrSlice;

  @override
  String toString() => 'H264NalUnit(type: $type, bytes: ${data.length})';
}

/// H.264 Annex-B 解析：把 scrcpy 下发的一条消息（实测 = 一帧）拆成 NAL 单元。
///
/// 实测结论（`docs/ws-scrcpy-protocol.md` §4.4）：`sendFrameMeta = false` 时，
/// 每条 WS 消息都以 4 字节起始码 `00 00 00 01` 开头；首条消息里是 SPS + PPS，
/// 随后是关键帧，再往后是非 IDR 片。
class AnnexBParser {
  const AnnexBParser._();

  /// 起始码：Annex-B 允许 3 字节（`00 00 01`）或 4 字节（`00 00 00 01`）。
  static const List<int> startCode = <int>[0, 0, 0, 1];

  /// 该帧是否以 Annex-B 起始码开头（用于区分视频帧与初始信息头/设备消息）。
  static bool hasStartCode(Uint8List frame) {
    if (frame.length < 4) {
      return false;
    }
    for (var i = 0; i < 3; i++) {
      if (frame[i] != 0) {
        return false;
      }
    }
    return frame[3] == 1;
  }

  /// 按起始码切分 NAL 单元；忽略起始码之前的前导零字节。
  ///
  /// 没有任何起始码时返回空列表（调用方据此判定"这不是一帧 H.264"）。
  static List<H264NalUnit> split(Uint8List frame) {
    final units = <H264NalUnit>[];
    var cursor = 0;
    int? nalStart;
    var nalStartCodeLength = 0;

    void flush(int end) {
      final start = nalStart;
      if (start == null || end <= start) {
        return;
      }
      units.add(
        H264NalUnit(
          type: frame[start] & 0x1F,
          data: Uint8List.sublistView(frame, start, end),
          startCodeLength: nalStartCodeLength,
        ),
      );
    }

    while (cursor + 3 <= frame.length) {
      if (frame[cursor] == 0 &&
          frame[cursor + 1] == 0 &&
          frame[cursor + 2] == 1) {
        final isFourByte = cursor > 0 && frame[cursor - 1] == 0;
        final startCodeLength = isFourByte ? 4 : 3;
        final startCodeOffset = isFourByte ? cursor - 1 : cursor;
        flush(startCodeOffset);
        nalStart = cursor + 3;
        nalStartCodeLength = startCodeLength;
        cursor += 3;
        continue;
      }
      cursor++;
    }
    flush(frame.length);
    return units;
  }
}
