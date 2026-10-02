import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';
import 'package:ws_scrcpy_client/common/widget/async_state_view.dart';
import 'package:ws_scrcpy_client/core/debug/debug_bootstrap.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';
import 'package:ws_scrcpy_client/feature/device/data/model/vo/device_vo.dart';
import 'package:ws_scrcpy_client/feature/device/presentation/viewmodel/device_list_viewmodel.dart';
import 'package:ws_scrcpy_client/feature/device/presentation/widget/device_card.dart';

/// 设备列表页：三态 + 下拉刷新 + 每台设备两个入口（原生投流 / 网页投流）。
class DeviceListPage extends StatefulWidget {
  const DeviceListPage({
    super.key,
    required this.viewModel,
    required this.onStartStream,
    this.onOpenWebStream,
    this.lastUdid,
  });

  final DeviceListViewModel viewModel;

  /// 由应用层注入的跨模块导航（避免 feature 之间互相 import presentation）。
  final Future<void> Function(DeviceVo device) onStartStream;

  /// 用 WebView 打开该设备的网页版投流页。
  final Future<void> Function(DeviceVo device)? onOpenWebStream;

  /// "上次使用过的设备"（来自设置）。
  final String? lastUdid;

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  /// 诊断用自动投流是否已触发（只触发一次）。
  bool _autostartTriggered = false;

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_onViewModelChanged);
    // view 只触发加载，具体编排在 viewmodel/service。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.viewModel.load();
    });
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_onViewModelChanged);
    super.dispose();
  }

  void _onViewModelChanged() {
    final state = widget.viewModel.state;
    if (state is AsyncSuccess<List<DeviceVo>>) {
      _maybeAutostart(state.data);
    }
  }

  /// 诊断用自动投流：`WS_SCRCPY_AUTOSTART=1` 时，设备列表一就绪就自动打开第一台可用设备。
  ///
  /// **为什么要它（2026-10-01）**：真机上"点开设备 → 投流"是两次人工操作，而要排查
  /// "画面周期性卡几秒"这类问题必须**反复跑**、还得能一边跑一边读日志。
  /// 有了它，开发者可以直接
  /// `WS_SCRCPY_AUTOSTART=1 build\...\Release\ws_scrcpy_client.exe`
  /// 在自己这边复现 —— 不必把用户当测试机（被要求"再跑一次"是很消耗耐心的）。
  ///
  /// **默认关闭**：不设这个变量时行为与以前完全一致；只在第一次加载成功时触发一次。
  void _maybeAutostart(List<DeviceVo> devices) {
    if (_autostartTriggered) {
      return;
    }
    // 两条入口同一个语义：桌面端用宿主环境变量，iOS/Android 拿不到宿主环境变量，
    // 用编译期的 `--dart-define=WS_SCRCPY_AUTOSTART=1`。
    final fromEnvironment = Platform.environment['WS_SCRCPY_AUTOSTART'] == '1';
    if (!fromEnvironment && !DebugBootstrap.isAutostartEnabled) {
      return;
    }
    final DeviceVo? device = devices
        .where((DeviceVo item) => item.isUsable)
        .firstOrNull;
    if (device == null) {
      return;
    }
    _autostartTriggered = true;
    AppLogger('Autostart')
        .info('WS_SCRCPY_AUTOSTART=1：自动打开设备 ${device.name}（${device.udid}）');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onStartStream(device);
      }
    });
  }

  /// 错误提示要能指向真正的下一步：读不了本地设置 ≠ 凭据填错。
  String? _errorHint(AsyncState<List<DeviceVo>> state) {
    if (state is AsyncFailure<List<DeviceVo>>) {
      final error = state.error;
      if (error is LocalStorageException) {
        return '本机无法写入应用数据目录，请从普通终端/IDE 启动 App（受限沙箱会拦截 %APPDATA% 写入）';
      }
      if (error is ValidationException) {
        return '请在"设置"里修正服务地址或 Basic Auth 凭据';
      }
    }
    return '请在"设置"里确认服务地址与 Basic Auth 凭据';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (BuildContext context, _) {
        final state = widget.viewModel.state;
        return Scaffold(
          appBar: AppBar(
            title: const Text('设备列表'),
            actions: <Widget>[
              IconButton(
                tooltip: '刷新',
                onPressed: widget.viewModel.isRefreshing
                    ? null
                    : () => widget.viewModel.refresh(),
                icon: widget.viewModel.isRefreshing
                    ? const SizedBox(
                        width: AppIconSize.md,
                        height: AppIconSize.md,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          body: AsyncStateView<List<DeviceVo>>(
            state: state,
            isRetrying: widget.viewModel.isRefreshing,
            onRetry: widget.viewModel.load,
            errorHint: _errorHint(state),
            emptyMessage: '没有发现设备',
            emptyHint: '请确认设备已连接服务端并处于在线状态',
            emptyIcon: Icons.devices_other_outlined,
            dataBuilder: (BuildContext context, List<DeviceVo> devices) =>
                RefreshIndicator(
                  onRefresh: widget.viewModel.refresh,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm,
                    ),
                    itemCount: devices.length,
                    itemBuilder: (BuildContext context, int index) {
                      final device = devices[index];
                      return DeviceCard(
                        device: device,
                        isLastUsed: device.udid == widget.lastUdid,
                        onStartStream: device.isUsable
                            ? () => widget.onStartStream(device)
                            : null,
                        onOpenWebStream: device.isUsable
                            ? () => widget.onOpenWebStream?.call(device)
                            : null,
                      );
                    },
                  ),
                ),
          ),
        );
      },
    );
  }
}
