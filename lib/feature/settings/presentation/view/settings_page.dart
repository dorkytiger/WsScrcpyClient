import 'package:flutter/material.dart';
import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';
import 'package:ws_scrcpy_client/common/widget/async_state_view.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';
import 'package:ws_scrcpy_client/core/util/message_of.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/dto/save_settings_dto.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/vo/app_settings_vo.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/vo/settings_profile_vo.dart';
import 'package:ws_scrcpy_client/feature/settings/presentation/view/profile_setup_page.dart';
import 'package:ws_scrcpy_client/feature/settings/presentation/viewmodel/settings_viewmodel.dart';

/// 设置页：当前连接配置的表单 + 配置（profile）管理。
///
/// 凭据只写入系统安全存储（见 `SecretLocalDatasource`），其余字段进本地数据库。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.viewModel});

  final SettingsViewModel viewModel;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _serverUrlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _keepScreenOn = true;
  bool _obscurePassword = true;
  bool _formInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.viewModel.load();
    });
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// 用已保存的设置初始化表单（只做一次，避免覆盖用户正在输入的内容）。
  void _syncForm(AppSettingsVo settings) {
    if (_formInitialized) {
      return;
    }
    _formInitialized = true;
    _serverUrlController.text = settings.serverUrl;
    _usernameController.text = settings.username;
    _passwordController.text = settings.password;
    _keepScreenOn = settings.keepScreenOn;
  }

  Future<void> _save() async {
    final result = await widget.viewModel.save(
      SaveSettingsDto(
        serverUrl: _serverUrlController.text,
        username: _usernameController.text,
        password: _passwordController.text,
        keepScreenOn: _keepScreenOn,
      ),
    );
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (result.isError) {
      messenger.showSnackBar(
        SnackBar(content: Text('保存失败：${messageOf(result.error)}')),
      );
      return;
    }
    final state = widget.viewModel.state;
    final passwordPersisted =
        state is! AsyncSuccess<AppSettingsVo> || state.data.passwordPersisted;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          passwordPersisted ? '设置已保存' : '设置已保存；密码未能写入系统安全存储，本次会话有效，重启后需重填',
        ),
      ),
    );
  }

  Future<void> _openNewProfile(AppSettingsVo settings) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ProfileSetupPage(
          viewModel: widget.viewModel,
          initialSettings: settings,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(SettingsProfileVo profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除配置？'),
        content: Text('将删除「${profile.displayName}」及其保存的密码，此操作不可撤销。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final result = await widget.viewModel.deleteProfile(profile.id);
    if (!mounted) {
      return;
    }
    if (result.isError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：${messageOf(result.error)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (BuildContext context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: AsyncStateView<AppSettingsVo>(
            state: widget.viewModel.state,
            onRetry: widget.viewModel.load,
            dataBuilder: (BuildContext context, AppSettingsVo settings) {
              _syncForm(settings);
              return _buildForm(context, settings);
            },
          ),
        );
      },
    );
  }

  Widget _buildForm(BuildContext context, AppSettingsVo settings) {
    final theme = Theme.of(context);
    final profiles = widget.viewModel.profiles;
    final busyProfileId = widget.viewModel.busyProfileId;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        Text('当前配置', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _serverUrlController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '服务地址',
            hintText: 'https://android.dorkytiger.top/',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Basic Auth（服务端未开启鉴权时留空）', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _usernameController,
          textInputAction: TextInputAction.next,
          autofillHints: const <String>[AutofillHints.username],
          decoration: const InputDecoration(
            labelText: '账号',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          autofillHints: const <String>[AutofillHints.password],
          decoration: InputDecoration(
            labelText: '密码',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              icon: Icon(
                _obscurePassword ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _keepScreenOn,
          onChanged: (bool value) => setState(() => _keepScreenOn = value),
          title: const Text('投流时保持屏幕常亮'),
          subtitle: const Text('避免观看过程中设备自动熄屏'),
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton.icon(
          onPressed: widget.viewModel.isSaving ? null : _save,
          icon: widget.viewModel.isSaving
              ? const SizedBox(
                  width: AppIconSize.sm,
                  height: AppIconSize.sm,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(widget.viewModel.isSaving ? '保存中…' : '保存'),
        ),
        const SizedBox(height: AppSpacing.xl),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '连接配置（${profiles.length}）',
                style: theme.textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: widget.viewModel.isSaving
                  ? null
                  : () => _openNewProfile(settings),
              icon: const Icon(Icons.add),
              label: const Text('新增'),
            ),
          ],
        ),
        if (profiles.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Text(
              '暂无配置，点"新增"创建一套。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final profile in profiles)
            Card(
              margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: ListTile(
                leading: Icon(
                  profile.isActive
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: profile.isActive ? theme.colorScheme.primary : null,
                ),
                title: Text(profile.displayName),
                subtitle: Text(
                  <String>[
                    profile.serverUrl,
                    if (profile.username.isNotEmpty) profile.username,
                    if (profile.lastUdid != null) '上次：${profile.lastUdid}',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (!profile.isActive)
                      TextButton(
                        onPressed: busyProfileId != null
                            ? null
                            : () =>
                                  widget.viewModel.activateProfile(profile.id),
                        child: const Text('切换'),
                      ),
                    IconButton(
                      tooltip: '删除',
                      onPressed: busyProfileId != null
                          ? null
                          : () => _confirmDelete(profile),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '配置保存在本机数据库（drift/SQLite）；密码保存在系统安全存储'
          '（Android Keystore / iOS Keychain / Windows DPAPI），不会写进数据库。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
