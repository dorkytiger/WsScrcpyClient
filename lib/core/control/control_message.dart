import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/control/control_message_type.dart';
import 'package:ws_scrcpy_client/core/exception/global_exception.dart';

/// 位置（触摸点 + 屏幕尺寸）值对象，对应 bundle 里的 `Position`
/// （`.probe/bundle.js` webpack 模块 4455，`{point, screenSize}`）。
///
/// 触摸与滚动两类消息都要携带它，所以放在基类所在文件，避免两个消息文件互相 import。
///
/// 之所以建成值对象而不是散落 4 个 int 参数：坐标与屏幕尺寸必须**成对**出现才有意义
/// （服务端要用屏幕尺寸把像素坐标换算成比例），拆开极易漏传。
class TouchPosition {
  const TouchPosition({
    required this.x,
    required this.y,
    required this.screenSize,
  });

  /// 视频坐标系下的横向像素（**不是** Flutter 逻辑像素，需由渲染层换算后传入）。
  final int x;

  /// 视频坐标系下的纵向像素。
  final int y;

  /// 该坐标所属的屏幕（视频）尺寸。
  final ScreenSize screenSize;

  @override
  String toString() => 'TouchPosition(x: $x, y: $y, screenSize: $screenSize)';
}

/// 屏幕（视频）像素尺寸值对象，对应 bundle 里的 `ScreenSize`。
///
/// 宽度/高度在线上是 uint16，因此上限固定为 65535；建类是为了把"上限校验"和
/// "两个字段必须同时合法"这两件事收在一处，避免每个编码函数各写一遍判断。
class ScreenSize {
  const ScreenSize({required this.width, required this.height});

  /// 字段字节宽度决定的取值上限（uint16）。
  static const int maxValue = 0xFFFF;

  final int width;

  final int height;

  /// 两个方向都是 1..65535 才算合法：0 尺寸无法用于坐标换算，也过不了 uint16 语义。
  bool get isValid =>
      width > 0 && width <= maxValue && height > 0 && height <= maxValue;

  @override
  String toString() => 'ScreenSize($width x $height)';
}

/// 控制消息抽象基类。
///
/// 对应 bundle 里的 `ControlMessage` 基类：只持有 `type`，把
/// `toBuffer()` 交给子类逐字节实现。
///
/// 本层是**纯编码层**（不依赖 Flutter、不持有 socket）：入参不合法直接抛
/// [ValidationException]，由调用方的边界层捕获并翻译成 `Result`，
/// 避免"编码出半截错误字节却当成成功发出"。
abstract class ControlMessage {
  const ControlMessage(this.type);

  /// `type` 字段本身的字节宽度，所有消息的子类都必须从偏移 0 开始写它。
  static const int typeFieldLength = 1;

  /// 单字节无符号整数字段宽度（action / paste 标志 / 电源模式等）。
  static const int uint8FieldLength = 1;

  /// 双字节无符号整数字段宽度（屏幕宽高、压力值）。
  static const int uint16FieldLength = 2;

  /// 四字节字段宽度（int32 / uint32）。
  static const int uint32FieldLength = 4;

  /// 线上取值上限（uint16）。
  static const int maxUint16Value = 0xFFFF;

  /// 线上取值上限（uint32）。
  static const int maxUint32Value = 0xFFFFFFFF;

  /// 线上取值上限（int32，Java 侧是有符号 int，Android keycode/metaState 均为正数）。
  static const int maxInt32Value = 0x7FFFFFFF;

  /// 有符号 int32 的最小值（滚动量等字段允许负值）。
  static const int minInt32Value = -0x80000000;

  /// 该消息在线上字节流里的类型。
  final ControlMessageType type;

  /// 编码为待发送的字节（含 `type` 字段）。
  Uint8List toBuffer();

  /// 校验一个整数字段是否落在线上可表达的范围内。
  ///
  /// 放在基类是因为所有子类都需要同一套边界判断（含"负数不能写进无符号字段"），
  /// 集中一处可避免各子类把上限写成不同的魔法数字。
  static void validateIntField({
    required String fieldName,
    required int value,
    required int maxValue,
    int minValue = 0,
  }) {
    if (value < minValue || value > maxValue) {
      throw ValidationException(
        message: '$fieldName 超出范围：$value（允许 $minValue..$maxValue）',
      );
    }
  }

  @override
  String toString() => '$runtimeType(type: ${type.code})';
}
