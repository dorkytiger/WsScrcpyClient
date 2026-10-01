import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/ws/multiplexer_message.dart';
import 'package:ws_scrcpy_client/core/ws/multiplexer_message_type.dart';
import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';

/// 通道内收到的一条消息。
class MultiplexedChannelMessage {
  const MultiplexedChannelMessage({required this.type, required this.payload});

  final MessageType type;
  final Uint8List payload;

  /// 是否为文本消息（服务端用 [MessageType.rawStringData] 下发 JSON/纯文本）。
  bool get isText => type == MessageType.rawStringData;

  /// 按 utf8 解码为字符串（容错处理非法字节）。
  String decodeText() => utf8.decode(payload, allowMalformed: true);

  @override
  String toString() =>
      'MultiplexedChannelMessage(type: $type, bytes: ${payload.length})';
}

/// 复用层上的一条逻辑通道。
class MultiplexedChannel {
  MultiplexedChannel._(this.id, this.initData, this._send);

  /// 通道 id（uint32，由发起方分配；客户端从 1 开始递增）。
  final int id;

  /// 打开通道时发送的初始化数据（通道码）。
  final Uint8List initData;

  final void Function(int channelId, Uint8List data, MessageType type) _send;
  final StreamController<MultiplexedChannelMessage> _controller =
      StreamController<MultiplexedChannelMessage>.broadcast();

  bool _isOpen = true;
  ChannelCloseEvent? _closeEvent;

  /// 通道消息流（广播）。
  Stream<MultiplexedChannelMessage> get messages => _controller.stream;

  bool get isOpen => _isOpen;

  /// 关闭事件（对端关闭时才有值）。
  ChannelCloseEvent? get closeEvent => _closeEvent;

  /// 以二进制消息发送（控制消息走这条路径）。
  void sendBinary(Uint8List data) {
    _send(id, data, MessageType.rawBinaryData);
  }

  /// 以文本消息发送。
  void sendText(String text) {
    _send(id, Uint8List.fromList(utf8.encode(text)), MessageType.rawStringData);
  }

  /// 以复用层 Data 帧发送（服务端部分通道按此类型读取）。
  void sendData(Uint8List data) {
    _send(id, data, MessageType.data);
  }

  void handleMessage(MultiplexedChannelMessage message) {
    if (_isOpen && !_controller.isClosed) {
      _controller.add(message);
    }
  }

