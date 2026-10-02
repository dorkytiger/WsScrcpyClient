import 'package:flutter/material.dart';
import 'package:ws_scrcpy_client/common/theme/app_tokens.dart';
import 'package:ws_scrcpy_client/core/platform/platform_capabilities.dart';
import 'package:ws_scrcpy_client/core/state/async_state.dart';
import 'package:ws_scrcpy_client/core/util/message_of.dart';
import 'package:ws_scrcpy_client/feature/settings/application/service/settings_service.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/dto/save_settings_dto.dart';
import 'package:ws_scrcpy_client/feature/settings/data/model/vo/app_settings_vo.dart';
import 'package:ws_scrcpy_client/feature/settings/presentation/viewmodel/settings_viewmodel.dart';

/// 连接配置表单。
///
/// 两种用法：
/// - 首次进入（`isFirstRun = true`）：应用还没有任何配置，直接展示这个表单，
///   保存成功后由应用层切到主界面；
/// - 新增配置：从设置页 push 进来，保存成功后返回。
class ProfileSetupPage extends StatefulWidget {
  const ProfileSetupPage({
    super.key,
    required this.viewModel,
    this.isFirstRun = false,
    this.initialSettings,
    this.onCompleted,
  });

  final SettingsViewModel viewModel;

  /// 是否为"首次进入"形态（无返回按钮、带引导说明）。
  final bool isFirstRun;

  /// 预填值（编辑/新增时用当前设置）。
  final AppSettingsVo? initialSettings;

  /// 首次进入保存成功后的回调（应用层据此切到设备列表）。
  final Future<void> Function()? onCompleted;

  @override
  State<ProfileSetupPage> createState() => _ProfileSetupPageState();
}

class _ProfileSetupPageState extends State<ProfileSetupPage> {
  final TextEditingController _serverUrlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _keepScreenOn = true;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSettings ?? SettingsService.defaults;
    _serverUrlController.text = initial.serverUrl;
    _usernameController.text = initial.username;
    _passwordController.text = initial.password;
    _keepScreenOn = initial.keepScreenOn;
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// 密码写不进系统安全存储时的降级提示（受限环境把密码留在内存里，仅本次会话有效）。
  String? _passwordPersistenceWarning() {
    final state = widget.viewModel.state;
    if (state is AsyncSuccess<AppSettingsVo> && !state.data.passwordPersisted) {
      return '密码无法写入系统安全存储，本次会话有效，重启后需要重新填写';
    }
    return null;
  }

  Future<void> _submit() async {
    final result = await widget.viewModel.createProfile(
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
    final warning = _passwordPersistenceWarning();
    if (warning != null) {
      messenger.showSnackBar(SnackBar(content: Text(warning)));
    }
    if (widget.isFirstRun) {
      await widget.onCompleted?.call();
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(warning ?? '配置已创建')));
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (BuildContext context, _) {
        final isSaving = widget.viewModel.isSaving;
        final body = Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(AppSpacing.xl),
              children: <Widget>[
                Icon(
                  Icons.settings_input_antenna,
                  size: AppIconSize.xl,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  widget.isFirstRun ? '先配置服务端' : '新增连接配置',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  // web 上**不能**让用户以为"填了密码就能连上"：浏览器不允许 WebSocket
                  // 携带自定义请求头，我们根本用不到这个密码，凭据由浏览器自己按 origin 保管。
                  // 让用户白填一次密码，正是"为什么还要我再登录一次"的来源。
                  isWebPlatform
                      ? '填写 ws-scrcpy 服务入口。\n'
                            '密码不用填：Basic 凭据由浏览器保管 —— 连接时会弹一次系统登录框，'
                            '输入后勾选「记住密码」，之后就不用再输了。'
                      : '填写 ws-scrcpy 服务入口；服务端开启了 Basic Auth 时再填账号密码。\n'
                            '配置保存在本机数据库中，密码写入系统安全存储。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                TextField(
                  controller: _serverUrlController,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '服务地址',
                    hintText: 'https://android.dorkytiger.top/',
                    helperText: '内网调试可用 http://192.168.11.132:8000/',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                TextField(
                  controller: _usernameController,
                  textInputAction: TextInputAction.next,
                  autofillHints: const <String>[AutofillHints.username],
                  decoration: const InputDecoration(
                    labelText: 'Basic Auth 账号（可留空）',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                // 密码框在 web 上**藏起来**：填了也用不上（浏览器不给 WebSocket 加请求头），
                // 留着只会让人以为"填了密码就能连"。
                if (!isWebPlatform)
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    autofillHints: const <String>[AutofillHints.password],
                    onSubmitted: (_) => isSaving ? null : _submit(),
                    decoration: InputDecoration(
                      labelText: 'Basic Auth 密码（可留空）',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: AppSpacing.sm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _keepScreenOn,
                  onChanged: (bool value) =>
                      setState(() => _keepScreenOn = value),
                  title: const Text('投流时保持屏幕常亮'),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  onPressed: isSaving ? null : _submit,
                  icon: isSaving
                      ? const SizedBox(
                          width: AppIconSize.sm,
                          height: AppIconSize.sm,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(isSaving ? '保存中…' : '保存并继续'),
                ),
              ],
            ),
          ),
        );

        if (widget.isFirstRun) {
          return Scaffold(body: SafeArea(child: body));
        }
        return Scaffold(
          appBar: AppBar(title: const Text('新增连接配置')),
          body: body,
        );
      },
    );
  }
}
