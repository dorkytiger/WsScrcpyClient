import 'package:flutter/material.dart';
import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';

/// 统一错误视图：可读文案 + 重试入口（规范要求错误态禁止只显示一句红字）。
class ErrorRetryView extends StatelessWidget {
  const ErrorRetryView({
    super.key,
    required this.message,
    required this.onRetry,
    this.isRetrying = false,
    this.hint,
  });

  final String message;
  final Future<void> Function() onRetry;

  /// 重试进行中：按钮进入 pending 并禁用，避免重复触发。
  final bool isRetrying;

  /// 附加的可执行建议（例如"请检查 Basic Auth 账号密码"）。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: AppIconSize.xl,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (hint != null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            FilledButton.tonalIcon(
              onPressed: isRetrying ? null : () => onRetry(),
              icon: isRetrying
                  ? const SizedBox(
                      width: AppIconSize.sm,
                      height: AppIconSize.sm,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(isRetrying ? '重试中…' : '重试'),
            ),
          ],
        ),
      ),
    );
  }
}
