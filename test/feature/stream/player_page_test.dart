import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/video_settings.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';
import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';
import 'package:ws_scrcpy_client/feature/stream/application/service/stream_session_service.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/stream_remote_datasource.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/video_decoder.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/video_bounds_mode.dart';
import 'package:ws_scrcpy_client/feature/stream/presentation/view/player_page.dart';
import 'package:ws_scrcpy_client/feature/stream/presentation/viewmodel/player_viewmodel.dart';

import '../../core/stream/stream_fixtures.dart';

/// 原生解码通道名（与 MainActivity.kt 的约定一致）。
const MethodChannel _videoChannel = MethodChannel('ws_scrcpy/video');

class _FakeTransport implements WebSocketTransport {
  final StreamController<Object> _controller =
      StreamController<Object>.broadcast();

  /// 客户端发出去的控制消息（用于断言触摸/按键确实按协议发出去了）。
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

/// 假解码器：只为验证"异步错误要立刻报出来"这条链路（web 的 WebCodecs 是回调式）。
class _FakeVideoDecoder extends VideoDecoder {
  final StreamController<VideoSize> _sizes =
      StreamController<VideoSize>.broadcast();
  final StreamController<String> _errors = StreamController<String>.broadcast();

  @override
  Stream<VideoSize> get sizeChanges => _sizes.stream;

  @override
  Stream<String> get asyncErrors => _errors.stream;

  @override
  VideoSize? get lastSize => null;

  @override
  bool get hasTexture => true;

  void emitError(String message) => _errors.add(message);

  @override
  Future<Result<int>> create() async => Result.success(7);

  @override
  Future<Result<void>> pushFrame(Uint8List frame) async => successVoid();

  @override
  Future<VideoSize?> getSize() async => null;

  @override
  Future<void> release() async {}

  @override
  Future<void> dispose() async {
    await _sizes.close();
    await _errors.close();
  }
}

/// 记录"被喂了哪些帧"的假解码器：验证 web 上的**补喂**（订阅之前到达的参数集 + IDR）。
class _RecordingVideoDecoder extends _FakeVideoDecoder {
  final List<Uint8List> pushed = <Uint8List>[];

