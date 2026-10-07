import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/native_video_decoder.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/video_decoder.dart';

/// 原生平台（Android / Windows / iOS / macOS）：`ws_scrcpy/video` 通道 + 系统硬解。
VideoDecoder createVideoDecoder({
  AppLogger? logger,
  void Function(String line)? onLog,
}) => NativeVideoDecoder(logger: logger);
