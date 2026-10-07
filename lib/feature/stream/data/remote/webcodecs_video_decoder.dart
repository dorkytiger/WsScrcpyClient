import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/h264_annex_b.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/video_decoder.dart';

/// web 端的解码器：浏览器 **WebCodecs**（`VideoDecoder`）+ canvas 平台视图。
///
/// 与原生三端的关系（`AGENTS.md` §9.3 阶段二）：
/// - 输入一样是**裸 Annex-B、一条 WS 消息一帧**；
/// - 但 WebCodecs 需要三样原生端不需要的东西，所以这一端自己解析：
///   1. `codec` 串（`avc1.PPCCLL`）——从 SPS 头三个字节来（[H264AnnexB]）；
///   2. 每条 chunk 是 `key` 还是 `delta`——看有没有 IDR（type 5）；
///   3. 画面往哪摆——DOM 元素不参与 Flutter 绘制，只能按 [VideoViewport] 写 CSS。
/// - **不传 `VideoDecoderConfig.description`**：那样浏览器按 Annex-B（起始码）解释输入，
///   省掉"Annex-B → AVCC"这一步（服务端自己的 WebCodecsPlayer 也是这么干的，见 §9.3）。
///
/// **平台视图只建一次**：Flutter web 的平台视图按 viewType 注册，注册第二次会抛；
/// 而且同一个 stream 关闭再开（[release] → [create]）时要复用同一个 DOM 元素，
/// 否则视图层拿到的是被我们丢掉的旧元素。所以 DOM 是 static 的，只有解码器是每实例的。
class WebCodecsVideoDecoder extends VideoDecoder {
  WebCodecsVideoDecoder({AppLogger? logger})
    : _logger = logger ?? AppLogger('WebCodecs');

  /// 平台视图类型；视图层 `HtmlElementView(viewType: …)` 用它取到我们建的 DOM。
  static const String viewType = 'ws_scrcpy/web-video';

  /// 帧时间戳用的假步长：投流协议不带时间戳，WebCodecs 又要求单调递增，
  /// 所以按 60fps 递增（只用来排序，不表示真实时间）。
  static const int _frameStepMicros = 16666;

  final AppLogger _logger;
  final StreamController<VideoSize> _sizeChanges =
      StreamController<VideoSize>.broadcast();

  static web.HTMLDivElement? _container;
  static web.HTMLCanvasElement? _canvas;
  static web.CanvasRenderingContext2D? _context;
  static bool _viewFactoryRegistered = false;

  web.VideoDecoder? _decoder;
  VideoViewport? _viewport;
  VideoSize? _lastSize;
  String? _codec;
  bool _configured = false;
  bool _hasCanvas = false;
  int _frameIndex = 0;
  int _decodedCount = 0;
  int _decodeErrorCount = 0;

  /// WebCodecs 的错误是**异步回调**（没有地方直接返回给调用方），
  /// 所以先记下来，由下一次 [pushFrame] 带回给 viewmodel（UI 会显示可读错误 + 重试入口）。
  String? _pendingError;

  @override
  Stream<VideoSize> get sizeChanges => _sizeChanges.stream;

  @override
  VideoSize? get lastSize => _lastSize;

  @override
  bool get hasTexture => _hasCanvas;

  @override
  Future<Result<int>> create() async {
    try {
      _ensureDom();
      _decoder?.close();
      _decoder = web.VideoDecoder(
        web.VideoDecoderInit(
          output: _onDecodedFrame.toJS,
          error: _onDecoderError.toJS,
        ),
      );
    } catch (error, stackTrace) {
      _logger.warn('创建 WebCodecs 解码器失败', error, stackTrace);
      return Result.failure(
        RemoteException(
          message:
              '创建 WebCodecs 解码器失败：$error'
              '（浏览器需支持 WebCodecs；Safari 16.4+ / Chrome 94+）',
          exception: error,
          stackTrace: stackTrace,
        ),
      );
    }
    _configured = false;
    _codec = null;
    _frameIndex = 0;
    _decodedCount = 0;
    _pendingError = null;
    _hasCanvas = true;
    // web 上没有纹理 id：给视图层一个占位值，渲染分支按平台选（见 player_page.dart）。
    return Result.success(0);
  }

