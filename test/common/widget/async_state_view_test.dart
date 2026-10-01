import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ws_scrcpy_client/common/widget/async_state_view.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';

void main() {
  Future<void> pumpState(
    WidgetTester tester,
    AsyncState<List<String>> state, {
    Future<void> Function()? onRetry,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncStateView<List<String>>(
            state: state,
            onRetry: onRetry ?? () async {},
            isEmpty: (List<String> data) => data.isEmpty,
            emptyMessage: '暂无数据',
            emptyHint: '换个时间再试',
            dataBuilder: (BuildContext context, List<String> data) =>
                Text('数据 ${data.length} 条'),
          ),
        ),
      ),
    );
  }

  testWidgets('loading 态渲染进度指示', (WidgetTester tester) async {
    await pumpState(tester, const AsyncLoading<List<String>>());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('error 态渲染文案与重试按钮，点击触发重试', (WidgetTester tester) async {
    var retryCount = 0;
    await pumpState(
      tester,
      const AsyncFailure<List<String>>(RemoteException(message: '连接已断开')),
      onRetry: () async => retryCount++,
    );

    expect(find.text('连接已断开'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '重试'));
    await tester.pump();
    expect(retryCount, 1);
  });

  testWidgets('success 且为空时渲染空态而不是空白', (WidgetTester tester) async {
    await pumpState(tester, const AsyncSuccess<List<String>>(<String>[]));
    expect(find.text('暂无数据'), findsOneWidget);
    expect(find.text('换个时间再试'), findsOneWidget);
  });

  testWidgets('success 且有数据时渲染业务内容', (WidgetTester tester) async {
    await pumpState(
      tester,
      const AsyncSuccess<List<String>>(<String>['a', 'b']),
    );
    expect(find.text('数据 2 条'), findsOneWidget);
  });
}
