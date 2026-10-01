import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

/// 统一错误文案提取入口：UI 层禁止自行 `String(e)` / `e.message` 拼文案。
String messageOf(Object? error) =>
    error is GlobalException ? error.message : '发生未知错误';
