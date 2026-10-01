import 'package:flutter/material.dart';
import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';
import 'package:ws_scrcpy_client/feature/device/data/model/vo/device_vo.dart';
import 'package:ws_scrcpy_client/feature/device/enum/device_state.dart';

/// 设备卡片：展示设备信息，并提供"投流"与"网页"两个入口。
class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.onStartStream,
    this.onOpenWebStream,
    this.isLastUsed = false,
  });

  final DeviceVo device;

  /// 原生投流入口；为 null 表示当前不可用，按钮置灰。
  final VoidCallback? onStartStream;

  /// 网页投流入口：用 WebView 打开该设备的网页版投流页。
  final VoidCallback? onOpenWebStream;

  /// 是否为"上次使用过的设备"。
  final bool isLastUsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitleParts = <String>[
      device.udid,
      if (device.androidRelease != null) 'Android ${device.androidRelease}',
      if (device.cpuAbi != null) device.cpuAbi!,
    ];
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    device.name,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _DeviceStateChip(state: device.state),
                if (isLastUsed) ...<Widget>[
                  const SizedBox(width: AppSpacing.sm),
                  Tooltip(
                    message: '上次使用的设备',
                    child: Icon(
                      Icons.history,
                      size: AppIconSize.md,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              subtitleParts.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (device.interfaces.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                '网卡：${device.interfaces.map((item) => '${item.name} ${item.ipv4}').join('，')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: AppSpacing.sm,
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: device.isUsable ? onOpenWebStream : null,
                    icon: const Icon(Icons.language),
                    label: const Text('网页'),
                  ),
                  FilledButton.icon(
                    onPressed: device.isUsable ? onStartStream : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      device.isUsable ? '投流' : device.state.description,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设备状态标签：文案来自枚举，禁止在 UI 里 switch 拼字符串。
class _DeviceStateChip extends StatelessWidget {
  const _DeviceStateChip({required this.state});

  final DeviceState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color background, Color foreground) = switch (state) {
      DeviceState.device => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      DeviceState.offline => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      DeviceState.unauthorized => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      DeviceState.unknown => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        state.description,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: foreground),
      ),
    );
  }
}
