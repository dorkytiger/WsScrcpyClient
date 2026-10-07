import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ws_scrcpy_client/app/app_scope.dart';
import 'package:ws_scrcpy_client/app/home_page.dart';
import 'package:ws_scrcpy_client/common/theme/app_theme.dart';
import 'package:ws_scrcpy_client/core/log/app_log_file.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Dart 侧日志也落一份文件（与原生 scrcpy_decoder.log 同一个数据目录/同目录）。
  //
  // 不 await：解析目录要走 path_provider，**绝不能挡住首帧**；解析好之前的日志会丢
  // （启动那几行本来就没什么价值），解析好之后 AppLogger 每条都会同步写入。
  unawaited(AppLogFile.start());
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
