import 'package:flutter/foundation.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';
import 'package:ws_scrcpy_client/feature/device/application/service/device_list_service.dart';
import 'package:ws_scrcpy_client/feature/device/data/model/vo/device_vo.dart';

/// 设备列表视图模型：只负责展示状态与交互触发，业务编排都在 [DeviceListService]。
class DeviceListViewModel extends ChangeNotifier {
  DeviceListViewModel(this._service);

  final DeviceListService _service;

  AsyncState<List<DeviceVo>> _state = const AsyncLoading();
  bool _isRefreshing = false;

  /// 列表三态。
  AsyncState<List<DeviceVo>> get state => _state;

  /// 是否正在刷新（下拉刷新 / 重试按钮 pending）。
  bool get isRefreshing => _isRefreshing;

  /// 加载（首次进入或重试）。
  Future<void> load() async {
    _state = const AsyncLoading();
    notifyListeners();
    await _refreshInternal();
  }

  /// 下拉刷新：保留当前列表，只提示正在刷新。
  Future<void> refresh() async {
    if (_isRefreshing) {
      return;
    }
    _isRefreshing = true;
    notifyListeners();
    try {
      await _refreshInternal();
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  Future<void> _refreshInternal() async {
    final result = await _service.loadDevices();
    if (result.isError) {
      _state = AsyncFailure<List<DeviceVo>>(result.error!);
    } else {
      _state = AsyncSuccess<List<DeviceVo>>(result.data!);
    }
    notifyListeners();
  }
}
