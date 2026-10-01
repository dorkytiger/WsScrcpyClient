import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';

/// 内嵌浏览器不可用时的兜底页。
///
/// 触发场景：当前平台没有可用的 WebView 实现（或实现初始化失败，
/// 例如 Windows 缺少 WebView2 运行时）。此时给出明确可用路径，而不是留白屏。
class BrowserFallbackView extends StatelessWidget {
  const BrowserFallbackView({
    super.key,
    required this.serverUri,
    required this.onOpenInBrowser,
    this.reason,
  });

  final Uri serverUri;

  /// 打开系统浏览器的回调（由 view 注入，便于统一错误反馈）。
  final Future<void> Function(Uri uri) onOpenInBrowser;

  /// 不可用的具体原因（技术细节，便于排查）。
  final String? reason;

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
              Icons.desktop_windows_outlined,
              size: AppIconSize.xl,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('内嵌浏览器不可用', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '暂时可以先用系统浏览器打开服务入口；'
              '原生协议渲染（M2）接入后桌面端不再依赖内嵌浏览器。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (reason != null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Text(
                reason!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: () => onOpenInBrowser(serverUri),
              icon: const Icon(Icons.open_in_new),
              label: const Text('用系统浏览器打开'),
            ),
            const SizedBox(height: AppSpacing.sm),
            SelectableText(
              serverUri.toString(),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// 用系统默认浏览器打开链接；返回是否成功。
Future<bool> openInSystemBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
