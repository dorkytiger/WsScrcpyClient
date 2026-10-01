import 'package:flutter/material.dart';
import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';

/// 统一空态视图（查询成功但无数据时必须渲染它，而不是空白页）。
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.hint,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String message;
  final String? hint;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: AppIconSize.xl, color: theme.colorScheme.outline),
            const SizedBox(height: AppSpacing.md),
            Text(message, style: theme.textTheme.bodyLarge),
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
            if (action != null) ...<Widget>[
              const SizedBox(height: AppSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