  @override
  Future<Result<void>> pushFrame(Uint8List frame) async {
    if (!_hasCanvas || _decoder == null) {
      return failureVoid(const BusinessException(message: '解码器尚未就绪，无法喂帧'));
    }
    final pending = _pendingError;
    if (pending != null) {
      _pendingError = null;
      return failureVoid(RemoteException(message: 'WebCodecs 解码失败：$pending'));
    }

    // 第一条带 SPS 的消息决定 codec 串；在那之前没什么可做的（scrcpy 开头就先发参数集）。
    if (!_configured) {
      final codec = H264AnnexB.avcCodecString(frame);
      if (codec == null) {
        return successVoid();
      }
      _configure(codec);
    }

    // 只含参数集、不含片数据的那条：作用只是让我们知道分辨率 / 配好解码器，不能当样本喂。
    final units = H264AnnexB.split(frame);
    if (units.isEmpty) {
      if (_decodeErrorCount == 0) {
        _logger.warn('拒绝一条不含起始码的视频消息（${frame.length} 字节）——协议约定是 Annex-B');
        _decodeErrorCount++;
      }
      return successVoid();
    }
    final hasSlice = units.any(
      (H264NalUnit unit) => unit.type == 1 || unit.type == 5,
    );
    if (!hasSlice) {
      return successVoid();
    }

    final isKey = units.any((H264NalUnit unit) => unit.type == 5);
    final timestamp = _frameIndex * _frameStepMicros;
    _frameIndex++;
    try {
      _decoder!.decode(
        web.EncodedVideoChunk(
          web.EncodedVideoChunkInit(
            type: isKey ? 'key' : 'delta',
            timestamp: timestamp,
            data: frame.toJS,
          ),
        ),
      );
    } catch (error, stackTrace) {
      _logger.warn('WebCodecs decode 抛异常', error, stackTrace);
      return failureVoid(
        RemoteException(
          message: 'WebCodecs decode 失败：$error',
          exception: error,
          stackTrace: stackTrace,
        ),
      );
    }
    return successVoid();
  }

  /// web 没有"拉尺寸"这一步（尺寸在输出回调里），返回最近一次已知值。
  @override
  Future<VideoSize?> getSize() async => _lastSize;

  @override
  Future<void> release() async {
    _hasCanvas = false;
    _configured = false;
    _lastSize = null;
    try {
      _decoder?.close();
    } catch (error, stackTrace) {
      _logger.warn('关闭 WebCodecs 解码器失败', error, stackTrace);
    }
    _decoder = null;
    // DOM 元素**不销毁**：Flutter web 的平台视图按 viewType 复用，销毁了下次就接不上。
    _clearCanvas();
  }

  @override
  Future<void> dispose() async {
    await release();
    await _sizeChanges.close();
  }

  /// 按 contain/cover 把 canvas 摆到控件里；CSS 像素 == Flutter 逻辑像素。
  @override
  void applyDisplayGeometry(VideoViewport? viewport) {
    _viewport = viewport;
    _applyGeometry();
  }

  // ---------------------------------------------------------------------------
  // 内部：DOM / 解码回调 / 几何
  // ---------------------------------------------------------------------------

