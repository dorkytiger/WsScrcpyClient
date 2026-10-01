import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';
import 'package:ws_scrcpy_client/feature/stream/application/service/stream_session_service.dart';
import 'package:ws_scrcpy_client/feature/stream/data/model/bo/stream_session_snapshot.dart';
import 'package:ws_scrcpy_client/feature/stream/data/remote/stream_remote_datasource.dart';
import 'package:ws_scrcpy_client/feature/stream/enum/stream_connection_status.dart';
import 'package:ws_scrcpy_client/feature/stream/presentation/viewmodel/player_viewmodel.dart';

/// 永远连不上的数据源：用于验证失败路径与"服务复用"行为，不触碰真实网络。
class _AlwaysFailingRemoteDatasource extends StreamRemoteDatasource {
  @override
  Future<Result<StreamSession>> connect({
    required Uri uri,
    String? authorization,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    return Result.failure(const RemoteException(message: '测试用：连接失败'));
  }
}

void main() {
  final target = StreamTarget(
    serverUri: Uri.parse('https://android.dorkytiger.top/'),
    udid: 'redroid:5555',
    interfaceHosts: const <String>['127.0.0.1'],
  );

  test('会话服务是共享单例：上一个投流页 dispose 后，下一个页面仍能收到快照', () async {
    final service = StreamSessionService(_AlwaysFailingRemoteDatasource());
    addTearDown(service.dispose);

    // 第一个页面：连接失败（会进入退避重连），随后被销毁。
    final firstPageViewModel = PlayerViewModel(service);
    await firstPageViewModel.connect(target: target);
    firstPageViewModel.dispose();

    // 第二个页面复用同一个 service，必须仍然收到快照（回归：
    // 曾经在 viewmodel.dispose 里 dispose 了 service，导致流被永久关闭）。
    final snapshots = <StreamSessionSnapshot>[];
    final subscription = service.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    final secondPageViewModel = PlayerViewModel(service);
    addTearDown(secondPageViewModel.dispose);
    await secondPageViewModel.connect(target: target);
    await pumpEventQueue();

    expect(
      snapshots.any(
        (snapshot) =>
            snapshot.status == StreamConnectionStatus.connecting ||
            snapshot.status == StreamConnectionStatus.reconnecting,
      ),
      isTrue,
      reason: '共享的 StreamSessionService 被上一个页面关掉后，新页面就收不到任何快照',
    );
  });
}
