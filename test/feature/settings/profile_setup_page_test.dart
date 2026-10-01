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
    // 密码不进库，只进安全存储。
    expect(context.secrets.stored.values, contains('secret'));
  });

  testWidgets('安全存储写不进时仍保存成功，但提示"仅本次会话有效"', (WidgetTester tester) async {
    final context = SettingsTestContext(
      secrets: FakeSecretLocalDatasource(failWrites: true),
    );
    addTearDown(context.dispose);
    final viewModel = SettingsViewModel(context.service);
    addTearDown(viewModel.dispose);

    await pumpSetupPage(tester, viewModel);
    await tester.enterText(
      find.byType(TextField).first,
      'https://android.dorkytiger.top/',
    );
    await tester.enterText(find.byType(TextField).at(1), 'u');
    await tester.enterText(find.byType(TextField).at(2), 'p');
    await tester.tap(find.text('保存并继续'));
    await tester.pump();

    expect(find.textContaining('无法写入系统安全存储'), findsOneWidget);
    final profiles = await context.service.listProfiles();
    expect(profiles.data, hasLength(1));
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
