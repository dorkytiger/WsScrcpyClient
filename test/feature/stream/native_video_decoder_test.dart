import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/native_video_decoder.dart';

/// 只测 Dart 这一侧的契约：
/// 1) 通道缺失 / 未创建时必须是**可读的失败 Result**，而不是抛异常穿透到 UI；
/// 2) 尺寸走"回执 / 主动拉取"，不再是原生侧反向推送
///    （`onSizeChanged` 那条路在 Windows 上已被删除，见 AGENTS.md §12）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('ws_scrcpy/video'),
      null,
    );
  });

  test('没有原生实现时 create 返回失败而不是抛异常', () async {
    final decoder = NativeVideoDecoder();
    addTearDown(decoder.dispose);

    final result = await decoder.create();

    expect(result.isError, isTrue);
    expect(result.error!.message, isNotEmpty);
    expect(decoder.hasTexture, isFalse);
  });

  test('未创建就喂帧时返回失败并给出可读文案', () async {
    final decoder = NativeVideoDecoder();
    addTearDown(decoder.dispose);

    final result = await decoder.pushFrame(Uint8List(16));

    expect(result.isError, isTrue);
    expect(result.error!.message, contains('尚未就绪'));
  });

  test('未创建时 release 是安全的空操作', () async {
    final decoder = NativeVideoDecoder();
    await decoder.release();
    expect(decoder.hasTexture, isFalse);
  });

  test('未创建时 getSize 不报错且不产生尺寸事件', () async {
    final decoder = NativeVideoDecoder();
    addTearDown(decoder.dispose);
    final sizes = <VideoSize>[];
    final subscription = decoder.sizeChanges.listen(sizes.add);
    addTearDown(subscription.cancel);

    expect(await decoder.getSize(), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(sizes, isEmpty);
  });

  test('create 回执里的尺寸会被广播出来（取代 onSizeChanged 推送）', () async {
    messenger.setMockMethodCallHandler(const MethodChannel('ws_scrcpy/video'), (
      MethodCall call,
    ) async {
      if (call.method == 'create') {
        return <Object?, Object?>{'textureId': 7, 'width': 1280, 'height': 720};
      }
      if (call.method == 'release') {
        return null;
      }
      throw MissingPluginException('未实现：${call.method}');
    });

    final decoder = NativeVideoDecoder();
    addTearDown(decoder.dispose);
    final sizes = <VideoSize>[];
    final subscription = decoder.sizeChanges.listen(sizes.add);
    addTearDown(subscription.cancel);

    final result = await decoder.create();
    await Future<void>.delayed(Duration.zero);

    expect(result.isError, isFalse);
    expect(result.data, 7);
    expect(decoder.hasTexture, isTrue);
    expect(decoder.lastSize, const VideoSize(1280, 720));
    expect(sizes, <VideoSize>[const VideoSize(1280, 720)]);
  });

  test('pushFrame 回执里的新尺寸会更新并只广播一次变化', () async {
    var width = 1280;
    var height = 720;
    var pushCount = 0;
    messenger.setMockMethodCallHandler(const MethodChannel('ws_scrcpy/video'), (
      MethodCall call,
    ) async {
      switch (call.method) {
        case 'create':
          return <Object?, Object?>{
            'textureId': 3,
            'width': width,
            'height': height,
          };
        case 'pushFrame':
          pushCount++;
          return <Object?, Object?>{'width': width, 'height': height};
        case 'release':
          return null;
      }
      throw MissingPluginException('未实现：${call.method}');
    });

    final decoder = NativeVideoDecoder();
    addTearDown(decoder.dispose);
    final sizes = <VideoSize>[];
    final subscription = decoder.sizeChanges.listen(sizes.add);
    addTearDown(subscription.cancel);

    await decoder.create();
    await decoder.pushFrame(Uint8List(8));
    await decoder.pushFrame(Uint8List(8));
    await Future<void>.delayed(Duration.zero);
    // 尺寸没变：只应在 create 回执时广播一次（不能每帧一条，否则 UI 会每帧重建）。
    expect(sizes, <VideoSize>[const VideoSize(1280, 720)]);

    // 原生侧解码器报告了真实分辨率（设备旋转）：下一帧回执就带回来。
    width = 1920;
    height = 1080;
    await decoder.pushFrame(Uint8List(8));
    await Future<void>.delayed(Duration.zero);

    expect(pushCount, 3);
    expect(decoder.lastSize, const VideoSize(1920, 1080));
    expect(sizes, <VideoSize>[
      const VideoSize(1280, 720),
      const VideoSize(1920, 1080),
    ]);
  });

  test('getSize 主动拉取能拿到当前尺寸（0x0 视为未知，不清空已有尺寸）', () async {
    var width = 0;
    var height = 0;
    messenger.setMockMethodCallHandler(const MethodChannel('ws_scrcpy/video'), (
      MethodCall call,
    ) async {
      switch (call.method) {
        case 'create':
          return <Object?, Object?>{'textureId': 1, 'width': 0, 'height': 0};
        case 'getSize':
          return <Object?, Object?>{'width': width, 'height': height};
        case 'release':
          return null;
      }
      throw MissingPluginException('未实现：${call.method}');
    });

    final decoder = NativeVideoDecoder();
    addTearDown(decoder.dispose);
    final sizes = <VideoSize>[];
    final subscription = decoder.sizeChanges.listen(sizes.add);
    addTearDown(subscription.cancel);

    await decoder.create();
    // create 回执是 0x0（解码器还没解出任何帧）：不能当成"尺寸变成 0"。
    expect(decoder.lastSize, isNull);
    expect(await decoder.getSize(), isNull);

    width = 640;
    height = 360;
    expect(await decoder.getSize(), const VideoSize(640, 360));
    expect(decoder.lastSize, const VideoSize(640, 360));
    await Future<void>.delayed(Duration.zero);
    expect(sizes, <VideoSize>[const VideoSize(640, 360)]);

    // 再拉一次同尺寸：不重复广播。
    expect(await decoder.getSize(), const VideoSize(640, 360));
    await Future<void>.delayed(Duration.zero);
    expect(sizes.length, 1);
  });

  test('平台没有 getSize 实现时返回已有尺寸而不是抛异常', () async {
    messenger.setMockMethodCallHandler(const MethodChannel('ws_scrcpy/video'), (
      MethodCall call,
    ) async {
      switch (call.method) {
        case 'create':
          // 老契约（例如 Android 仍在用 onSizeChanged 推送）：回执里没有尺寸。
          return <Object?, Object?>{'textureId': 9};
        case 'release':
          return null;
      }
      throw MissingPluginException('未实现：${call.method}');
    });

    final decoder = NativeVideoDecoder();
    addTearDown(decoder.dispose);

    final result = await decoder.create();
    expect(result.isError, isFalse);
    expect(decoder.lastSize, isNull);
    expect(await decoder.getSize(), isNull);
  });

  test('onSizeChanged 入站推送仍然兼容（Android 契约），但尺寸去重', () async {
    messenger.setMockMethodCallHandler(const MethodChannel('ws_scrcpy/video'), (
      MethodCall call,
    ) async {
      switch (call.method) {
        case 'create':
          return <Object?, Object?>{'textureId': 11};
        case 'release':
          return null;
      }
      throw MissingPluginException('未实现：${call.method}');
    });

    final decoder = NativeVideoDecoder();
    addTearDown(decoder.dispose);
    final sizes = <VideoSize>[];
    final subscription = decoder.sizeChanges.listen(sizes.add);
    addTearDown(subscription.cancel);

    await decoder.create();
    // 模拟 Android 侧主动推送（Windows 已不再发这个消息）。
    await messenger.handlePlatformMessage(
      'ws_scrcpy/video',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onSizeChanged', <Object?, Object?>{
          'width': 1080,
          'height': 1920,
        }),
      ),
      (ByteData? _) {},
    );
    await messenger.handlePlatformMessage(
      'ws_scrcpy/video',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onSizeChanged', <Object?, Object?>{
          'width': 1080,
          'height': 1920,
        }),
      ),
      (ByteData? _) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(decoder.lastSize, const VideoSize(1080, 1920));
    expect(sizes, <VideoSize>[const VideoSize(1080, 1920)]);
  });
}
