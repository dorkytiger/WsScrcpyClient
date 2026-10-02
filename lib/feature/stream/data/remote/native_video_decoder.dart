import 'dart:async';

import 'package:flutter/services.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';

/// 原生 H.264 硬解通道（与平台实现共用同一份 MethodChannel 契约）。
///
/// - Android：`android/app/src/main/kotlin/.../ScrcpyVideoDecoder.kt`（MediaCodec）；
/// - Windows：`windows/runner/scrcpy_video_decoder.cpp`（Media Foundation MFT）；
/// - iOS / macOS：`darwin/ScrcpyVideoDecoder.swift`（VideoToolbox，**两端共用同一份**）。
///
/// 只负责"建解码器 / 喂帧 / 收尺寸变化 / 释放"，不理解投流协议；
/// 帧从哪来由 `StreamSessionService` 提供。
///
/// **尺寸是"拉"出来的，不是平台"推"过来的**：
/// - `create` 与每次 `pushFrame` 的返回值里带 `{width, height}` 回执，顺手更新；
/// - 需要立刻知道时调 [getSize] 主动拉一次；
/// - 因此原生侧**没有** `onSizeChanged` 反向推送，也就没有"解码线程投递到
///   platform thread"这条生命周期易碎路径（Windows 崩溃 0x58CA5 的根因，见 AGENTS §12）。
class NativeVideoDecoder {
  NativeVideoDecoder({AppLogger? logger})
    : _logger = logger ?? AppLogger('NativeVideoDecoder');

  /// 与 Android 的 `MainActivity.kt`、Windows 的 `flutter_window.cpp` 保持一致。
  static const MethodChannel _channel = MethodChannel('ws_scrcpy/video');

  final AppLogger _logger;
  final StreamController<VideoSize> _sizeChanges =
      StreamController<VideoSize>.broadcast();

  bool _hasTexture = false;
  VideoSize? _lastSize;

  // ---- 帧吞吐计数（每秒一条日志） ----
  //
  // 为什么在 Dart 侧再数一遍：真机上出现过"原生心跳里的『收到』停在 143 十几秒不涨、
  // 而队列深度一直是 0"，光看原生侧分不清是**流根本没给帧**还是**通道/平台线程卡住**。
  // 这三个数（发起 / 完成 / 在途峰值）与原生侧心跳一对照就能定位：
  //   - WS 收到在涨、这里"发起"不涨 → 卡在我们的转换/订阅环节；
  //   - "发起"在涨、"完成"不涨且"在途"堆积 → 卡在 MethodChannel / platform thread；
  //   - 两者都在涨但画面慢 → 卡在解码/上屏（看原生心跳的光栅回调与上传）。
  // 判据写进 AGENTS.md §12.8。
  final Stopwatch _throughputClock = Stopwatch()..start();
  static const Duration _throughputLogInterval = Duration(seconds: 1);
  Duration _lastThroughputLogAt = Duration.zero;
  int _framesIssued = 0;
  int _framesCompleted = 0;
  int _framesFailed = 0;
  int _inFlight = 0;
  int _inFlightPeak = 0;
  int _loggedIssued = 0;
  int _loggedCompleted = 0;

  /// 解码器返回的真实画面尺寸变化（投流中可能随设备旋转变化）。
  Stream<VideoSize> get sizeChanges => _sizeChanges.stream;

  /// 最近一次从原生侧拿到的尺寸；从未拿到过时为 null。
  VideoSize? get lastSize => _lastSize;

  /// 是否已经拿到纹理（用于 UI 决定渲染 Texture 还是占位图）。
  bool get hasTexture => _hasTexture;

