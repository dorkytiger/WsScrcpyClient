import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/feature/settings/presentation/view/profile_setup_page.dart';
import 'package:ws_scrcpy_client/feature/settings/presentation/viewmodel/settings_viewmodel.dart';

import 'settings_test_support.dart';

/// 首次进入的配置表单：这是"初始化先让用户填表单"的核心交互，必须有测试守着。
void main() {
  Future<void> pumpSetupPage(
    WidgetTester tester,
    SettingsViewModel viewModel, {
    bool isFirstRun = true,
    Future<void> Function()? onCompleted,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: ProfileSetupPage(
          viewModel: viewModel,
          isFirstRun: isFirstRun,
          onCompleted: onCompleted,
        ),
      ),
    );
  }

  /// ★ 原生端必须**保留**密码输入框。
  ///
  /// 对照背景（2026-10-02）：web 上密码框被藏掉了 —— 浏览器不允许 WebSocket 携带
  /// 自定义请求头，填了也用不上，留着只会让人以为"填了密码就能连"。
  /// 但这个 `if (!isWebPlatform)` 是**编译期**分支（VM 上恒为原生），
  /// 所以这条测试守的是"原生端别被顺手改没"，web 那一侧只能靠浏览器实跑看。
  testWidgets('原生端保留 Basic Auth 密码输入框（web 上才隐藏）', (WidgetTester tester) async {
    final context = SettingsTestContext();
    addTearDown(context.dispose);
    final viewModel = SettingsViewModel(context.service);
    addTearDown(viewModel.dispose);

    await pumpSetupPage(tester, viewModel);

    expect(find.text('Basic Auth 密码（可留空）'), findsOneWidget);
    expect(find.textContaining('密码写入系统安全存储'), findsOneWidget);
  });

  testWidgets('首次进入：地址非法时给出校验提示且不落库', (WidgetTester tester) async {
    final context = SettingsTestContext();
    addTearDown(context.dispose);
    final viewModel = SettingsViewModel(context.service);
    addTearDown(viewModel.dispose);

    await pumpSetupPage(tester, viewModel);
    await tester.enterText(find.byType(TextField).first, 'not-a-url');
    await tester.tap(find.text('保存并继续'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('服务地址不合法'), findsOneWidget);
    final profiles = await context.service.listProfiles();
    expect(profiles.data, isEmpty);
  });

  testWidgets('首次进入：填完表单保存成功后触发 onCompleted 并落库', (WidgetTester tester) async {
    final context = SettingsTestContext();
    addTearDown(context.dispose);
    final viewModel = SettingsViewModel(context.service);
    addTearDown(viewModel.dispose);

    var completed = false;
    await pumpSetupPage(
      tester,
      viewModel,
      onCompleted: () async => completed = true,
    );

    await tester.enterText(
      find.byType(TextField).first,
      'https://android.dorkytiger.top/',
    );
    await tester.enterText(find.byType(TextField).at(1), 'u758272094');
    await tester.enterText(find.byType(TextField).at(2), 'secret');
    await tester.tap(find.text('保存并继续'));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    final profiles = await context.service.listProfiles();
    expect(profiles.data, hasLength(1));
    expect(profiles.data!.single.isActive, isTrue);
    expect(profiles.data!.single.username, 'u758272094');
    // 密码明文落在 connection_profiles.password（2026-10-07 去掉了 flutter_secure_storage）。
    final rows = await context.database
        .select(context.database.connectionProfiles)
        .get();
    expect(rows.single.password, 'secret');
  });

  test('视图模型：hasProfile 从 false 变为 true 驱动首次进入的判定', () async {
    final context = SettingsTestContext();
    addTearDown(context.dispose);
    final viewModel = SettingsViewModel(context.service);
    addTearDown(viewModel.dispose);

    await viewModel.load();
    expect(viewModel.hasProfile, isFalse);

    await context.createProfile();
    await viewModel.load();
    expect(viewModel.hasProfile, isTrue);
    expect(viewModel.profiles, hasLength(1));
  });

  test('视图模型：删除最后一套配置后回到"需要初始化"', () async {
    final context = SettingsTestContext();
    addTearDown(context.dispose);
    final viewModel = SettingsViewModel(context.service);
    addTearDown(viewModel.dispose);

    final id = await context.createProfile();
    await viewModel.load();
    expect(viewModel.hasProfile, isTrue);

    final result = await viewModel.deleteProfile(id);
    expect(result.isSuccess, isTrue);
    expect(viewModel.hasProfile, isFalse);
    expect(viewModel.profiles, isEmpty);
  });
}
