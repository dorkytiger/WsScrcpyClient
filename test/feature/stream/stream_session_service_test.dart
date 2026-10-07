import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/control/android_key_code.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';
import 'package:ws_scrcpy_client/core/stream/video_settings.dart';
import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';
import 'package:ws_scrcpy_client/core/ws/ws_error_translator.dart';
import 'package:ws_scrcpy_client/feature/stream/application/service/stream_session_service.dart';
import 'package:ws_scrcpy_client/feature/stream/data/model/bo/stream_session_snapshot.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/stream_remote_datasource.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/stream_connection_status.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/video_bounds_mode.dart';

import '../../core/stream/stream_fixtures.dart';

/// 假传输：测试可以直接"推"初始信息头与视频帧，并检查客户端发出去的字节。
class _FakeTransport implements WebSocketTransport {
  final StreamController<Object> _controller =
      StreamController<Object>.broadcast();
  final List<Uint8List> sent = <Uint8List>[];

  @override
  bool isOpen = true;

  @override
  Stream<Object> get messages => _controller.stream;

  @override
  void sendBinary(Uint8List data) => sent.add(data);

  @override
  Future<void> close([int code = 1000, String? reason]) async {
    isOpen = false;
    await _controller.close();
  }

  void emit(Object message) => _controller.add(message);
}

/// 返回预置会话的数据源（不碰真实网络）。
class _FakeStreamRemoteDatasource extends StreamRemoteDatasource {
  _FakeStreamRemoteDatasource(this.transport);

  final _FakeTransport transport;

  @override
  Future<Result<StreamSession>> connect({
    required Uri uri,
    String? authorization,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!transport.isOpen) {
      return Result.failure(const RemoteException(message: '测试用：连接失败'));
    }
    return Result.success(StreamSession.fromTransport(uri, transport));
  }
}

