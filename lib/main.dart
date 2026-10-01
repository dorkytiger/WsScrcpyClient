import 'package:flutter/material.dart';
import 'package:ws_scrcpy_client/app/app_scope.dart';
import 'package:ws_scrcpy_client/app/home_page.dart';
import 'package:ws_scrcpy_client/common/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WsScrcpyApp());
}

/// 应用根组件：只负责装配依赖、主题与首屏。
class WsScrcpyApp extends StatefulWidget {
  const WsScrcpyApp({super.key});

  @override
  State<WsScrcpyApp> createState() => _WsScrcpyAppState();
}

class _WsScrcpyAppState extends State<WsScrcpyApp> {
  late final AppDependencies _dependencies;

  @override
  void initState() {
    super.initState();
    _dependencies = AppDependencies.create();
  }

  @override
  void dispose() {
    _dependencies.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      dependencies: _dependencies,
      child: MaterialApp(
        title: 'ws-scrcpy 客户端',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: const HomePage(),
      ),
    );
  }
}
