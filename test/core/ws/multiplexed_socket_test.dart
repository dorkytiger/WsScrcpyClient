import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/ws/multiplexed_socket.dart';
import 'package:ws_scrcpy_client/core/ws/multiplexer_message.dart';
import 'package:ws_scrcpy_client/core/ws/multiplexer_message_type.dart';
import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';

/// 假传输：把"发出去的字节"和"收到的消息"都记下来，用于验证复用层行为。
class FakeWebSocketTransport implements WebSocketTransport {
  final StreamController<Object> _controller =
      StreamController<Object>.broadcast();
  final List<Uint8List> sentFrames = <Uint8List>[];

  @override
  bool isOpen = true;

  @override
  Stream<Object> get messages => _controller.stream;

  @override
  void sendBinary(Uint8List data) => sentFrames.add(data);

  @override
  Future<void> close([int code = 1000, String? reason]) async {
    isOpen = false;
    await _controller.close();
  }

  void emit(Object message) => _controller.add(message);

  /// 把收到的帧解析成结构化对象，便于断言。
  MultiplexerMessage frameAt(int index) =>
      MultiplexerMessage.decode(sentFrames[index]);
}

void main() {
  late FakeWebSocketTransport transport;
  late MultiplexedSocket socket;

  setUp(() {
    transport = FakeWebSocketTransport();
    socket = MultiplexedSocket(transport);
  });

  tearDown(() async {
    await socket.dispose();
  });

  test('createChannel 发送 CreateChannel 帧（通道码为 ASCII）', () {
    final result = socket.createChannel(
      Uint8List.fromList(ascii.encode('GTRC')),
    );

    expect(result.isSuccess, isTrue);
    expect(result.data!.id, 1);
    final frame = transport.frameAt(0);
    expect(frame.type, MessageType.createChannel);
    expect(frame.channelId, 1);
    expect(utf8.decode(frame.payload), 'GTRC');
  });

  test('通道 id 递增且不复用已打开的 id', () {
    final first = socket.createChannel(Uint8List(0)).data!;
    final second = socket.createChannel(Uint8List(0)).data!;
    expect(<int>[first.id, second.id], <int>[1, 2]);
  });

  test('文本与二进制帧都按类型分发到对应通道', () async {
    final channel = socket.createChannel(Uint8List(0)).data!;
    final received = <MultiplexedChannelMessage>[];
    final subscription = channel.messages.listen(received.add);

    transport.emit(
      MultiplexerMessage.encodeFrame(
        type: MessageType.rawStringData,
        channelId: channel.id,
        payload: Uint8List.fromList(utf8.encode('{"type":"devicelist"}')),
      ),
    );
    transport.emit(
      MultiplexerMessage.encodeFrame(
        type: MessageType.rawBinaryData,
        channelId: channel.id,
        payload: Uint8List.fromList(<int>[0, 0, 0, 1, 0x65]),
      ),
    );
    await pumpEventQueue();

    expect(received, hasLength(2));
    expect(received[0].isText, isTrue);
    expect(received[0].decodeText(), '{"type":"devicelist"}');
    expect(received[1].isText, isFalse);
    expect(received[1].payload, <int>[0, 0, 0, 1, 0x65]);

    await subscription.cancel();
  });

  test('服务端主动打开的通道通过 serverChannels 暴露', () async {
    final created = <MultiplexedChannel>[];
    final subscription = socket.serverChannels.listen(created.add);

    transport.emit(
      MultiplexerMessage.encodeFrame(
        type: MessageType.createChannel,
        channelId: 7,
        payload: Uint8List.fromList(ascii.encode('HSTS')),
      ),
    );
    await pumpEventQueue();

    expect(created, hasLength(1));
    expect(created.first.id, 7);
    expect(utf8.decode(created.first.initData), 'HSTS');
    // 服务端通道 id 之后，客户端新开通道必须避让，不能撞车。
    expect(socket.createChannel(Uint8List(0)).data!.id, greaterThan(7));

    await subscription.cancel();
  });

  test('CloseChannel 关闭通道并带上关闭事件', () async {
    final channel = socket.createChannel(Uint8List(0)).data!;
    var closed = false;
    final subscription = channel.messages.listen(
      (_) {},
      onDone: () => closed = true,
    );

    final payload = Uint8List(6);
    ByteData.sublistView(payload).setUint16(0, 1000, Endian.little);
    transport.emit(
      MultiplexerMessage.encodeFrame(
        type: MessageType.closeChannel,
        channelId: channel.id,
        payload: payload,
      ),
    );
    await pumpEventQueue();

    expect(channel.isOpen, isFalse);
    expect(channel.closeEvent?.code, 1000);
    expect(closed, isTrue);

    await subscription.cancel();
  });

  test('通道消息发送时带上自己的通道 id 与类型', () {
    final channel = socket.createChannel(Uint8List(0)).data!;
    channel.sendBinary(Uint8List.fromList(<int>[9, 9]));

    final frame = transport.frameAt(1);
    expect(frame.type, MessageType.rawBinaryData);
    expect(frame.channelId, channel.id);
    expect(frame.payload, <int>[9, 9]);
  });

  test('非法帧进入错误流而不是崩溃', () async {
    final errors = <Object>[];
    final subscription = socket.errors.listen(errors.add);

    transport.emit(Uint8List.fromList(<int>[4, 1]));
    await pumpEventQueue();

    expect(errors, hasLength(1));

    await subscription.cancel();
  });

  test('连接关闭后 createChannel 返回失败而不是抛异常', () async {
    transport.isOpen = false;
    final result = socket.createChannel(Uint8List(0));
    expect(result.isError, isTrue);
  });
}
