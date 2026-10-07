import 'dart:async';
import 'dart:typed_data';

import 'package:ws_scrcpy_client/core/result/result.dart';
import 'package:ws_scrcpy_client/core/stream/display_info.dart';
import 'package:ws_scrcpy_client/feature/stream/application/input/video_viewport.dart';

/// 视频解码器的**平台边界**：上层（`PlayerViewModel`）只认这个接口。
///
/// 为什么要有这层（2026-10-07，web 端阶段二）：
/// 原生三端（Android / Windows / iOS / macOS）都是"把整条 Annex-B 消息丢给系统硬解、
/// 尺寸靠回执 / 拉取回来"，而 **web 只能用 WebCodecs**，而且它需要上层不知道的东西
/// （codec 串、key/delta、canvas 平台视图）。抽成接口后，`PlayerViewModel` 的编排
/// （何时建解码器、喂帧、处理尺寸变化、失败重试）一行都不用改。
///
/// 平台分派见 `video_decoder_factory.dart`（条件导出）：
/// - 原生 → `NativeVideoDecoder`（`ws_scrcpy/video` 通道）；
/// - web → `WebCodecsVideoDecoder`（`VideoDecoder` + canvas 平台视图）。
abstract class VideoDecoder {
  /// 解码器给出的真实画面尺寸变化（投流中设备旋转 / 编码器重建时）。
  Stream<VideoSize> get sizeChanges;

  /// 最近一次拿到的尺寸；从没拿到过时为 null。
  VideoSize? get lastSize;

  /// 是否已经拿到可渲染的画面载体（原生是纹理，web 是 canvas 平台视图）。
  bool get hasTexture;

  /// 建解码器；原生返回纹理 id，web 返回一个占位 id（0）——渲染分支由视图层按平台选。
  Future<Result<int>> create();

  /// 喂一帧 Annex-B（调用方可以不等结果，帧率很高）。
  Future<Result<void>> pushFrame(Uint8List frame);

  /// 主动拉一次当前尺寸（原生才有意义；web 返回上次已知值）。
  Future<VideoSize?> getSize();

  /// 释放解码器与画面载体；**可重复调用**（断开、重试、页面销毁都会调）。
  Future<void> release();

  Future<void> dispose();

  /// 解码器的**异步错误**（默认空流：原生的错误都走 [Result]，从不走这条）。
  ///
  /// 为什么 web 需要单独一条：WebCodecs 的错误是**回调式**的，没有地方把它当返回值交出来。
  /// 一开始的实现是"先记住，下一次 [pushFrame] 带回"——但服务端只在画面变化时发帧，
  /// 解码一失败又可能再也等不到下一帧，结果就是**一块没有任何解释的黑屏**（用户实测）。
  /// 所以改成错误一发生就立刻通知上层（UI 显示可读错误 + 重试入口）。
  Stream<String> get asyncErrors => const Stream<String>.empty();

  /// 告诉解码器"画面该摆在控件的哪个位置"（默认空实现，只有 web 需要）。
  ///
  /// 为什么 web 需要：那边画面是 **DOM canvas 平台视图**，不参与 Flutter 的绘制，
  /// 所以 `FittedBox` 那套 contain/cover 缩放管不到它，只能由我们按同一套
  /// [VideoViewport] 数字去摆 CSS。**必须是同一套数字**——渲染和触摸换算一旦分家，
  /// 就会又回到"点哪都偏"（§9.2 B / §15.7 的教训）。
  void applyDisplayGeometry(VideoViewport? viewport) {}
}
