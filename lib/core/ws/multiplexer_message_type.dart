/// ws-scrcpy 复用层（multiplexer）的消息类型。
///
/// 取值来自服务端实际下发的网页 bundle（`MessageType`），**不可自行改动**：
/// 客户端必须适配服务端协议。
enum MessageType {
  /// 未知类型：仅用于解析兜底，出现时按协议异常处理，禁止当正常值继续跑业务。
  unknown(0),

  /// 打开一条逻辑通道，payload 为通道初始化数据（通道名/通道码）。
  createChannel(4),

  /// 关闭通道，payload 为 CloseEvent 结构。
  closeChannel(8),

  /// 通道内原始二进制数据。
  rawBinaryData(16),

  /// 通道内原始 utf8 文本数据。
  rawStringData(32),

  /// 通道内数据（复用层自定义 Data 帧）。
  data(64);

  const MessageType(this.code);

  /// 帧头里承载的 uint8 取值。
  final int code;

  /// 服务端取值 → 枚举的唯一解析入口；未知取值返回 [MessageType.unknown]。
  static MessageType fromCode(int code) {
    for (final value in MessageType.values) {
      if (value.code == code) {
        return value;
      }
    }
    return MessageType.unknown;
  }
}
