import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';
import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';
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

  testWidgets('"更多"面板里有"连接后自动唤醒设备"开关，默认关且能打开', (WidgetTester tester) async {
    final transport = _FakeTransport();
    final viewModel = await pumpPlayer(tester, transport);

    await tester.tap(find.text('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('连接后自动唤醒设备'), findsOneWidget);
    final switchFinder = find.byType(Switch);
    expect(switchFinder, findsOneWidget);
    // 默认**关**：唤醒只是可选项——真实服务端网页端并不发唤醒键，
    // 黑屏的正解是"视频参数只发一次 + 回显服务端值"（见 AGENTS §12.5）。
    expect(tester.widget<Switch>(switchFinder).value, isFalse);
    expect(viewModel.wakeOnConnect, isFalse);

    await tester.tap(switchFinder);
    await tester.pump();
    expect(viewModel.wakeOnConnect, isTrue);
    expect(tester.widget<Switch>(switchFinder).value, isTrue);
  });

  testWidgets('非原生平台（iOS）：给出可读的降级说明，不尝试原生解码', (WidgetTester tester) async {
    // 注意：必须在测试体内还原，addTearDown 太晚——框架会在测试结束前断言
    // debugDefaultTargetPlatformOverride 已被清空。
    // 这里刻意用 iOS：Android / Windows 都已经有原生解码实现（M2 路线 A）。
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final transport = _FakeTransport();
      final viewModel = await pumpPlayer(
        tester,
        transport,
        withVideoFrame: true,
      );

      expect(viewModel.isNativeDecodingSupported, isFalse);
      expect(viewModel.decoderError, isNull);
      expect(find.textContaining('已在 Android 与 Windows 上实现'), findsOneWidget);
      expect(find.text('重试解码'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

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
}
