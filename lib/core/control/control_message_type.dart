/// scrcpy 控制消息的类型常量。
///
/// 取值**实测自真实服务端网页 bundle** `.probe/bundle.js` 中的
/// `src/app/controlMessage/ControlMessage.ts`（webpack 模块 831，源码可读）：
///
/// ```js
/// e.TYPE_KEYCODE=0, e.TYPE_TEXT=1, e.TYPE_TOUCH=2, e.TYPE_SCROLL=3,
/// e.TYPE_BACK_OR_SCREEN_ON=4, e.TYPE_EXPAND_NOTIFICATION_PANEL=5,
/// e.TYPE_EXPAND_SETTINGS_PANEL=6, e.TYPE_COLLAPSE_PANELS=7,
/// e.TYPE_GET_CLIPBOARD=8, e.TYPE_SET_CLIPBOARD=9,
/// e.TYPE_SET_SCREEN_POWER_MODE=10, e.TYPE_ROTATE_DEVICE=11,
/// e.TYPE_CHANGE_STREAM_PARAMETERS=101, e.TYPE_PUSH_FILE=102
/// ```
///
/// 客户端必须适配服务端，因此这里的数值**不可改动**；改动即协议不兼容。
enum ControlMessageType {
  /// 按键注入（`TYPE_KEYCODE`），对应 `KeyCodeControlMessage`。
  keycode(0),

  /// 文本注入（`TYPE_TEXT`），对应 `TextControlMessage`。
  text(1),

  /// 触摸/鼠标注入（`TYPE_TOUCH`），对应 `TouchControlMessage`。
  touch(2),

  /// 滚轮注入（`TYPE_SCROLL`），对应 `ScrollControlMessage`。
  scroll(3),

  /// 返回键或亮屏（`TYPE_BACK_OR_SCREEN_ON`），**无负载**。
  backOrScreenOn(4),

  /// 展开通知面板（`TYPE_EXPAND_NOTIFICATION_PANEL`），**无负载**。
  expandNotificationPanel(5),

  /// 展开快捷设置面板（`TYPE_EXPAND_SETTINGS_PANEL`），**无负载**。
  expandSettingsPanel(6),

  /// 收起所有面板（`TYPE_COLLAPSE_PANELS`），**无负载**。
  collapsePanels(7),

  /// 索取设备剪贴板（`TYPE_GET_CLIPBOARD`），**无负载**。
  getClipboard(8),

  /// 写入设备剪贴板（`TYPE_SET_CLIPBOARD`），负载为 paste 标志 + 文本。
  setClipboard(9),

  /// 开关屏幕（`TYPE_SET_SCREEN_POWER_MODE`），负载为 1 字节模式。
  setScreenPowerMode(10),

  /// 旋转设备（`TYPE_ROTATE_DEVICE`），**无负载**。
  rotateDevice(11),

  /// 动态修改视频参数（`TYPE_CHANGE_STREAM_PARAMETERS`），负载为视频参数结构。
  changeStreamParameters(101),

  /// 推送文件（`TYPE_PUSH_FILE`），本层暂不实现编码（非目标，属二期）。
  pushFile(102);

  const ControlMessageType(this.code);

  /// 线上字节流里的 `type` 字段取值。
  final int code;

  /// 线上取值 → 枚举的唯一解析入口。
  ///
  /// 未知取值返回 `null`（**不提供 `unknown` 兜底值**）：调用方必须显式处理，
  /// 例如记 warning 日志后丢弃该消息，禁止静默当成正常类型继续跑。
  static ControlMessageType? fromCode(int code) {
    for (final value in ControlMessageType.values) {
      if (value.code == code) {
        return value;
      }
    }
    return null;
  }
}
