import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/video_decoder.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/webcodecs_video_decoder.dart';

/// web：浏览器 WebCodecs（`VideoDecoder`），画面画进 canvas 平台视图。
VideoDecoder createVideoDecoder({
  AppLogger? logger,
  void Function(String line)? onLog,
}) => WebCodecsVideoDecoder(logger: logger, onLog: onLog);
