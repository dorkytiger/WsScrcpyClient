import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/log/app_logger.dart';
import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/ws/ws_url_builder.dart';
import 'package:ws_scrcpy_client/feature/device/data/model/response/device_list_response.dart';
import 'package:ws_scrcpy_client/feature/device/data/model/vo/device_vo.dart';
import 'package:ws_scrcpy_client/feature/device/data/remote/device_list_remote_datasource.dart';
import 'package:ws_scrcpy_client/feature/settings/application/service/settings_service.dart';

/// 设备用例：把"设置 + 远程数据源"编排成 UI 可直接用的设备列表。
class DeviceListService {
  DeviceListService(
    this._remoteDatasource,
    this._settingsService, {
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger('DeviceListService');

  final DeviceListRemoteDatasource _remoteDatasource;
  final SettingsService _settingsService;
  final AppLogger _logger;

  /// 拉取设备列表（在线设备排前面）。
  Future<Result<List<DeviceVo>>> loadDevices() async {
    final settingsResult = await _settingsService.load();
    if (settingsResult.isError) {
      return Result.failure(settingsResult.error!);
    }
    final settings = settingsResult.data!;
    final authorization = settings.hasBasicAuth
        ? WsUrlBuilder.basicAuthorization(settings.username, settings.password)
        : null;

    final result = await _remoteDatasource.fetchDeviceList(
      serverUri: settings.serverUri,
      authorization: authorization,
    );
    if (result.isError) {
      return Result.failure(result.error!);
    }

    final devices = _toViewObjects(result.data!);
    _logger.info('获取到 ${devices.length} 台设备');
    return Result.success(devices);
  }

  List<DeviceVo> _toViewObjects(DeviceListResponse response) {
    final devices = response.devices
        .map(
          (descriptor) => DeviceVo(
            udid: descriptor.udid,
            state: descriptor.state,
            name: descriptor.model ?? descriptor.udid,
            model: descriptor.model,
            androidRelease: descriptor.androidRelease,
            cpuAbi: descriptor.cpuAbi,
            interfaces: descriptor.interfaces
                .map(
                  (item) => DeviceInterfaceVo(name: item.name, ipv4: item.ipv4),
                )
                .toList(growable: false),
          ),
        )
        .toList();
    devices.sort((a, b) {
      if (a.isUsable != b.isUsable) {
        return a.isUsable ? -1 : 1;
      }
      return a.name.compareTo(b.name);
    });
    return List<DeviceVo>.unmodifiable(devices);
  }

  /// 供调用方在保存校验失败时快速拿到文案。
  static GlobalException? validateTarget(DeviceVo device) => device.isUsable
      ? null
      : ValidationException(
          message: '设备 ${device.name} 当前状态为${device.state.description}，无法投流',
        );
}
