import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';
import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';
import 'package:ws_scrcpy_client/feature/stream/application/service/stream_session_service.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/stream_remote_datasource.dart';
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

  testWidgets('非原生平台（Linux）：给出可读的降级说明，不尝试原生解码', (WidgetTester tester) async {
    // 注意：必须在测试体内还原，addTearDown 太晚——框架会在测试结束前断言
    // debugDefaultTargetPlatformOverride 已被清空。
    // 这里刻意用 Linux：Android / Windows / iOS / macOS 都已经有原生解码实现（M2 路线 A）。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(
        tester,
        transport,
        withVideoFrame: true,
      );

      expect(viewModel.isNativeDecodingSupported, isFalse);
      expect(viewModel.decoderError, isNull);
      expect(
        find.textContaining('已在 Android / Windows / iOS / macOS 上实现'),
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

        expect(viewModel.isNativeDecodingSupported, isTrue);
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

      expect(viewModel.isNativeDecodingSupported, isTrue);
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

      expect(viewModel.isNativeDecodingSupported, isTrue);
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
}