  void handleClose(ChannelCloseEvent event) {
    if (!_isOpen) {
      return;
    }
    _isOpen = false;
    _closeEvent = event;
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  /// 本地释放（不发关闭帧）。
  void dispose() {
    _isOpen = false;
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}

/// 复用层客户端：把一条 WebSocket 连接切分成多条逻辑通道。
///
/// 协议见 [MultiplexerMessage]。
class MultiplexedSocket {
  MultiplexedSocket(this._transport, {AppLogger? logger})
    : _logger = logger ?? AppLogger('MultiplexedSocket') {
    _subscription = _transport.messages.listen(
      _onRawMessage,
      onError: (Object error, StackTrace stackTrace) {
        _errors.add(
          RemoteException(
            message: '通道数据接收失败：$error',
            exception: error,
            stackTrace: stackTrace,
          ),
        );
      },
      onDone: _onTransportClosed,
      cancelOnError: false,
    );
  }

  final WebSocketTransport _transport;
  final AppLogger _logger;
  final Map<int, MultiplexedChannel> _channels = <int, MultiplexedChannel>{};
  final StreamController<MultiplexedChannel> _serverChannels =
      StreamController<MultiplexedChannel>.broadcast();
  final StreamController<GlobalException> _errors =
      StreamController<GlobalException>.broadcast();
  late final StreamSubscription<Object> _subscription;

  /// 客户端可用的最大通道 id（uint32 上界）。
  static const int maxChannelId = 0xFFFFFFFF;

  int _nextId = 0;
  bool _isClosed = false;

  /// 服务端主动打开的通道（如服务端侧发起的子通道）。
  Stream<MultiplexedChannel> get serverChannels => _serverChannels.stream;

  /// 协议层错误流（解析失败、连接异常等），供上层做三态与重连决策。
  Stream<GlobalException> get errors => _errors.stream;

  bool get isClosed => _isClosed;

  /// 当前打开的通道数。
  int get openedChannelCount => _channels.length;

  /// 打开一条通道并发送 [ChannelCode] 等初始化数据。
  Result<MultiplexedChannel> createChannel(Uint8List initData) {
    if (_isClosed || !_transport.isOpen) {
      return Result.failure(const BusinessException(message: '连接已关闭，无法打开通道'));
    }
    final id = _allocateChannelId();
    final channel = MultiplexedChannel._(id, initData, _sendOnChannel);
    _channels[id] = channel;
    _transport.sendBinary(
      MultiplexerMessage.encodeFrame(
        type: MessageType.createChannel,
        channelId: id,
        payload: initData,
      ),
    );
    return Result.success(channel);
  }

  /// 关闭整条连接并释放所有通道。
  Future<void> dispose() async {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    await _subscription.cancel();
    for (final channel in _channels.values) {
      channel.dispose();
    }
    _channels.clear();
    await _serverChannels.close();
    await _errors.close();
    if (_transport.isOpen) {
      await _transport.close();
    }
  }

  void _onRawMessage(Object raw) {
    final bytes = switch (raw) {
      Uint8List value => value,
      String value => Uint8List.fromList(utf8.encode(value)),
      _ => Uint8List.fromList((raw as List<int>)),
    };
    final MultiplexerMessage message;
    try {
      message = MultiplexerMessage.decode(bytes);
    } on ParsingException catch (error, stackTrace) {
      _logger.warn('复用帧解析失败', error, stackTrace);
      _errors.add(error);
      return;
    }

    switch (message.type) {
      case MessageType.createChannel:
        _onServerCreateChannel(message);
      case MessageType.rawStringData:
      case MessageType.rawBinaryData:
      case MessageType.data:
        _channelOf(message.channelId)?.handleMessage(
          MultiplexedChannelMessage(
            type: message.type,
            payload: message.payload,
          ),
        );
      case MessageType.closeChannel:
        _onCloseChannel(message);
      case MessageType.unknown:
        _logger.warn('收到未知复用帧类型：${message.type.code}');
    }
  }

  void _onServerCreateChannel(MultiplexerMessage message) {
    final channel = MultiplexedChannel._(
      message.channelId,
      message.payload,
      _sendOnChannel,
    );
    _channels[message.channelId] = channel;
    if (message.channelId > _nextId) {
      _nextId = message.channelId;
    }
    if (!_serverChannels.isClosed) {
      _serverChannels.add(channel);
    }
  }

  void _onCloseChannel(MultiplexerMessage message) {
    final channel = _channelOf(message.channelId);
    if (channel == null) {
      _logger.warn('收到未知通道的关闭事件：${message.channelId}');
      return;
    }
    try {
      channel.handleClose(message.decodeCloseEvent());
    } on ParsingException catch (error, stackTrace) {
      _logger.warn('关闭事件解析失败', error, stackTrace);
      channel.handleClose(const ChannelCloseEvent(code: 1006));
    }
    _channels.remove(message.channelId);
  }

  void _onTransportClosed() {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    for (final channel in _channels.values) {
      channel.handleClose(const ChannelCloseEvent(code: 1006, reason: '连接已断开'));
    }
    _channels.clear();
    if (!_errors.isClosed) {
      _errors.add(const RemoteException(message: '连接已断开'));
    }
  }

  MultiplexedChannel? _channelOf(int channelId) {
    final channel = _channels[channelId];
    if (channel == null) {
      _logger.warn('收到未知通道（$channelId）的数据');
    }
    return channel;
  }

  void _sendOnChannel(int channelId, Uint8List data, MessageType type) {
    if (_isClosed || !_transport.isOpen) {
      _logger.warn('连接已关闭，丢弃一条通道消息（${data.length} 字节）');
      return;
    }
    _transport.sendBinary(
      MultiplexerMessage.encodeFrame(
        type: type,
        channelId: channelId,
        payload: data,
      ),
    );
  }

  int _allocateChannelId() {
    var candidate = _nextId + 1;
    var wrapped = false;
    while (_channels.containsKey(candidate)) {
      candidate += 1;
      if (candidate > maxChannelId) {
        if (wrapped) {
          throw const BusinessException(message: '复用层通道 id 已耗尽');
        }
        candidate = 1;
        wrapped = true;
      }
    }
    _nextId = candidate;
    return candidate;
  }
}
