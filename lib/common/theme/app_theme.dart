import 'package:flutter/material.dart';

/// 应用主题：所有颜色都从这里（Material 3 配色方案）取，业务代码禁止硬编码色值。
class AppTheme {
  const AppTheme._();

  /// 品牌主色种子：唯一允许出现具体色值的地方。
  static const Color _seedColor = Color(0xFF2E6BE6);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
      ),
    );
  }
}
