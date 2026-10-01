import 'package:flutter/material.dart';
import 'package:ws_scrcpy_client/common/widget/empty_view.dart';
import 'package:ws_scrcpy_client/common/widget/error_retry_view.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';
import 'package:ws_scrcpy_client/core/util/message_of.dart';

/// 三态统一渲染：loading → error(可重试) → success(可空态)。
///
/// 页面只需要关心"成功时长什么样"，loading / error / 空态由这里统一处理，
/// 避免各页面各写一套。
class AsyncStateView<T> extends StatelessWidget {
  const AsyncStateView({
    super.key,
    required this.state,
    required this.onRetry,
    required this.dataBuilder,
    this.isEmpty,
    this.emptyMessage = '暂无数据',
    this.emptyHint,
    this.emptyIcon = Icons.inbox_outlined,
    this.loadingBuilder,
    this.errorHint,
    this.isRetrying = false,
  });

  final AsyncState<T> state;
  final Future<void> Function() onRetry;
  final Widget Function(BuildContext context, T data) dataBuilder;

  /// 判定成功数据是否为空（为空时渲染空态）。
  final bool Function(T data)? isEmpty;
  final String emptyMessage;
  final String? emptyHint;
  final IconData emptyIcon;

  /// 局部骨架/进度；不传则使用紧凑的进度指示（避免无脑全屏转圈）。
  final WidgetBuilder? loadingBuilder;

  /// 错误时的可执行建议。
  final String? errorHint;

  final bool isRetrying;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      AsyncLoading<T>() =>
        loadingBuilder?.call(context) ??
            const Center(child: CircularProgressIndicator()),
      AsyncFailure<T>(:final error) => ErrorRetryView(
        message: messageOf(error),
        hint: errorHint,
        isRetrying: isRetrying,
        onRetry: onRetry,
      ),
      AsyncSuccess<T>(:final data) =>
        (isEmpty?.call(data) ?? false)
            ? EmptyView(message: emptyMessage, hint: emptyHint, icon: emptyIcon)
            : dataBuilder(context, data),
    };
  }
}
