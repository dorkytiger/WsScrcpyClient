/// 设计 token：间距 / 圆角 / 动效时长 / 图标尺寸。
///
/// 规范要求 UI 里禁止出现 `12`、`16` 这类裸数字，一律引用这里或主题。
class AppSpacing {
  const AppSpacing._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// 圆角 token。
class AppRadius {
  const AppRadius._();

  static const double sm = 6;
  static const double md = 10;
  static const double lg = 16;
  static const double pill = 999;
}

/// 动效时长 token。
class AppDurations {
  const AppDurations._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);
}

/// 图标尺寸 token。
class AppIconSize {
  const AppIconSize._();

  static const double sm = 16;
  static const double md = 20;
  static const double lg = 24;
  static const double xl = 32;
}

/// 响应式断点：宽屏切侧边导航。
class AppBreakpoints {
  const AppBreakpoints._();

  static const double wide = 720;
}

/// 业务相关的协议默认值（非 UI token，集中放置避免散落魔数）。
class AppDefaults {
  const AppDefaults._();

  /// 默认服务端入口（文档 §0 的公网入口）。
  static const String serverUrl = 'https://android.dorkytiger.top/';

  /// 设备列表等待超时。
  static const Duration deviceListTimeout = Duration(seconds: 12);

  /// 投流连接等待初始信息头的超时。
  static const Duration streamInitialInfoTimeout = Duration(seconds: 12);

  /// 会话建立后是否自动唤醒被控设备屏幕。
  ///
  /// **默认关，且它不是"进去黑屏"的修复**：真实服务端 `bundle.js` 里网页端根本不发唤醒键
  /// （`WAKEUP` 只命中常量表、没有自动调用点）。黑屏的正解是"视频参数只发一次、
  /// 且回显服务端给的值"（见 `StreamSessionService._scheduleFirstVideoSettings` 与 AGENTS §12.5）。
  /// 保留它是因为**有些设备确实会因为屏幕休眠而出不了帧**，需要时用户可以自己开。
  static const bool wakeDeviceOnConnect = false;

  /// 首发视频参数时"等 UI 上报视口尺寸"的时长。
  ///
  /// 等到了就一次到位（带上 bounds，只发一条）；超时则退化为不带 bounds 先发一条，
  /// 避免因为 UI 没布局而永远不发参数（不发就完全没有画面）。
  static const Duration settingsFallbackDelay = Duration(milliseconds: 300);
}