  @override
  Future<Result<void>> pushFrame(Uint8List frame) async {
    pushed.add(frame);
    return successVoid();
  }
}

void main() {
  final target = StreamTarget(
    serverUri: Uri.parse('https://android.dorkytiger.top/'),
    udid: 'redroid:5555',
    interfaceHosts: const <String>['192.168.112.2'],
  );

  /// 用假的平台通道实现驱动解码分支：不给 mock 的话，未注册的通道调用**不会返回**，
  /// 测试会一直卡在"正在启动原生解码器…"。
  void mockVideoChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_videoChannel, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_videoChannel, null),
    );
  }

  Future<PlayerViewModel> pumpPlayer(
    WidgetTester tester,
    _FakeTransport transport, {
    bool withVideoFrame = false,
  }) async {
    final service = StreamSessionService(
      _FakeStreamRemoteDatasource(transport),
    );
    addTearDown(service.dispose);
    final viewModel = PlayerViewModel(service);
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(viewModel: viewModel, target: target, title: '测试设备'),
      ),
    );
    // 刻意不用 pumpAndSettle：加载态里有持续动画，永远 settle 不了。
    // 顺序也要对：先让 post-frame 里的 connect() 跑完并建立订阅，再推消息，
    // 否则广播流会把这条丢掉。
    await tester.pump();
    await tester.pump();
    transport.emit(loadInitialInfoFixture());
    await tester.pump();
    // 解码器创建要跨平台通道一拍：有界地多等几拍。
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (viewModel.decoderError != null ||
          viewModel.textureId != null ||
          !viewModel.isDecoderCreating) {
        break;
      }
    }
    // 视频帧必须在解码器就绪**之后**再推：更早的帧按设计会被广播流丢掉。
    if (withVideoFrame) {
      transport.emit(loadVideoFrameFixture().first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump();
    return viewModel;
  }

  testWidgets('底部快捷栏只保留 返回/主页/最近/更多 四个入口', (WidgetTester tester) async {
    final transport = _FakeTransport();
    await pumpPlayer(tester, transport);

    expect(find.text('返回'), findsOneWidget);
    expect(find.text('主页'), findsOneWidget);
    expect(find.text('最近'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);

    // 旧设计把音量/电源/旋转/面板平铺在底部，这次改版后不应该再出现。
    expect(find.text('音量 +'), findsNothing);
    expect(find.text('电源键'), findsNothing);
    expect(find.text('旋转屏幕'), findsNothing);
    expect(find.text('通知面板'), findsNothing);
  });

  testWidgets('低频动作收进"更多"面板，含断开投流（横屏小高度下不溢出）', (WidgetTester tester) async {
    final transport = _FakeTransport();
    await pumpPlayer(tester, transport);

    await tester.tap(find.text('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('音量 +'), findsOneWidget);
    expect(find.text('音量 −'), findsOneWidget);
    expect(find.text('电源键'), findsOneWidget);
    expect(find.text('旋转设备屏幕'), findsOneWidget);
    expect(find.text('唤醒设备屏幕'), findsOneWidget);
    expect(find.text('断开投流'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// ★ 回归（2026-10-02 真机截图）：iPhone 18 Pro **横屏**（874x402 逻辑点）下，
  /// 底部黄黑条报 `BOTTOM OVERFLOWED BY 3.9 PIXELS`。
  ///
  /// 默认的 800x600 测试画布**测不出**这类 bug（够高），必须显式摆成横屏手机。
  /// 横屏下会溢出的是**两处**，都要盯着：
  /// ① "更多"面板：`showModalBottomSheet` 默认把高度压到屏幕的 9/16，
  ///    而面板里的固定内容（标题 + 两行开关 + 两条分割线 + 断开按钮）超了这个上限，
  ///    里面那层 `Flexible + SingleChildScrollView` 兜不住；
  /// ② 画面占位组件：AppBar + 快捷栏之后只剩 ~280 点，装不下那堆状态文案
  ///    —— 真机首帧到达前就能看到。
  void landscapePhone(WidgetTester tester) {
    // iPhone 18 Pro 横屏：402 点高、DPR 3。
    tester.view.physicalSize = const Size(874 * 3, 402 * 3);
    tester.view.devicePixelRatio = 3;
    // 真机横屏时底部有 Home Indicator 的安全区（~21pt），SafeArea 会吃掉它，
    // 面板可用高度比"纯 402"更小 —— 这正是真机溢出、而纯 402 测不出来的差别。
    tester.view.padding = const FakeViewPadding(bottom: 21 * 3);
    addTearDown(tester.view.reset);
  }

  testWidgets('★ 横屏手机尺寸下：画面占位不溢出', (WidgetTester tester) async {
    landscapePhone(tester);
    final transport = _FakeTransport();
    await pumpPlayer(tester, transport); // 不给视频帧 → 走占位分支

    expect(
      tester.takeException(),
      isNull,
      reason: '横屏矮画布下画面占位溢出了（真机首帧到达前就能看到）',
    );
    expect(find.text('已连接，等待视频数据'), findsOneWidget);
  });

  testWidgets('★ 横屏手机尺寸下：打开"更多"面板不溢出', (WidgetTester tester) async {
    landscapePhone(tester);
    mockVideoChannel((MethodCall call) async {
      if (call.method == 'create') {
        return <Object?, Object?>{'textureId': 9};
      }
      return null;
    });
    final transport = _FakeTransport();
    await pumpPlayer(tester, transport, withVideoFrame: true);

    await tester.tap(find.text('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 溢出会被 Flutter 报成异常（debug 下的黄黑条），takeException 能抓到。
    expect(
      tester.takeException(),
      isNull,
      reason: '横屏小高度下面板溢出了（真机上就是那条 BOTTOM OVERFLOWED）',
    );
    // 内容仍在（放不下时靠滚动，不是被裁掉）。
    expect(find.text('连接后自动唤醒设备'), findsOneWidget);
    expect(find.text('断开投流'), findsOneWidget);
  });

  testWidgets('"更多"面板里有"连接后自动唤醒设备"开关，默认关且能打开', (WidgetTester tester) async {
    final transport = _FakeTransport();
    final viewModel = await pumpPlayer(tester, transport);

    await tester.tap(find.text('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('连接后自动唤醒设备'), findsOneWidget);
    // 面板里现在有**两个**开关（唤醒 + 铺满），按标题定位到唤醒那个。
    final switchFinder = find.ancestor(
      of: find.text('连接后自动唤醒设备'),
      matching: find.byType(SwitchListTile),
    );
    expect(switchFinder, findsOneWidget);
    // 默认**关**：唤醒只是可选项——真实服务端网页端并不发唤醒键，
    // 黑屏的正解是"视频参数只发一次 + 回显服务端值"（见 AGENTS §12.5）。
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
    expect(viewModel.wakeOnConnect, isFalse);

    await tester.tap(switchFinder);
    await tester.pump();
    expect(viewModel.wakeOnConnect, isTrue);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
  });

  testWidgets('非原生平台（Linux）：给出可读的降级说明，不尝试解码', (WidgetTester tester) async {
    // 注意：必须在测试体内还原，addTearDown 太晚——框架会在测试结束前断言
    // debugDefaultTargetPlatformOverride 已被清空。
    // 这里刻意用 Linux：Android / Windows / iOS / macOS 走系统硬解、web 走 WebCodecs，
    // 只剩 Linux 还没有实现（见 §1 的"待做"）。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(
        tester,
        transport,
        withVideoFrame: true,
      );

      expect(viewModel.isVideoDecodingSupported, isFalse);
      expect(viewModel.decoderError, isNull);
      expect(
        find.textContaining('Android / Windows / iOS / macOS（系统硬解）'),
        findsOneWidget,
      );
      expect(find.text('重试解码'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // iOS 与 macOS 走的是**同一份** darwin/ 解码器，Dart 侧只有"平台门禁"这一行不同，
  // 所以同一个用例跑两遍即可，不必把 20 行断言复制两份。
  for (final platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    testWidgets('$platform 且解码器就绪：渲染原生 Texture 并喂帧（M2 路线 A / VideoToolbox）', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final pushedFrames = <Uint8List>[];
      mockVideoChannel((MethodCall call) async {
        switch (call.method) {
          case 'create':
            return <Object?, Object?>{'textureId': 21};
          case 'pushFrame':
            pushedFrames.add(call.arguments as Uint8List);
            // Apple 两端与 Windows 一样在回执里带尺寸（Dart 侧顺手刷新 AspectRatio）。
            return <Object?, Object?>{'width': 992, 'height': 560};
          case 'getSize':
            return <Object?, Object?>{'width': 992, 'height': 560};
          default:
            return null;
        }
      });
      try {
        final transport = _FakeTransport();
        final viewModel = await pumpPlayer(
          tester,
          transport,
          withVideoFrame: true,
        );

        expect(viewModel.isVideoDecodingSupported, isTrue);
        expect(viewModel.textureId, 21);
        expect(find.byType(Texture), findsOneWidget);
        // 帧要喂给 VideoToolbox 解码器。
        expect(pushedFrames, isNotEmpty);
        // 回执里的尺寸要生效（转屏/编码器重建时 UI 靠它跟着调）。
        expect(viewModel.videoSize, const VideoSize(992, 560));
        expect(find.text('重试解码'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('Windows 且解码器就绪：同样渲染原生 Texture（M2 路线 A）', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final pushedFrames = <Uint8List>[];
    mockVideoChannel((MethodCall call) async {
      switch (call.method) {
        case 'create':
          return <Object?, Object?>{'textureId': 11};
        case 'pushFrame':
          pushedFrames.add(call.arguments as Uint8List);
          return null;
        default:
          return null;
      }
    });
    try {
      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(
        tester,
        transport,
        withVideoFrame: true,
      );

      expect(viewModel.isVideoDecodingSupported, isTrue);
      expect(viewModel.textureId, 11);
      expect(find.byType(Texture), findsOneWidget);
      // 帧同样要喂给原生解码器（Windows 走 Media Foundation）。
      expect(pushedFrames, isNotEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android 且解码器创建失败：给可读错误与重试入口', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    mockVideoChannel((MethodCall call) async {
      throw PlatformException(
        code: 'decoder_create_failed',
        message: '测试用：解码器创建失败',
      );
    });
    try {
      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(tester, transport);

      expect(viewModel.isVideoDecodingSupported, isTrue);
      expect(viewModel.decoderError, isNotNull);
      expect(find.textContaining('原生解码失败'), findsOneWidget);
      expect(find.textContaining('测试用：解码器创建失败'), findsOneWidget);
      expect(find.text('重试解码'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android 且解码器就绪：渲染原生 Texture', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final pushedFrames = <Uint8List>[];
    mockVideoChannel((MethodCall call) async {
      switch (call.method) {
        case 'create':
          return <Object?, Object?>{'textureId': 7};
        case 'pushFrame':
          pushedFrames.add(call.arguments as Uint8List);
          return null;
        default:
          return null;
      }
    });
    try {
      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(
        tester,
        transport,
        withVideoFrame: true,
      );

      expect(viewModel.textureId, 7);
      expect(viewModel.videoSize, isNotNull);
      expect(find.byType(Texture), findsOneWidget);
      // 视频帧必须被喂给原生解码器（M2 的核心管线）。
      expect(pushedFrames, isNotEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('点画面会按视频像素发出触摸消息（M3）', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    mockVideoChannel((MethodCall call) async {
      if (call.method == 'create') {
        return <Object?, Object?>{'textureId': 9};
      }
      return null;
    });
    try {
      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(
        tester,
        transport,
        withVideoFrame: true,
      );
      expect(viewModel.textureId, 9);
      transport.sent.clear();

      // 点画面正中：视频是 1280x720（初始信息头里的 displayInfo），
      // 控件里居中显示，所以正中心应该映射到视频中心 (640, 360) 附近。
      final videoArea = find.byType(Texture);
      await tester.tapAt(tester.getCenter(videoArea));
      await tester.pump();

      final touchFrames = transport.sent
          .where((Uint8List frame) => frame.isNotEmpty && frame[0] == 2)
          .toList(growable: false);
      expect(touchFrames, isNotEmpty, reason: '没有发出触摸消息（type=2）');

      final down = touchFrames.first;
      expect(down[1], 0, reason: '第一条应该是 ACTION_DOWN');
      final data = ByteData.sublistView(down);
      expect(data.getInt32(10, Endian.big), closeTo(640, 4));
      expect(data.getInt32(14, Endian.big), closeTo(360, 4));
      expect(data.getUint16(18, Endian.big), 1280);
      expect(data.getUint16(20, Endian.big), 720);

      // 抬手那一条压力必须是 0。
      final up = touchFrames.last;
      expect(up[1], 1, reason: '最后一条应该是 ACTION_UP');
      expect(ByteData.sublistView(up).getUint16(22, Endian.big), 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  /// ★ 回归（2026-10-02，iOS 实测"一开始可能可以，试几次就点不回去了"）：
  ///
  /// 设备端按 `pointerId` 记"这根手指是否还按着"。手指从画面内滑到**黑边**上抬手时，
  /// 老实现会在 `_sendTouch` 里因为 `point == null` 把整条 UP 吃掉 ——
  /// 设备端那根手指就永久按着，之后复用同一个 pointerId 的 DOWN 全被丢弃，
  /// **所有单指操作都失效**。iOS 竖屏时画面只占控件高度约 1/3，滑动几乎必然滑出画面。
  testWidgets('★ 滑动滑出画面（黑边）后必须补 UP，否则下一次点按会点不动', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    mockVideoChannel((MethodCall call) async {
      if (call.method == 'create') {
        return <Object?, Object?>{'textureId': 9};
      }
      return null;
    });
    List<int> actionsOf(List<Uint8List> frames) => frames
        .where((Uint8List f) => f.isNotEmpty && f[0] == 2)
        .map((Uint8List f) => f[1])
        .toList(growable: false);
    try {
      final transport = _FakeTransport();
      await pumpPlayer(tester, transport, withVideoFrame: true);
      transport.sent.clear();

      // `find.byType(Texture)` 的矩形就是**画面**矩形（AspectRatio 把它收成了画面尺寸），
      // 所以它的上下外侧就是黑边。
      final videoRect = tester.getRect(find.byType(Texture));
      final center = videoRect.center;

      // 手指在画面内按下 → 滑到画面下方的黑边 → 抬起。
      final gesture = await tester.startGesture(center);
      await tester.pump();
      await gesture.moveTo(Offset(center.dx, videoRect.bottom + 40));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(actionsOf(transport.sent), <int>[
        0,
        1,
      ], reason: '滑出画面后必须「DOWN 之后跟一条 UP」，不能只按不抬');

      // 关键：再点一次必须还能发出 DOWN（老实现这里会因为 id 卡住而一条都不发）。
      transport.sent.clear();
      await tester.tapAt(center);
      await tester.pump();

      expect(actionsOf(transport.sent), <int>[
        0,
        1,
      ], reason: '上一次的 UP 补齐了，这一次点按就该正常发出 down/up');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('★ 回归：连续 5 次「点按 + 手滑到黑边抬起」，序列始终是成对的 down/up', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    mockVideoChannel((MethodCall call) async {
      if (call.method == 'create') {
        return <Object?, Object?>{'textureId': 9};
      }
      return null;
    });
    try {
      final transport = _FakeTransport();
      await pumpPlayer(tester, transport, withVideoFrame: true);
      transport.sent.clear();

      final videoRect = tester.getRect(find.byType(Texture));
      final center = videoRect.center;

      for (var i = 0; i < 5; i++) {
        final gesture = await tester.startGesture(center);
        await tester.pump();
        // 偶数次故意把「抬起」落在黑边上（模拟手滑）。
        if (i.isEven) {
          await gesture.moveTo(Offset(center.dx, videoRect.bottom + 30));
          await tester.pump();
        }
        await gesture.up();
        await tester.pump();
      }

      final actions = transport.sent
          .where((Uint8List f) => f.isNotEmpty && f[0] == 2)
          .map((Uint8List f) => f[1])
          .toList(growable: false);

      expect(actions, hasLength(10), reason: '5 次点按 = 5 个 down + 5 个 up');
      expect(
        actions.where((int a) => a == 0).length,
        actions.where((int a) => a == 1).length,
        reason: 'DOWN 与 UP 数量必须相等（有一个 DOWN 没配对，设备端那根手指就卡住了）',
      );
      // 逐条检查配对：不允许"连续两个 DOWN 之间没有 UP"。
      var downSinceLastUp = 0;
      for (final action in actions) {
        if (action == 0) {
          downSinceLastUp++;
          expect(downSinceLastUp, 1, reason: '出现了没有配对的重复 DOWN：$actions');
        } else if (action == 1) {
          expect(downSinceLastUp, 1, reason: '出现了没有 DOWN 的 UP：$actions');
          downSinceLastUp = 0;
        }
      }
      expect(downSinceLastUp, 0, reason: '最后一次点按没有抬起：$actions');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // ---------------------------------------------------------------------------
  // 横屏布局：顶栏收起 + 快捷栏竖排贴右 + "铺满"显示模式
  // ---------------------------------------------------------------------------

  testWidgets('★ 横屏：顶栏收起（把高度让给画面），常驻小按钮能唤回', (WidgetTester tester) async {
    landscapePhone(tester);
    mockVideoChannel((MethodCall call) async {
      if (call.method == 'create') {
        return <Object?, Object?>{'textureId': 9};
      }
      return null;
    });
    final transport = _FakeTransport();
    final viewModel = await pumpPlayer(tester, transport, withVideoFrame: true);

    // 横屏没有 AppBar：那 56 点直接变成画面高度。
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('测试设备'), findsNothing, reason: '标题默认收起');

    // 但必须留一个常驻入口把它唤回来（**不能**用"点画面"，那是发给设备的）。
    final handle = find.byTooltip('显示标题栏');
    expect(handle, findsOneWidget);
    await tester.tap(handle);
    await tester.pump();
    expect(find.byTooltip('收起顶栏（把高度让给画面）'), findsOneWidget);
    expect(find.text('测试设备'), findsOneWidget);

    // ★ 横屏没有 AppBar → 也就没有返回箭头；浏览器更没有系统返回键，
    // 所以顶栏里必须自带一个"返回设备列表"（用户实测："左上角也没有返回键"）。
    expect(find.byTooltip('返回设备列表'), findsOneWidget);

    // 顶栏里的"铺满"按钮能切模式。
    expect(viewModel.videoFitMode, VideoFitMode.contain);
    await tester.tap(find.byTooltip('铺满屏幕（会裁掉画面上下边缘）'));
    await tester.pump();
    expect(viewModel.videoFitMode, VideoFitMode.cover);
  });

  testWidgets('★ 横屏：快捷栏竖排、贴右侧；画面撑满可用高度', (WidgetTester tester) async {
    landscapePhone(tester);
    mockVideoChannel((MethodCall call) async {
      if (call.method == 'create') {
        return <Object?, Object?>{'textureId': 9};
      }
      return null;
    });
    final transport = _FakeTransport();
    await pumpPlayer(tester, transport, withVideoFrame: true);

    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final back = tester.getCenter(find.text('返回'));
    final home = tester.getCenter(find.text('主页'));

    // 竖排：x 基本相同、y 递增；而且整体在屏幕右半边。
    expect(back.dx, closeTo(home.dx, 1));
    expect(home.dy, greaterThan(back.dy));
    expect(back.dx, greaterThan(screen.width / 2), reason: '快捷栏应该在右侧');

    // ★ 紧凑：4 个按钮要收成一组（用户实测："右边按钮区域太松散了"）。
    // 之前用 spaceEvenly，4 个按钮被摊到 ~400 点里，看着散、拇指也够不着。
    final top = tester.getRect(find.text('返回'));
    final bottom = tester.getRect(find.text('更多'));
    expect(
      bottom.bottom - top.top,
      lessThan(200),
      reason: '4 个按钮的竖向跨度应该收在一个紧凑组里，实际 ${bottom.bottom - top.top}',
    );
    // 整条竖栏也不要占太多宽度（每一点都是从画面里抠出来的）。
    expect(
      back.dx + tester.getRect(find.text('返回')).width,
      lessThan(screen.width),
    );
    final barRight = tester.getRect(find.text('更多')).right;
    expect(
      screen.width - barRight,
      greaterThan(0),
      reason: '按钮必须在右侧栏里，不能被裁掉',
    );

    // 画面高度撑满（横屏总共才 402 点，原来顶栏 + 底栏吃掉 120）。
    final videoRect = tester.getRect(find.byType(Texture));
    expect(
      videoRect.height,
      greaterThan(screen.height * 0.9),
      reason: '顶栏收起后画面应该占满高度，实际 ${videoRect.height} / ${screen.height}',
    );
  });

  testWidgets('★ 横屏 + 铺满：原本的黑边现在也能点（坐标按 cover 换算）', (
    WidgetTester tester,
  ) async {
    landscapePhone(tester);
    mockVideoChannel((MethodCall call) async {
      if (call.method == 'create') {
        return <Object?, Object?>{'textureId': 9};
      }
      return null;
    });
    final transport = _FakeTransport();
    final viewModel = await pumpPlayer(tester, transport, withVideoFrame: true);
    transport.sent.clear();

    List<int> actions() => transport.sent
        .where((Uint8List f) => f.isNotEmpty && f[0] == 2)
        .map((Uint8List f) => f[1])
        .toList(growable: false);

    // contain 下画面是高度受限的，左右各有一条黑边（874 宽里画面只用 ~715）。
    final videoRect = tester.getRect(find.byType(Texture));
    final barPoint = Offset(videoRect.left - 5, videoRect.center.dy);
    expect(barPoint.dx, greaterThan(0), reason: '这个尺寸下应该确实有左侧黑边，测试才有意义');

    // 黑边上按下 → 不转发（老行为，仍然正确）。
    await tester.tapAt(barPoint);
    await tester.pump();
    expect(actions(), isEmpty, reason: '黑边上的点击不该发给设备');

    // 切到铺满（走"更多"面板这条真实入口）。
    await tester.tap(find.text('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('铺满屏幕'));
    await tester.pump();
    expect(viewModel.videoFitMode, VideoFitMode.cover);

    // 收起面板，再点同一个位置：铺满后这里已经是画面内容，应该发得出去。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    transport.sent.clear();

    await tester.tapAt(barPoint);
    await tester.pump();
    expect(actions(), <int>[0, 1], reason: '铺满后同一位置应该能点（down + up）');
  });

  // ---------------------------------------------------------------------------
  // ★ 拉伸窗口（桌面端最常做的动作）：连续改变控件尺寸时的编码参数下发
  // ---------------------------------------------------------------------------

  testWidgets('★ 拖动窗口连续改变尺寸：最多补发 1 条编码参数，且之后仍然能点', (
    WidgetTester tester,
  ) async {
    // 桌面端（macOS）路径：原生解码 + 真实窗口尺寸变化。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    mockVideoChannel((MethodCall call) async {
      switch (call.method) {
        case 'create':
          return <Object?, Object?>{'textureId': 31};
        case 'pushFrame':
          return <Object?, Object?>{'width': 1280, 'height': 720};
        case 'getSize':
          return <Object?, Object?>{'width': 1280, 'height': 720};
        default:
          return null;
      }
    });
    try {
      // 桌面窗口：1600x1000 逻辑、DPR 1（比设备原生 1280x720 大 → 会被收敛到 1280x720）。
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(tester, transport, withVideoFrame: true);
      expect(viewModel.videoSize, const VideoSize(1280, 720));

      List<Uint8List> settingsFrames() => transport.sent
          .where(
            (Uint8List f) =>
                f.isNotEmpty &&
                f[0] == ControlMessageType.changeStreamParameters.code,
          )
          .toList(growable: false);
      final before = settingsFrames().length;

      // 拖动窗口：每一帧都是一个**新尺寸**（真实拖动就是这样，20 帧 ≈ 0.3 秒）。
      // 尺寸必须每帧都不同，否则会被 service 里的"相同尺寸去重"挡掉，测不出问题。
      for (var i = 1; i <= 20; i++) {
        tester.view.physicalSize = Size(1600 - i * 12, 1000 - i * 7);
        await tester.pump(const Duration(milliseconds: 16));
      }
      // 松手之后留出宽限期（防抖窗口），让最终尺寸有机会下发。
      await tester.pump(const Duration(milliseconds: 800));

      final sent = settingsFrames().length - before;
      expect(
        sent,
        lessThanOrEqualTo(1),
        reason:
            '连续 20 个不同尺寸最多允许补发 1 条（最终尺寸），实际 $sent 条。'
            '每多发一条，服务端就重建一次编码器：重建后不会立刻出 IDR，'
            '画面会停住/变黑，用户看到的就是"拉伸窗口后没法操控了"'
            '（AGENTS §12.5 / §6.2 记过这个失败模式）。',
      );

      // ★ 同一个坑的第二条入口：**旋转手机**（用户实测"我旋转一下屏幕，就点不了了"）。
      // 转屏动画同样会连续产生几十个不同尺寸，走的是同一条路径。
      final beforeRotation = settingsFrames().length;
      for (var i = 1; i <= 16; i++) {
        // 竖屏 402x874 → 横屏 874x402，中间每一帧都不重复。
        final t = i / 16;
        tester.view.physicalSize = Size(
          (402 + (874 - 402) * t).roundToDouble(),
          (874 + (402 - 874) * t).roundToDouble(),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 800));
      final sentOnRotation = settingsFrames().length - beforeRotation;
      expect(
        sentOnRotation,
        lessThanOrEqualTo(1),
        reason:
            '转屏过程最多允许补发 1 条，实际 $sentOnRotation 条。'
            '转屏时点不动，先看这里——不是坐标算错，是编码器被重建打死了。',
      );

      // 拉伸之后输入必须还活着：点画面正中要发出 down + up（type=2）。
      transport.sent.clear();
      await tester.tapAt(tester.getCenter(find.byType(Texture)));
      await tester.pump();
      final actions = transport.sent
          .where((Uint8List f) => f.isNotEmpty && f[0] == 2)
          .map((Uint8List f) => f[1])
          .toList(growable: false);
      expect(
        actions,
        <int>[0, 1],
        reason: '窗口尺寸变化之后点画面仍然要能发出 down/up（不能因为视口变化就把输入层丢掉）',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // ---------------------------------------------------------------------------
  // ★ 清晰度：编码边界策略（桌面默认"清晰优先"，与网页端一致）
  // ---------------------------------------------------------------------------

  /// 从已发出的报文里解出最近一条编码参数。
  VideoSettings? lastSettings(_FakeTransport transport) {
    final frames = transport.sent
        .where((Uint8List f) => f.isNotEmpty && f[0] == 101)
        .toList(growable: false);
    if (frames.isEmpty) {
      return null;
    }
    return VideoSettings.fromBuffer(Uint8List.sublistView(frames.last, 1));
  }

  testWidgets('★ 桌面端默认"清晰优先"：编码边界按画面区物理像素，不再封顶到设备原生', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    mockVideoChannel((MethodCall call) async {
      switch (call.method) {
        case 'create':
          return <Object?, Object?>{'textureId': 41};
        case 'pushFrame':
          return <Object?, Object?>{'width': 1280, 'height': 720};
        case 'getSize':
          return <Object?, Object?>{'width': 1280, 'height': 720};
        default:
          return null;
      }
    });
    try {
      // 桌面窗口：1600x1000 逻辑、DPR 1（画面区物理像素多于设备原生 1280x720）。
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(tester, transport, withVideoFrame: true);

      expect(
        viewModel.boundsMode,
        VideoBoundsMode.viewport,
        reason: '桌面端默认清晰优先（网页端就是按自己的视口尺寸要像素的）',
      );
      final bounds = lastSettings(transport)?.bounds;
      expect(bounds, isNotNull);
      expect(
        bounds!.width,
        greaterThan(1280),
        reason: '清晰优先下应该请设备多编像素（设备原生 1280x720），实际 $bounds',
      );

      // 面板里的开关能切回"省设备算力"，并且立刻补发一条封顶到原生的参数。
      await tester.tap(find.text('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final switchFinder = find.text('清晰优先（按画面区像素编码）');
      await tester.ensureVisible(switchFinder);
      await tester.pump();
      await tester.tap(switchFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(viewModel.boundsMode, VideoBoundsMode.nativeCap);
      expect(
        lastSettings(transport)?.bounds,
        const VideoSize(1280, 720),
        reason: '关掉清晰优先后回到"绝不向设备要放大"（AGENTS §12.7）',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('★ 移动端默认也是"清晰优先"（用户 2026-10-07 要求：手机横屏别糊）', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    landscapePhone(tester);
    mockVideoChannel((MethodCall call) async {
      switch (call.method) {
        case 'create':
          return <Object?, Object?>{'textureId': 42};
        case 'pushFrame':
          return <Object?, Object?>{'width': 1280, 'height': 720};
        case 'getSize':
          return <Object?, Object?>{'width': 1280, 'height': 720};
        default:
          return null;
      }
    });
    try {
      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(tester, transport, withVideoFrame: true);
      expect(
        viewModel.boundsMode,
        VideoBoundsMode.viewport,
        reason: '手机横屏画面区物理 2280x1206，封顶到原生 1280x720 会被放大 1.68x（糊）',
      );
      // 874x402 逻辑 @3 = 2622x1206 物理 → 按设备比例收框 2144x1206 → 上限原生×2 → 2144x1200。
      expect(lastSettings(transport)?.bounds, const VideoSize(2144, 1200));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('★ 桌面宽窗口 + 铺满：黑边位置也变成画面内容，坐标按 cover 换算', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    mockVideoChannel((MethodCall call) async {
      switch (call.method) {
        case 'create':
          return <Object?, Object?>{'textureId': 51};
        case 'pushFrame':
          return <Object?, Object?>{'width': 1280, 'height': 720};
        case 'getSize':
          return <Object?, Object?>{'width': 1280, 'height': 720};
        default:
          return null;
      }
    });
    try {
      // 桌面**宽**窗口（2000x800 逻辑、DPR 1）：比 16:9 更宽 → contain 下左右有黑边，
      // 正是用户"点铺满"想用上的那块地方。
      tester.view.physicalSize = const Size(2000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(tester, transport, withVideoFrame: true);

      /// 已发出的触摸消息 → (action, x, y)。x 在偏移 10、y 在 14
      /// （偏移 2..9 是 pointerId 的高/低 4 字节）。
      List<List<int>> touches() => transport.sent
          .where((Uint8List f) => f.isNotEmpty && f[0] == 2)
          .map((Uint8List f) {
            final data = ByteData.sublistView(f);
            return <int>[
              f[1],
              data.getInt32(10, Endian.big),
              data.getInt32(14, Endian.big),
            ];
          })
          .toList(growable: false);

      // contain：画面左右各一条黑边（这个几何下必然有，测试才有意义）。
      final videoRect = tester.getRect(find.byType(Texture));
      expect(
        videoRect.left,
        greaterThan(20),
        reason: '这个窗口尺寸下应该有左侧黑边，实际 ${videoRect.left}',
      );
      final barPoint = Offset(2, videoRect.center.dy);

      transport.sent.clear();
      await tester.tapAt(barPoint);
      await tester.pump();
      expect(touches(), isEmpty, reason: 'contain 下黑边上的点击不该发给设备');

      // 画面正中：两种模式下都应该能点，而且映射到视频中心附近。
      transport.sent.clear();
      await tester.tapAt(videoRect.center);
      await tester.pump();
      final center = touches();
      expect(center.map((t) => t[0]).toList(), <int>[0, 1]);
      expect(center.first[1], closeTo(640, 40), reason: '正中的视频 x 应该在 640 附近');
      expect(center.first[2], closeTo(360, 40), reason: '正中的视频 y 应该在 360 附近');

      // 切"铺满"（真实入口：更多面板里的开关）。
      await tester.tap(find.text('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final switchFinder = find.text('铺满屏幕');
      await tester.ensureVisible(switchFinder);
      await tester.pump();
      await tester.tap(switchFinder);
      await tester.pump();
      expect(viewModel.videoFitMode, VideoFitMode.cover);
      // 关掉面板（面板挡在画面上时点击不会到 Listener）。
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      transport.sent.clear();
      await tester.tapAt(barPoint);
      await tester.pump();
      final onBar = touches();
      expect(
        onBar.map((t) => t[0]).toList(),
        <int>[0, 1],
        reason: '铺满后原本黑边的位置已经是画面内容，必须发得出去',
      );
      // 这个几何下铺满是按宽度铺满、裁掉画面的上下边缘，所以左边缘就是视频的 x≈0
      // ——要紧的是"**contain 下发不出去、cover 下发得出去**"这件事（上面两条断言）。
      expect(
        onBar.first[1],
        inInclusiveRange(0, 100),
        reason: '铺满后左边缘对应视频 x 的起点附近，实际 ${onBar.first[1]}',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('★ 解码器异步报错（web 的 WebCodecs 是回调式）：立刻出可读错误 + 重试，不等下一帧', (
    WidgetTester tester,
  ) async {
    final transport = _FakeTransport();
    final service = StreamSessionService(_FakeStreamRemoteDatasource(transport));
    addTearDown(service.dispose);
    final decoder = _FakeVideoDecoder();
    addTearDown(decoder.dispose);
    final viewModel = PlayerViewModel(service, decoder: decoder);
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(viewModel: viewModel, target: target, title: '测试设备'),
      ),
    );
    await tester.pump();
    await tester.pump();
    transport.emit(loadInitialInfoFixture());
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (viewModel.textureId != null) {
        break;
      }
    }
    expect(viewModel.textureId, isNotNull, reason: '解码器已建好，画面载体就位');
    expect(find.text('重试解码'), findsNothing);

    // 服务端画面静止时不再给帧，所以"等下一帧再报错"就是一块没有解释的黑屏
    // （用户实测）。错误必须当场显示出来。
    decoder.emitError('管道里没有可解码的数据');
    await tester.pump();

    expect(viewModel.decoderError, isNotNull);
    expect(
      viewModel.decoderError!.message,
      contains('管道里没有可解码的数据'),
    );
    expect(find.text('重试解码'), findsOneWidget);
  });

  testWidgets('★ web：把"订阅之前到达"的参数集 + IDR 补喂给后建的解码器（否则永远全黑）', (
    WidgetTester tester,
  ) async {
    // 复现真机时序：服务端的 header 与头几帧经常在同一个事件循环里投递完，
    // 此时 viewmodel 还没订阅 videoFrames（广播流没有监听者 → 直接丢）；
    // 设备画面静止时又不会再发帧 → 解码器永远拿不到 SPS = 全黑且无报错。
    final transport = _FakeTransport();
    final service = StreamSessionService(_FakeStreamRemoteDatasource(transport));
    addTearDown(service.dispose);
    final decoder = _RecordingVideoDecoder();
    addTearDown(decoder.dispose);
    final viewModel = PlayerViewModel(service, decoder: decoder, isWeb: true);
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(viewModel: viewModel, target: target, title: '测试设备'),
      ),
    );
    await tester.pump();

    // 一口气推：header + 参数集 + IDR（中间不给微任务机会 = 订阅还没建立）。
    final fixture = loadVideoFrameFixture();
    transport.emit(loadInitialInfoFixture());
    transport.emit(fixture[0]); // SPS + PPS
    transport.emit(fixture[1]); // IDR
    await tester.pump();
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (decoder.pushed.isNotEmpty) {
        break;
      }
    }

    expect(
      decoder.pushed,
      <Uint8List>[fixture[0], fixture[1]],
      reason: '参数集必须在最前面（web 端靠它算 codec 串），紧跟最近一个 IDR',
    );
    expect(viewModel.textureId, isNotNull);
  });
}
