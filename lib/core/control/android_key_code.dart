/// Android `KeyEvent` keycode 常量表。
///
/// 取值**实测自真实服务端网页 bundle** `.probe/bundle.js` 里的 `AndroidKeyCode`
/// 表（例如 `e.KEYCODE_HOME=3`、`e.KEYCODE_APP_SWITCH=187`），与
/// `android.view.KeyEvent` 常量一致，**不可自行改动**。
///
/// 这里只收录本客户端快捷栏/键盘映射真正会用到的取值；需要更多时从同一张表继续抄，
/// 不要凭记忆写数字。用 `class + static const int` 而非 enum：keycode 是一个开放集合
/// （Android 有 280+ 个），枚举无法表达"设备回传的任意 keycode"，而常量表可以按需取用。
class AndroidKeyCode {
  const AndroidKeyCode._();

  /// 未定义按键（`KEYCODE_UNKNOWN`）。
  static const int unknown = 0;

  /// 主屏（`KEYCODE_HOME`）。
  static const int home = 3;

  /// 返回（`KEYCODE_BACK`）。
  static const int back = 4;

  /// 最近任务/概览（`KEYCODE_APP_SWITCH`）。
  static const int appSwitch = 187;

  /// 电源键（`KEYCODE_POWER`）。
  static const int power = 26;

  /// 休眠（`KEYCODE_SLEEP`）。
  static const int sleep = 223;

  /// 唤醒（`KEYCODE_WAKEUP`）。
  static const int wakeup = 224;

  /// 音量加（`KEYCODE_VOLUME_UP`）。
  static const int volumeUp = 24;

  /// 音量减（`KEYCODE_VOLUME_DOWN`）。
  static const int volumeDown = 25;

  /// 静音（`KEYCODE_VOLUME_MUTE`）。
  static const int volumeMute = 164;

  /// 菜单（`KEYCODE_MENU`）。
  static const int menu = 82;

  /// 通知栏（`KEYCODE_NOTIFICATION`）。
  static const int notification = 83;

  /// 回车（`KEYCODE_ENTER`）。
  static const int enter = 66;

  /// 退格（`KEYCODE_DEL`，Android 里就是 backspace）。
  static const int del = 67;

  /// 前向删除（`KEYCODE_FORWARD_DEL`）。
  static const int forwardDel = 112;

  /// Tab（`KEYCODE_TAB`）。
  static const int tab = 61;

  /// 空格（`KEYCODE_SPACE`）。
  static const int space = 62;

  /// Esc（`KEYCODE_ESCAPE`）。
  static const int escape = 111;

  /// 方向键上（`KEYCODE_DPAD_UP`）。
  static const int dpadUp = 19;

  /// 方向键下（`KEYCODE_DPAD_DOWN`）。
  static const int dpadDown = 20;

  /// 播放/暂停（`KEYCODE_MEDIA_PLAY_PAUSE`）。
  static const int mediaPlayPause = 85;

  /// 相机（`KEYCODE_CAMERA`）。
  static const int camera = 27;

  /// 语音助手（`KEYCODE_ASSIST`）。
  static const int assist = 219;

  /// 亮度减（`KEYCODE_BRIGHTNESS_DOWN`）。
  static const int brightnessDown = 220;

  /// 亮度加（`KEYCODE_BRIGHTNESS_UP`）。
  static const int brightnessUp = 221;

  // ---------------------------------------------------------------------------
  // M3（物理键盘映射）新增：桌面端真的会按到的那些键。
  // 取值同 Android `KeyEvent` 官方定义（`KEYCODE_DPAD_LEFT` 等）。
  // ---------------------------------------------------------------------------

  /// 方向键左（`KEYCODE_DPAD_LEFT`）。
  static const int dpadLeft = 21;

  /// 方向键右（`KEYCODE_DPAD_RIGHT`）。
  static const int dpadRight = 22;

  /// 方向键中键 / 确认（`KEYCODE_DPAD_CENTER`）。
  static const int dpadCenter = 23;

  /// 行首（`KEYCODE_MOVE_HOME`）。
  static const int moveHome = 122;

  /// 行尾（`KEYCODE_MOVE_END`）。
  static const int moveEnd = 123;

  /// 上一页（`KEYCODE_PAGE_UP`）。
  static const int pageUp = 92;

  /// 下一页（`KEYCODE_PAGE_DOWN`）。
  static const int pageDown = 93;

  /// 字母 A 的 keycode；A..Z 连续，值为 29..54（即 `'A'` 的 ASCII 减 36）。
  static const int letterA = 29;

  /// 字母 Z 的 keycode。
  static const int letterZ = 54;

  /// 数字 0 的 keycode；0..9 连续，值为 7..16。
  static const int digit0 = 7;

  /// 数字 9 的 keycode。
  static const int digit9 = 16;

  /// F1..F12 的 keycode 起点（F1=131 … F12=142）。
  static const int f1 = 131;

  /// F12 的 keycode。
  static const int f12 = 142;
}