  /// 创建解码器并返回纹理 id。
  Future<Result<int>> create() async {
    _installHandler();
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('create');
      final textureId = raw?['textureId'];
      if (textureId is! int) {
        return Result.failure(const RemoteException(message: '原生解码器没有返回纹理 id'));
      }
      _hasTexture = true;
      // 回执里已经带了尺寸（可能是 1280x720 占位值），真实尺寸等后续回执刷新。
      _applySizeFromReply(raw);
      _logger.info('原生解码器就绪：textureId=$textureId');
      return Result.success(textureId);
    } on MissingPluginException catch (error, stackTrace) {
      return Result.failure(
        RemoteException(
          message: '当前平台没有原生解码器实现（目前支持 Android / Windows / iOS / macOS）',
          exception: error,
          stackTrace: stackTrace,
        ),
      );
    } on PlatformException catch (error, stackTrace) {
      _logger.warn('创建原生解码器失败', error, stackTrace);
      return Result.failure(
        RemoteException(
          message: error.message ?? '创建原生解码器失败',
          exception: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  /// 主动拉取当前解码尺寸（原生侧同步返回，不会阻塞）。
  ///
  /// 返回 null 表示当前平台没有实现 / 通道不可用；此时保留上一次已知尺寸，
  /// **不要**把它当成"尺寸变成未知"（否则 UI 会闪回 16:9 占位）。
  Future<VideoSize?> getSize() async {
    if (!_hasTexture) {
      return _lastSize;
    }
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('getSize');
      return _applySizeFromReply(raw);
    } on PlatformException catch (error, stackTrace) {
      _logger.warn('读取解码尺寸失败', error, stackTrace);
      return _lastSize;
    } on MissingPluginException {
      // 平台没实现 getSize（例如 Android 仍在用反向推送）：保留上一次尺寸。
      return _lastSize;
    }
  }

  /// 喂一帧 Annex-B；调用方可以不等结果（帧率很高），失败会记录日志。
  ///
  /// 回执里带回 `{width, height}`（Windows 实现），顺手更新尺寸；
  /// 没有带回尺寸的实现（例如 Android 的旧契约）就什么也不做。
  Future<Result<void>> pushFrame(Uint8List frame) async {
    if (!_hasTexture) {
      return failureVoid(const BusinessException(message: '解码器尚未就绪，无法喂帧'));
    }
    _framesIssued++;
    _inFlight++;
    if (_inFlight > _inFlightPeak) {
      _inFlightPeak = _inFlight;
    }
    Result<void> result;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'pushFrame',
        frame,
      );
      _applySizeFromReply(raw);
      result = successVoid();
    } on PlatformException catch (error, stackTrace) {
      result = failureVoid(
        RemoteException(
          message: error.message ?? '喂帧失败',
          exception: error,
          stackTrace: stackTrace,
        ),
      );
    } on MissingPluginException catch (error, stackTrace) {
      result = failureVoid(
        RemoteException(
          message: '当前平台没有原生解码器实现（目前支持 Android / Windows / iOS / macOS）',
          exception: error,
          stackTrace: stackTrace,
        ),
      );
    }
    _inFlight--;
    _framesCompleted++;
    if (result.isError) {
      _framesFailed++;
    }
    _maybeLogThroughput();
    return result;
  }

  /// 释放解码器与纹理；可重复调用。
  Future<void> release() async {
    if (!_hasTexture) {
      return;
    }
    _hasTexture = false;
    _lastSize = null;
    try {
      await _channel.invokeMethod<void>('release');
    } on PlatformException catch (error, stackTrace) {
      _logger.warn('释放原生解码器失败', error, stackTrace);
    } on MissingPluginException {
      // 通道不存在（未实现原生解码的平台）：无需释放。
    }
  }

  Future<void> dispose() async {
    await release();
    await _sizeChanges.close();
  }

  /// 解析尺寸回执并（尺寸变化时）广播出去；返回解析到的尺寸（没有则返回上一次的）。
  ///
  /// 尺寸为 0 视为"未知"，直接忽略——原生侧解码器还没创建时就是 0x0。
  VideoSize? _applySizeFromReply(Object? reply) {
    if (reply is! Map) {
      return _lastSize;
    }
    final width = reply['width'];
    final height = reply['height'];
    if (width is! int || height is! int || width <= 0 || height <= 0) {
      return _lastSize;
    }
    final size = VideoSize(width, height);
    if (_lastSize == size) {
      return _lastSize;
    }
    _lastSize = size;
    if (!_sizeChanges.isClosed) {
      _sizeChanges.add(size);
    }
    return size;
  }

  /// 每秒一条的帧吞吐日志（只在有帧流动时写；见上面计数器的注释）。
  void _maybeLogThroughput() {
    final elapsed = _throughputClock.elapsed;
    if (elapsed - _lastThroughputLogAt < _throughputLogInterval) {
      return;
    }
    final issuedDelta = _framesIssued - _loggedIssued;
    final completedDelta = _framesCompleted - _loggedCompleted;
    _lastThroughputLogAt = elapsed;
    _loggedIssued = _framesIssued;
    _loggedCompleted = _framesCompleted;
    _logger.info(
      '帧吞吐/s：发起 +$issuedDelta（累计 $_framesIssued），'
      '完成 +$completedDelta（累计 $_framesCompleted，失败 $_framesFailed），'
      '在途峰值 $_inFlightPeak（当前 $_inFlight）',
    );
  }

  /// 安装入站方法处理器。
  ///
  /// Windows（本次改动后）**不再**发送任何入站方法，尺寸全走回执/拉取；
  /// Android 目前仍然用 `onSizeChanged` 反向推送，所以这里保留处理器——不然
  /// Dart 侧会因为"没有注册处理器"直接把它当错误，Android 的尺寸变化就全丢了。
  /// （Android 的推送发生在 platform thread 上、且对象生命周期由插件持有，
  /// 不存在 Windows 那类"投递任务活过状态"的竞态。）
  void _installHandler() {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onSizeChanged') {
        _applySizeFromReply(call.arguments);
      }
      return null;
    });
  }
}
