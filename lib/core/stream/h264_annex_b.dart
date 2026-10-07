import 'dart:typed_data';

/// Annex-B 码流里的一个 NAL 单元（只描述"在哪、什么类型"，不复制字节）。
///
/// 为什么要自己切 NAL（2026-10-07，web 端阶段二）：
/// - **判断关键帧**：WebCodecs 的 `EncodedVideoChunk` 必须告诉浏览器这条是
///   `key` 还是 `delta`，否则第一批帧会被丢掉；
/// - **取 SPS 造 codec 串**：`VideoDecoderConfig.codec` 要 `avc1.PPCCLL`，
///   这三个字节就在 SPS 的 RBSP 开头（见 [H264AnnexB.avcCodecString]）。
///
/// 三个解码端（Android MediaCodec / Windows MFT / Apple VideoToolbox）都是把整条消息
/// 直接喂给系统解码器的，只有 web 这一端需要自己看 NAL 类型——所以这层放在 `core`
/// （纯 Dart、无 Flutter），并且用真实抓包做单测（`test/core/stream/h264_annex_b_test.dart`）。
class H264NalUnit {
  const H264NalUnit({
    required this.type,
    required this.payloadOffset,
    required this.end,
  });

  /// `nal_unit_type`：1 = 非 IDR 片，5 = IDR 片，7 = SPS，8 = PPS。
  final int type;

  /// NAL header（第一个字节）之后的偏移，也就是 RBSP 起点。
  final int payloadOffset;

  /// 这个 NAL 的结束位置（不含下一个起始码，也不含本 NAL 尾部的零字节）。
  final int end;
}

/// H.264 / Annex-B 的最小解析工具。
class H264AnnexB {
  const H264AnnexB._();

  /// 按起始码（`00 00 01` / `00 00 00 01`）切开 [data]。
  ///
  /// 数据里没有起始码时返回空列表——调用方据此拒绝这条消息（协议实测是 Annex-B，
  /// 一条没有起始码的"视频消息"说明上游出了问题，不猜）。
  static List<H264NalUnit> split(Uint8List data) {
    final codeStarts = <int>[];
    final payloadStarts = <int>[];
    var i = 0;
    while (i + 3 <= data.length) {
      if (i + 4 <= data.length &&
          data[i] == 0 &&
          data[i + 1] == 0 &&
          data[i + 2] == 0 &&
          data[i + 3] == 1) {
        codeStarts.add(i);
        payloadStarts.add(i + 4);
        i += 4;
        continue;
      }
      if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
        codeStarts.add(i);
        payloadStarts.add(i + 3);
        i += 3;
        continue;
      }
      i++;
    }

    final units = <H264NalUnit>[];
    for (var k = 0; k < payloadStarts.length; k++) {
      final start = payloadStarts[k];
      var end = k + 1 < codeStarts.length ? codeStarts[k + 1] : data.length;
      // 尾部零字节属于起始码填充，不算 NAL 内容（RBSP 里不会以 0x00 结尾地裸奔）。
      while (end > start && data[end - 1] == 0) {
        end--;
      }
      if (end <= start) {
        continue;
      }
      units.add(
        H264NalUnit(
          type: data[start] & 0x1F,
          payloadOffset: start + 1,
          end: end,
        ),
      );
    }
    return units;
  }

  /// 这条消息里有没有 IDR 片（`nal_unit_type == 5`）。
  static bool hasIdr(Uint8List data) =>
      split(data).any((H264NalUnit unit) => unit.type == 5);

  /// 这条消息里有没有参数集（SPS 7 / PPS 8）。
  ///
  /// scrcpy 每条连接开头会先发一条"只有 SPS+PPS、没有片数据"的消息；
  /// web 端要在**看到它之后**才能算出 codec 串并 `configure`。
  static bool hasParameterSets(Uint8List data) {
    final types = split(data).map((H264NalUnit unit) => unit.type).toSet();
    return types.contains(7) || types.contains(8);
  }

  /// 从这条消息里取 SPS 的 RBSP（不含 NAL header，已去掉防竞争字节 `00 00 03`）。
  static Uint8List? spsRbsp(Uint8List data) {
    for (final unit in split(data)) {
      if (unit.type != 7) {
        continue;
      }
      return _withoutEmulationPrevention(
        Uint8List.sublistView(data, unit.payloadOffset, unit.end),
      );
    }
    return null;
  }

  /// 用 SPS 造 WebCodecs 要的 codec 串：`avc1.PPCCLL`（P=profile、C=constraint、L=level）。
  ///
  /// SPS 的 RBSP 头三个字节就是 `profile_idc` / `constraint_set_flags` / `level_idc`，
  /// 不需要真的算指数哥伦布（这也是各家播放器造这个串的做法）。
  /// 例：真实夹具里的 SPS 是 `67 42 c0 29 …` → `avc1.42c029`（Baseline 4.1）。
  static String? avcCodecString(Uint8List data) {
    final rbsp = spsRbsp(data);
    if (rbsp == null || rbsp.length < 3) {
      return null;
    }
    return 'avc1.${_hex2(rbsp[0])}${_hex2(rbsp[1])}${_hex2(rbsp[2])}';
  }

  /// 组装一条"喂给**没有 `description`** 的 WebCodecs 解码器"的关键帧样本：
  /// 把参数集（SPS+PPS）拼在片数据前面。
  ///
  /// **为什么必须拼**（2026-10-07 用户实测 `WebCodecs 解码失败：Decoder failure`）：
  /// 我们不传 `VideoDecoderConfig.description`（那样输入按 Annex-B 解释、省掉 AVCC 重封装），
  /// 但代价是**解码器没有任何带外参数集**——SPS/PPS 必须**跟着片数据一起**喂进去。
  /// 服务端自己的 `WebCodecsPlayer` 就是这么干的（它把 SPS+PPS+IDR 拼成一条 `type:'key'` 的 chunk），
  /// 而"纯参数集那条消息"它只用来 configure，不当样本喂。
  ///
  /// [frame] 里已经带了参数集时原样返回，避免重复（H.264 允许带内重复，但没必要）。
  static Uint8List sampleDataForDecoder({
    required Uint8List frame,
    Uint8List? parameterSets,
  }) {
    if (parameterSets == null ||
        parameterSets.isEmpty ||
        hasParameterSets(frame)) {
      return frame;
    }
    final out = Uint8List(parameterSets.length + frame.length);
    out.setRange(0, parameterSets.length, parameterSets);
    out.setRange(parameterSets.length, out.length, frame);
    return out;
  }

  /// 去掉防竞争字节：码流里 `00 00 03` 是插入的，解析 RBSP 前要删掉那个 `03`。
  static Uint8List _withoutEmulationPrevention(Uint8List raw) {
    if (!raw.contains(3)) {
      return raw;
    }
    final out = Uint8List(raw.length);
    var length = 0;
    var i = 0;
    while (i < raw.length) {
      if (i + 2 < raw.length && raw[i] == 0 && raw[i + 1] == 0 && raw[i + 2] == 3) {
        out[length++] = 0;
        out[length++] = 0;
        i += 3;
        continue;
      }
      out[length++] = raw[i++];
    }
    return Uint8List.sublistView(out, 0, length);
  }

  static String _hex2(int value) =>
      (value & 0xFF).toRadixString(16).padLeft(2, '0');
}
