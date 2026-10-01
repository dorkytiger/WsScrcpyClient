import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/ws/multiplexed_socket.dart';
import 'package:ws_scrcpy_client/core/ws/web_socket_transport.dart';
import 'package:ws_scrcpy_client/core/ws/ws_action.dart';
import 'package:ws_scrcpy_client/core/ws/ws_error_translator.dart';
import 'package:ws_scrcpy_client/core/ws/ws_url_builder.dart';
import 'package:ws_scrcpy_client/feature/device/data/model/response/device_list_response.dart';

/// 设备列表远程数据源。
///
/// 实测（M0）：设备列表**不是** HTTP 接口，而是复用层通道：
/// 连 `wss://<host>/?action=multiplex` → 发 `CreateChannel("GTRC")` →
/// 服务端在该通道上下发 `{"type":"devicelist","data":{"list":[…]}}` 文本消息。
class DeviceListRemoteDatasource {
  DeviceListRemoteDatasource({AppLogger? logger})
    : _logger = logger ?? AppLogger('DeviceListRemoteDatasource');

  final AppLogger _logger;

  /// 拉取一次设备列表快照。
  Future<Result<DeviceListResponse>> fetchDeviceList({
    required Uri serverUri,
    String? authorization,
    Duration timeout = AppDefaults.deviceListTimeout,
  }) async {
    final WebSocketTransport transport;
    try {
      transport = await IoWebSocketTransport.connect(
        WsUrlBuilder.action(serverUri, WsAction.multiplex),
        authorization: authorization,
        timeout: timeout,
      );
    } catch (error, stackTrace) {
      _logger.warn('连接复用层失败', error, stackTrace);
      return Result.failure(translateHandshakeError(error, stackTrace));
    }

    final socket = MultiplexedSocket(transport, logger: _logger);
    final completer = Completer<Result<DeviceListResponse>>();
    final channelResult = socket.createChannel(
      Uint8List.fromList(ascii.encode(ChannelCode.gtrc.code)),
    );
    if (channelResult.isError) {
      await socket.dispose();
      return Result.failure(channelResult.error!);
    }
    final channel = channelResult.data!;

    final subscription = channel.messages.listen((message) {
      if (completer.isCompleted) {
        return;
      }
      try {
        final response = DeviceListResponse.parse(message.decodeText());
        completer.complete(Result.success(response));
      } on ParsingException catch (error, stackTrace) {
        _logger.warn('设备列表消息解析失败', error, stackTrace);
        // 单条消息解析失败不代表连接不可用，继续等后续消息，超时统一兜底。
      }
    });

    final errorSubscription = socket.errors.listen((error) {
      if (!completer.isCompleted) {
        completer.complete(Result.failure(error));
      }
    });

    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(
          Result.failure(
            RemoteException(
              message: '等待设备列表超时（${timeout.inSeconds} 秒），请确认服务端在线且凭据正确',
            ),
          ),
        );
      }
    });

    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
      await errorSubscription.cancel();
      await socket.dispose();
    }
  }
}