  void _ensureDom() {
    if (_canvas != null) {
      return;
    }
    final container = web.document.createElement('div') as web.HTMLDivElement;
    container.style
      ..position = 'absolute'
      ..left = '0'
      ..top = '0'
      ..width = '100%'
      ..height = '100%'
      ..overflow = 'hidden'
      ..backgroundColor = '#000'
      // ★ 不能让 DOM 抢走指针事件：画面上的点击/拖动要留给 Flutter 的 Listener
      // （触摸坐标是按 [VideoViewport] 算的，被 DOM 截走就等于整条输入链路失效）。
      ..pointerEvents = 'none';
    final canvas = web.document.createElement('canvas') as web.HTMLCanvasElement;
    canvas.style
      ..position = 'absolute'
      ..pointerEvents = 'none';
    container.appendChild(canvas);
    _container = container;
    _canvas = canvas;
    _context = canvas.getContext('2d') as web.CanvasRenderingContext2D?;
    if (_context == null) {
      throw StateError('拿不到 canvas 2d 上下文，WebCodecs 的画面没地方画');
    }
    _registerViewFactory();
  }

  void _registerViewFactory() {
    if (_viewFactoryRegistered) {
      return;
    }
    ui_web.platformViewRegistry.registerViewFactory(
      viewType,
      (int viewId) => _container!,
    );
    _viewFactoryRegistered = true;
    _logger.info('web 视频平台视图已注册：$viewType（canvas + 2d 上下文）');
  }

  void _configure(String codec) {
    _codec = codec;
    _decoder!.configure(
      web.VideoDecoderConfig(codec: codec, optimizeForLatency: true),
    );
    _configured = true;
    _logger.info(
      'WebCodecs 已配置：codec=$codec，optimizeForLatency=true，'
      'Annex-B 输入（不传 description，见 AGENTS §9.3）',
    );
  }

  void _onDecodedFrame(web.VideoFrame frame) {
    try {
      final width = frame.displayWidth > 0
          ? frame.displayWidth
          : frame.codedWidth;
      final height = frame.displayHeight > 0
          ? frame.displayHeight
          : frame.codedHeight;
      final canvas = _canvas;
      final context = _context;
      if (canvas == null || context == null || width <= 0 || height <= 0) {
        return;
      }
      if (canvas.width != width || canvas.height != height) {
        canvas.width = width;
        canvas.height = height;
      }
      context.drawImage(frame, 0, 0);
      _applyGeometry();
      _decodedCount++;
      if (_decodedCount == 1) {
        _logger.info('已解出第一帧并画进 canvas（${width}x$height）');
      }
      final size = VideoSize(width, height);
      if (_lastSize != size) {
        _lastSize = size;
        if (!_sizeChanges.isClosed) {
          _sizeChanges.add(size);
        }
      }
    } finally {
      // 必须关：VideoFrame 持有解码器缓冲，不关会把解码器憋死（浏览器只给有限几张）。
      frame.close();
    }
  }

  void _onDecoderError(web.DOMException error) {
    _decodeErrorCount++;
    _pendingError = error.message;
    if (_decodeErrorCount <= 3 || _decodeErrorCount % 60 == 0) {
      _logger.warn(
        'WebCodecs 解码错误（第 $_decodeErrorCount 次）：${error.message}'
        '${_codec == null ? '' : '（codec=$_codec）'}',
      );
    }
  }

  void _clearCanvas() {
    final canvas = _canvas;
    final context = _context;
    if (canvas == null || context == null) {
      return;
    }
    context.clearRect(0, 0, canvas.width.toDouble(), canvas.height.toDouble());
  }

  void _applyGeometry() {
    final canvas = _canvas;
    if (canvas == null) {
      return;
    }
    final viewport = _viewport;
    if (viewport == null || !viewport.isUsable) {
      // 还没有画面尺寸：先铺满控件（黑底），等第一帧到了再摆。
      canvas.style
        ..left = '0'
        ..top = '0'
        ..width = '100%'
        ..height = '100%';
      return;
    }
    // 与触摸换算**同一套数字**：contain 时偏移是黑边（≥0），cover 时是负数（画面被裁）。
    // 容器有 overflow:hidden，所以 cover 多出来的部分正好被裁掉，和 ClipRect 同理。
    canvas.style
      ..left = '${viewport.offsetX}px'
      ..top = '${viewport.offsetY}px'
      ..width = '${viewport.displayWidth}px'
      ..height = '${viewport.displayHeight}px';
  }
}