void main() {
  final target = StreamTarget(
    serverUri: Uri.parse('https://android.dorkytiger.top/'),
    udid: 'redroid:5555',
    interfaceHosts: const <String>['192.168.112.2'],
  );

  late _FakeTransport transport;
  late StreamSessionService service;

  setUp(() {
    transport = _FakeTransport();
    // 兜底延时设成 0：这些用例大多在"UI 还没报视口尺寸"的前提下跑，
    // 让首发参数的退化路径在 pumpEventQueue() 里立刻发生，测试才确定。
    service = StreamSessionService(
      _FakeStreamRemoteDatasource(transport),
      settingsFallbackDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await service.dispose();
  });

  /// 按控制消息类型筛出客户端发出去的帧（首字节就是 type）。
  ///
  /// 为什么需要它：连上之后还会发唤醒键（如果开了）与尺寸补发，直接数 `sent.length`
  /// 会让"只下发一次参数"这类断言变得又脆又难读。
  List<Uint8List> framesOfType(int type) => transport.sent
      .where((Uint8List frame) => frame.isNotEmpty && frame[0] == type)
      .toList(growable: false);

  /// keycode 消息里的按键值（偏移 2 起 4 字节大端）。
  int keyCodeOf(Uint8List frame) =>
      ByteData.sublistView(frame).getInt32(2, Endian.big);

  /// 从 CHANGE_STREAM_PARAMETERS 帧里解出视频参数（首字节是 type，其后是参数结构）。
  VideoSettings settingsOf(Uint8List frame) =>
      VideoSettings.fromBuffer(Uint8List.sublistView(frame, 1));

  test('初始信息头 → 解析出设备与分辨率，并下发一次视频参数', () async {
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();

    final snapshot = service.snapshot;
    expect(snapshot.deviceName, 'redroid12_x86_64_only');
    expect(snapshot.display, isNotNull);
    expect(snapshot.display!.displayInfo.size.width, greaterThan(0));

    // 视频参数必须**只下发一次**（多发会把服务端拖进反馈循环，编码器反复重启）。
    final settings = framesOfType(
      ControlMessageType.changeStreamParameters.code,
    );
    expect(settings, hasLength(1));
    // 而且它必须是第一条发出去的消息。
    expect(
      transport.sent.first[0],
      ControlMessageType.changeStreamParameters.code,
    );
  });

  test('首发视频参数：回显服务端给的值，而不是本地默认值', () async {
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();

    final sent = settingsOf(
      framesOfType(ControlMessageType.changeStreamParameters.code).single,
    );
    // 夹具（真实服务端初始头）里服务端给的是 bitrate 7340032 / maxFps 60 /
    // iFrameInterval 10 / bounds 1856x960；以前我们发的是本地默认
    // 8000000 / 0 / 10 / null，与服务端网页端行为不一致。
    expect(sent.bitrate, 7340032);
    expect(sent.maxFps, 60);
    expect(sent.iFrameInterval, 10);
    expect(sent.displayId, 0);
    // sendFrameMeta 必须为 false：我们解的是裸 Annex-B，不解析每帧前 12 字节帧信息。
    expect(sent.sendFrameMeta, isFalse);
    // UI 还没报尺寸：沿用服务端给的 bounds，但**必须收敛到设备原生范围内 + 设备同比例 + 16 对齐**
    // （服务端给的 1856x960 大于原生 1280x720；见 AGENTS §12.7/§12.8）。
    expect(sent.bounds, const VideoSize(1280, 720));
  });

  test('首发只发一条且带上 UI 的最终视口尺寸（不先发 null 再补发）', () async {
    await service.start(target);
    // UI 先布局（真实顺序就是这样：页面 build 往往早于初始信息头到达）。
    service.applyViewportBounds(width: 1898, height: 853);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();

    // 连发两条（先 bounds:null、再实际尺寸）会让服务端重建两次编码器，
    // 重建后不会立刻出 IDR → 黑屏，直到画面变化才有帧。所以必须一次到位。
    final settings = framesOfType(
      ControlMessageType.changeStreamParameters.code,
    );
    expect(settings, hasLength(1), reason: '首发必须一次到位，不能补发第二条');
    // 视口 1898x853 大于设备原生 1280x720 → 按比例收敛，**绝不要求放大**（AGENTS §12.7），
    // 并向下对齐到 16×16 宏块（§12.8：非对齐尺寸的流 MF 解不出来）。
    // 先按设备比例（16:9）把视口收成 1516x853 的框，再收到原生范围内 → 1280x720。
    expect(settingsOf(settings.single).bounds, const VideoSize(1280, 720));

    // 初始信息头再来（服务端重发很常见）也不该再发第二条。
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();
    expect(
      framesOfType(ControlMessageType.changeStreamParameters.code),
      hasLength(1),
    );
  });

  test('UI 尺寸晚于初始信息头：兜底那条等价时不再补发，视口真的更小时才补', () async {
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue(); // 兜底定时器（测试里是 0ms）在这一步触发

    final first = settingsOf(
      framesOfType(ControlMessageType.changeStreamParameters.code).single,
    );
    expect(
      first.bounds,
      const VideoSize(1280, 720),
      reason: '等不到 UI 尺寸时用服务端给的值，但仍要收敛到原生范围内（不放大）+ 同设备比例 + 16 对齐',
    );

    // UI 布局好了，报上桌面窗口那样的视口：收敛后**还是原生 1280x720**，
    // 与兜底那条完全等价 → **不该再发**（每多发一条服务端就重建一次编码器）。
    service.applyViewportBounds(width: 1898, height: 853);
    expect(
      framesOfType(ControlMessageType.changeStreamParameters.code),
      hasLength(1),
      reason: '去重比的是收敛后的生效边界：兜底那条已经等价，不必再补一条',
    );

    // 视口真的小到"收敛结果不同"（800x600 → 800x448）时才补一条。
    service.applyViewportBounds(width: 800, height: 600);
    final settings = framesOfType(
      ControlMessageType.changeStreamParameters.code,
    );
    expect(settings, hasLength(2));
    expect(settingsOf(settings.last).bounds, const VideoSize(800, 448));
  });

  test('重复收到初始信息头时只下发一次视频参数（防反馈循环）', () async {
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();
    transport.emit(loadInitialInfoFixture());
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();

    // 下发多次会把服务端拖进"改参数 → 重发初始头"的循环，编码器反复重启。
    expect(
      framesOfType(ControlMessageType.changeStreamParameters.code),
      hasLength(1),
    );
  });

  test('唤醒是可选项：默认关，打开后发一次 KEYCODE_WAKEUP', () async {
    // 默认关：真实服务端 bundle 里网页端根本不发唤醒键，黑屏的正解是"只发一次参数 +
    // 回显服务端值"，唤醒只是给"屏幕休眠导致不出帧"的设备留的可选开关。
    expect(service.wakeOnConnect, isFalse);
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();
    expect(framesOfType(ControlMessageType.keycode.code), isEmpty);

    // 打开开关 → 立刻补发一次（用户在面板里刚点的开关要马上有反馈）。
    service.wakeOnConnect = true;
    final keyCodes = framesOfType(ControlMessageType.keycode.code);
    expect(keyCodes, hasLength(2), reason: '唤醒键应该是 down + up 两条');
    expect(keyCodeOf(keyCodes[0]), AndroidKeyCode.wakeup);
    expect(keyCodeOf(keyCodes[1]), AndroidKeyCode.wakeup);
    // 第 1 字节是动作：0=down，1=up。
    expect(keyCodes[0][1], 0);
    expect(keyCodes[1][1], 1);

    // 重复收到初始信息头不会再发一次唤醒（每条连接只发一次）。
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();
    expect(framesOfType(ControlMessageType.keycode.code), hasLength(2));
  });

  test('开了自动唤醒时：参数下发成功后自动发一次唤醒键', () async {
    service.wakeOnConnect = true;
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();

    expect(framesOfType(ControlMessageType.keycode.code), hasLength(2));
    expect(
      keyCodeOf(framesOfType(ControlMessageType.keycode.code)[0]),
      AndroidKeyCode.wakeup,
    );
  });

  test('未连接时唤醒返回失败而不是抛异常', () {
    expect(service.wakeDevice().isError, isTrue);
  });

  test('视频帧按 Annex-B 原样转发到 videoFrames 流，并累计计数', () async {
    final frames = <Uint8List>[];
    final subscription = service.videoFrames.listen(frames.add);
    addTearDown(subscription.cancel);

    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();

    final fixtureFrames = loadVideoFrameFixture();
    for (final frame in fixtureFrames) {
      transport.emit(frame);
    }
    await pumpEventQueue();

    expect(frames, hasLength(fixtureFrames.length));
    expect(frames.first, fixtureFrames.first);
    expect(service.snapshot.videoFrameCount, fixtureFrames.length);
    expect(service.snapshot.status, StreamConnectionStatus.streaming);
  });

  test('初始信息头不会被当成视频帧', () async {
    final frames = <Uint8List>[];
    final subscription = service.videoFrames.listen(frames.add);
    addTearDown(subscription.cancel);

    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();

    expect(frames, isEmpty);
    expect(service.snapshot.videoFrameCount, 0);
  });

  test('没有订阅者时视频帧不会撑爆内存（广播流直接丢弃）', () async {
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();

    for (final frame in loadVideoFrameFixture()) {
      transport.emit(frame);
    }
    await pumpEventQueue();

    // 只统计、不缓存：没有 videoFrames 订阅者时不应抛错或阻塞。
    expect(service.snapshot.videoFrameCount, loadVideoFrameFixture().length);
  });

  test('解析初始信息头后能发控制消息（按键走同一条连接）', () async {
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();

    final result = service.pressNavigationKey(NavigationKey.home);
    expect(result.isSuccess, isTrue);
    // 默认不开唤醒，所以 keycode 帧只有 Home 的 down/up。
    final keyCodes = framesOfType(ControlMessageType.keycode.code);
    expect(keyCodes, hasLength(2));
    expect(keyCodeOf(keyCodes[0]), NavigationKey.home.keyCode);
    expect(keyCodeOf(keyCodes[1]), NavigationKey.home.keyCode);
  });

  test('未连接时发控制消息返回失败而不是抛异常', () {
    final result = service.pressKey(3);
    expect(result.isError, isTrue);
  });

  test('按窗口更新编码边界：下发一次，重复相同尺寸不再下发', () async {
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();
    // 这一步的首发用的是服务端给的 bounds（UI 还没报尺寸）。
    final sentAfterHandshake = transport.sent.length;

    expect(
      service.applyViewportBounds(width: 1080, height: 2400).isSuccess,
      isTrue,
    );
    expect(transport.sent.length, sentAfterHandshake + 1);

    // 同一尺寸再来一次（旋转过程中的重复回调）不应该再下发。
    service.applyViewportBounds(width: 1080, height: 2400);
    expect(transport.sent.length, sentAfterHandshake + 1);

    // 尺寸变了才再发一次（横屏）。
    service.applyViewportBounds(width: 2400, height: 1080);
    expect(transport.sent.length, sentAfterHandshake + 2);
  });

  test('未连接时上报尺寸不算失败：只记录，连接后首发带上它', () async {
    // 真实顺序就是这样：页面一 build 就上报尺寸，而连接/初始信息头还没到。
    // 这一步必须成功（否则首发就拿不到最终尺寸，只能先发 null 再补发 → 编码器重建两次）。
    final result = service.applyViewportBounds(width: 100, height: 100);
    expect(result.isSuccess, isTrue);
    expect(transport.sent, isEmpty, reason: '还没连接，不该发任何东西');

    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();

    final settings = framesOfType(
      ControlMessageType.changeStreamParameters.code,
    );
    expect(settings, hasLength(1));
    // 100x100 不是设备比例（16:9），也不是 16 的整数倍：
    // 先按设备比例收成 100x56.25，再向下对齐成 96x48（宏块对齐，见 §12.8）。
    expect(settingsOf(settings.single).bounds, const VideoSize(96, 48));
  });

  test('编码边界一律向下对齐到 16 宏块：非对齐尺寸的流解码器解不出来', () {
    // 真机实测（AGENTS §12.8）：下发 1280x575（奇数、非 16 对齐）时，
    // 日志是"已喂入 12 / 已发布 0 / ProcessOutput 需更多输入 12 / 流格式变化 0 次"，
    // 即解码器压根没解析出参数集；而下发 1280x720 / 992x560（都是 16 对齐）时正常出帧。
    const native = VideoSize(1280, 720);
    expect(
      StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(1898, 853),
        native: native,
      ),
      const VideoSize(1280, 720),
      reason: '先按设备比例收框（1516x853）再收到原生范围内 → 正好原生满分辨率，且 16 对齐',
    );
    expect(
      StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(999, 601),
        native: native,
      ),
      const VideoSize(992, 560),
      reason: '视口 ≤ 原生：保持不放大，但仍要按设备比例收框并对齐',
    );
    expect(
      StreamSessionService.clampBoundsToNative(
        viewport: const VideoSize(10, 10),
        native: native,
      ),
      const VideoSize(16, 16),
      reason: '极小视口不会被对齐成 0',
    );
  });

  // ---------------------------------------------------------------------------
  // 编码边界策略（清晰度取舍）：网页端更清楚就是因为它的 bounds 不封顶到原生
  // ---------------------------------------------------------------------------

  test('★ 清晰优先：允许编码超过设备原生（上限 2 倍），网页端就是这么干的', () {
    const native = VideoSize(1280, 720);
    // 1898x853 就是 §12.7 那次真机实测的 Ui 视口（同比例收框后是 1516x853）。
    expect(
      StreamSessionService.clampBoundsForMode(
        viewport: const VideoSize(1898, 853),
        native: native,
        mode: VideoBoundsMode.viewport,
      ),
      const VideoSize(1504, 848),
      reason: '清晰优先下不再封顶到原生，只受"原生 ×2"上限约束，再 16 对齐',
    );
    expect(
      StreamSessionService.clampBoundsForMode(
        viewport: const VideoSize(6000, 3376),
        native: native,
        mode: VideoBoundsMode.viewport,
      ),
      const VideoSize(2560, 1440),
      reason: '窗口再大也只到原生 2 倍：容器里的软编码器扛不住更高',
    );
    expect(
      StreamSessionService.clampBoundsForMode(
        viewport: const VideoSize(1898, 853),
        native: native,
        mode: VideoBoundsMode.nativeCap,
      ),
      const VideoSize(1280, 720),
      reason: '省设备算力模式保持原行为（AGENTS §12.7：绝不向设备要放大）',
    );
  });

  test('★ 转屏不改编码边界：一条消息都不发（服务端不会重建编码器）', () async {
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();
    // 手机竖屏：402x698 逻辑 @3 → 1206x2094 物理。
    service.applyViewportBounds(width: 1206, height: 2094);
    final afterPortrait = transport.sent.length;
    expect(
      settingsOf(
        framesOfType(ControlMessageType.changeStreamParameters.code).last,
      ).bounds,
      const VideoSize(1280, 720),
      reason: '竖屏贴原生 → 吸附成原生（免得转屏时来回改边界）',
    );

    // 转成横屏：874x402 逻辑 @3 → 2622x1206 物理。
    service.applyViewportBounds(width: 2622, height: 1206);
    expect(
      transport.sent.length,
      afterPortrait,
      reason: '转屏前后边界都是原生 1280x720，去重应该吃掉第二条：'
          '每多发一条服务端就重建一次编码器，重建后要等新的 IDR（10s）→ 画面停住几十秒',
    );
    expect(
      service.viewportUpdateSequence,
      0,
      reason: '连竖屏那次都不需要补发：首发用的服务端边界收敛后本来就是原生 1280x720，'
          '转屏前后都一样 → 编码器全程不重建',
    );
  });

  test('★ 切换清晰优先：立刻按当前视口补发一条参数（尺寸没变也要发）', () async {
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();
    // UI 报上来的视口就是 §12.7 那次实测的 1898x853。
    service.applyViewportBounds(width: 1898, height: 853);
    final framesBefore = framesOfType(
      ControlMessageType.changeStreamParameters.code,
    );
    expect(
      settingsOf(framesBefore.last).bounds,
      const VideoSize(1280, 720),
      reason: '默认省设备算力：封顶到设备原生',
    );

    final result = service.setBoundsMode(VideoBoundsMode.viewport);
    expect(result.isSuccess, isTrue);
    final framesAfter = framesOfType(
      ControlMessageType.changeStreamParameters.code,
    );
    expect(
      framesAfter,
      hasLength(framesBefore.length + 1),
      reason: '切换模式必须马上补发一条，否则用户点了开关看不到任何变化',
    );
    expect(
      settingsOf(framesAfter.last).bounds,
      const VideoSize(1504, 848),
      reason: '清晰优先：按画面区像素编码（不再封顶到 1280x720）',
    );

    // 切回去也要立刻生效，而且回到原生封顶。
    service.setBoundsMode(VideoBoundsMode.nativeCap);
    final framesBack = framesOfType(
      ControlMessageType.changeStreamParameters.code,
    );
    expect(framesBack, hasLength(framesAfter.length + 1));
    expect(settingsOf(framesBack.last).bounds, const VideoSize(1280, 720));
  });

  test('已发过参数后断开再改尺寸：返回失败而不是抛异常', () async {
    await service.start(target);
    transport.emit(loadInitialInfoFixture());
    await pumpEventQueue();
    await service.stop();

    final result = service.applyViewportBounds(width: 123, height: 456);
    expect(result.isError, isTrue);
  });

  /// ★ 回归（2026-10-02 用户实测："每次点击都要 basic auth"）。
  ///
  /// 服务端是 nginx 层的 Basic Auth，浏览器**不给 WebSocket 加自定义请求头**，
  /// 于是每次未认证握手都会再弹一次登录框。而自动重连（指数退避 + 多候选地址）
  /// 会把这个过程刷屏 —— 所以**鉴权失败必须停下来**，把提示和重试按钮交给用户。
  group('★ 鉴权失败不自动重连', () {
    test('鉴权失败 → 直接 failed，不再安排重连', () async {
      final service = StreamSessionService(
        _AuthFailingDatasource(),
        settingsFallbackDelay: Duration.zero,
      );
      addTearDown(service.dispose);

      final statuses = <StreamConnectionStatus>[];
      final subscription = service.snapshots.listen(
        (StreamSessionSnapshot s) => statuses.add(s.status),
      );
      addTearDown(subscription.cancel);

      final result = await service.start(
        target,
        authorization: 'Basic dGVzdDp0ZXN0',
      );

      expect(result.isError, isTrue);
      expect(
        isAuthFailure(result.error!),
        isTrue,
        reason: '翻译层应该把它认成鉴权失败：${result.error!.message}',
      );
      expect(service.snapshot.status, StreamConnectionStatus.failed);

      // 等一段明显超过首次退避的时间：若还安排了重连，这里会看到第 2 次尝试。
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        service.snapshot.status,
        StreamConnectionStatus.failed,
        reason: '鉴权失败后不该再自动重连（每次重连都会再弹一次浏览器登录框）',
      );
      expect(
        statuses.where((s) => s == StreamConnectionStatus.reconnecting),
        isEmpty,
        reason: '不该进入重连态，实际状态序列：$statuses',
      );
    });

    test('对照：非鉴权失败仍然照常重连（别把重连能力一起改坏）', () async {
      final service = StreamSessionService(
        // 这个假数据源在 transport 关闭时给的是普通失败，不含 Basic Auth 字样。
        _FakeStreamRemoteDatasource(_closedTransport()),
        settingsFallbackDelay: Duration.zero,
      );
      addTearDown(service.dispose);

      final statuses = <StreamConnectionStatus>[];
      final subscription = service.snapshots.listen(
        (StreamSessionSnapshot s) => statuses.add(s.status),
      );
      addTearDown(subscription.cancel);

      final result = await service.start(target);
      expect(result.isError, isTrue);
      expect(isAuthFailure(result.error!), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        statuses.contains(StreamConnectionStatus.reconnecting),
        isTrue,
        reason: '普通失败应该进入重连态，实际：$statuses',
      );
    });
  });
}

/// 一个"已经关掉"的假传输：让 [_FakeStreamRemoteDatasource] 走失败分支。
_FakeTransport _closedTransport() {
  final transport = _FakeTransport();
  transport.isOpen = false;
  return transport;
}

/// 返回"需要 Basic Auth"的失败（走真实的翻译函数，
/// 这样测试同时钉住了"翻译层认得出鉴权失败"这件事）。
class _AuthFailingDatasource extends StreamRemoteDatasource {
  @override
  Future<Result<StreamSession>> connect({
    required Uri uri,
    String? authorization,
    Duration timeout = const Duration(seconds: 10),
  }) async => Result.failure(
    translateHandshakeError(
      Exception(
        'WebSocketException: Connection to $uri was not upgraded '
        'to websocket (401 Unauthorized)',
      ),
      StackTrace.current,
    ),
  );
}
