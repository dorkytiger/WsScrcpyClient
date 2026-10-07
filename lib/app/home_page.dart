import 'package:flutter/material.dart';
import 'package:ws_scrcpy_client/app/app_scope.dart';
import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';
import 'package:ws_scrcpy_client/core/stream/stream_target.dart';
import 'package:ws_scrcpy_client/core/util/message_of.dart';
import 'package:ws_scrcpy_client/feature/device/data/model/vo/device_vo.dart';
import 'package:ws_scrcpy_client/feature/device/presentation/view/device_list_page.dart';
import 'package:ws_scrcpy_client/feature/settings/application/service/settings_service.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/vo/app_settings_vo.dart';
import 'package:ws_scrcpy_client/feature/settings/presentation/view/profile_setup_page.dart';
import 'package:ws_scrcpy_client/feature/settings/presentation/view/settings_page.dart';
import 'package:ws_scrcpy_client/feature/shell/presentation/view/webview_shell_page.dart';
import 'package:ws_scrcpy_client/feature/shell/presentation/viewmodel/webview_shell_viewmodel.dart';
import 'package:ws_scrcpy_client/feature/stream/presentation/view/player_page.dart';
import 'package:ws_scrcpy_client/feature/stream/presentation/viewmodel/player_viewmodel.dart';

/// 应用主框架：两个页签（设备 / 设置）。
///
/// 投流与"网页投流"都从**设备卡片**进入（不是独立的标签页），
/// 跨 feature 的导航只在这一层做，feature 之间不互相 import presentation。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 设置是其他页面的前提，进入应用即加载一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.of(context).settingsViewModel.load();
    });
  }

  /// 当前生效的设置：加载失败或未加载完成时回落出厂默认值。
  AppSettingsVo get _settings {
    final state = AppScope.of(context).settingsViewModel.state;
    return state is AsyncSuccess<AppSettingsVo>
        ? state.data
        : SettingsService.defaults;
  }

  /// 用 WebView 打开该设备的网页版投流页（深链直达画面）。
  Future<void> _openWebStream(DeviceVo device) async {
    final settings = _settings;
    final target = StreamTarget(
      serverUri: settings.serverUri,
      udid: device.udid,
      interfaceHosts: device.interfaceHosts,
    );
    final shellViewModel = WebviewShellViewModel();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => WebviewShellPage(
          viewModel: shellViewModel,
          initialUri: target.webPlayerUri(),
          title: device.name,
          basicAuthUsername: settings.username,
          basicAuthPassword: settings.password,
          keepScreenOn: settings.keepScreenOn,
        ),
      ),
    );
    shellViewModel.dispose();
  }

  /// 从设备列表进入投流页。
  Future<void> _openStream(DeviceVo device) async {
    final dependencies = AppScope.of(context);
    final settings = _settings;
    final target = StreamTarget(
      serverUri: settings.serverUri,
      udid: device.udid,
      interfaceHosts: device.interfaceHosts,
    );

    // 记住上次设备：失败只提示，不阻断投流。
    final rememberResult = await dependencies.settingsService
        .rememberLastDevice(device.udid);
    if (!mounted) {
      return;
    }
    if (rememberResult.isError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('记住设备失败：${messageOf(rememberResult.error)}')),
      );
    }

    final playerViewModel = PlayerViewModel(dependencies.streamSessionService);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PlayerPage(
          viewModel: playerViewModel,
          target: target,
          title: device.name,
          authorization: settings.basicAuthorizationHeader,
          keepScreenOn: settings.keepScreenOn,
        ),
      ),
    );
    playerViewModel.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dependencies = AppScope.of(context);
    final settingsViewModel = dependencies.settingsViewModel;
    // 首次进入的判定与设置变化都要驱动重建，所以整个外壳订阅设置 viewmodel。
    return ListenableBuilder(
      listenable: settingsViewModel,
      builder: (BuildContext context, _) =>
          _buildScaffold(context, dependencies),
    );
  }

  Widget _buildScaffold(BuildContext context, AppDependencies dependencies) {
    final settingsViewModel = dependencies.settingsViewModel;
    // 还没有任何连接配置：先让用户填表单（"初始化先叫用户填表单"）。
    if (settingsViewModel.hasProfile == false) {
      return ProfileSetupPage(
        viewModel: settingsViewModel,
        isFirstRun: true,
        onCompleted: settingsViewModel.load,
      );
    }
    // 判定中：不要闪一下设备列表的错误态，先给一个安静的加载态。
    if (settingsViewModel.hasProfile == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final settings = _settings;
    final pages = <Widget>[
      DeviceListPage(
        viewModel: dependencies.deviceListViewModel,
        lastUdid: settings.lastUdid,
        onStartStream: _openStream,
        onOpenWebStream: _openWebStream,
      ),
      SettingsPage(viewModel: dependencies.settingsViewModel),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 桌面宽屏用侧边导航，窄屏用底部导航栏。
        final useRail = constraints.maxWidth >= AppBreakpoints.wide;
        return Scaffold(
          body: useRail
              ? Row(
                  children: <Widget>[
                    NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: (int value) =>
                          setState(() => _index = value),
                      labelType: NavigationRailLabelType.all,
                      destinations: _railDestinations,
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: pages[_index]),
                  ],
                )
              : pages[_index],
          bottomNavigationBar: useRail
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (int value) =>
                      setState(() => _index = value),
                  destinations: _destinations,
                ),
        );
      },
    );
  }

  List<NavigationDestination> get _destinations =>
      const <NavigationDestination>[
        NavigationDestination(
          icon: Icon(Icons.devices_other_outlined),
          selectedIcon: Icon(Icons.devices_other),
          label: '设备',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '设置',
        ),
      ];

  List<NavigationRailDestination> get _railDestinations =>
      const <NavigationRailDestination>[
        NavigationRailDestination(
          icon: Icon(Icons.devices_other_outlined),
          selectedIcon: Icon(Icons.devices_other),
          label: Text('设备'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: Text('设置'),
        ),
      ];
}
