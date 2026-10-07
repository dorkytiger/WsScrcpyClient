# 原生视频层（macOS / iOS 先行）——实现方案

> 分支 `4-native-video-surface`。目标：**让视频不进 Flutter 的合成管线**，直接送进原生显示层。
> 收益量级 10–25 ms（省掉一次引擎合成 + 一帧排队），顺带把"本地放大"那一步也交给系统做。
> 本文只覆盖 **darwin（macOS + iOS）**，其它平台等这两端跑通再照抄思路。

## 1. 现在是什么样（代码事实）

- Dart 侧：`player_page.dart:_VideoStage` 在拿到 `viewModel.textureId` 后渲染 `Texture(textureId: …)`
  （`player_page.dart:424`），没有纹理就显示占位/错误重试。
- 解码：`darwin/ScrcpyVideoDecoder.swift` 用 `VTDecompressionSession` 解出 `CVPixelBuffer`，
  再**拷贝/转换**进 `FlutterTexture` 注册的纹理，最后由 Flutter 引擎合成上屏。
- 于是这条链上多了一跳：`解码器 → (拷贝) → 纹理 → 引擎合成 → 提交`。

## 2. 目标链路

```
VTDecompressionSession → CVPixelBuffer
        └─ 包成 CMSampleBuffer（带 DisplayImmediately）
              └─ AVSampleBufferDisplayLayer.enqueue()   ← 系统自己显示，不进 Flutter 合成
```

**为什么选 `AVSampleBufferDisplayLayer`**：macOS 与 iOS **都有**这个类（`AVFoundation`），
所以 `darwin/` 那份共享 Swift 可以两端共用 —— 与现有"两端共用一份解码器"的结构一致，
一处改动两端受益。它接受**已解码**的 `CVPixelBuffer`（包成 `CMSampleBuffer`），
并且支持 `kCMSampleAttachmentKey_DisplayImmediately = true`（不等 vsync 排程，正是我们要的低延迟）。

> 备选：把**压缩帧**直接丢给 `AVSampleBufferDisplayLayer` 让它自己解（更省一步），
> 但那要求 **AVCC（长度前缀）+ format description**，而我们协议里是**裸 Annex-B**
> （见 `docs/ws-scrcpy-protocol.md`）——要额外写 Annex-B→AVCC 转换，属于"改协议适配"，
> 先不做。保留现有的 VideoToolbox 解码路径最稳。

## 3. 改动清单（darwin）

### 3.1 Swift（`darwin/`，两端共用）

### ★ 平台事实（实测，别再踩）

| 事实 | 证据 / 影响 |
|---|---|
| iOS 用 `FlutterPlatformView` 包装，`func view()` **必须返回 `UIView`** | 返回具体子类会报 `does not conform to protocol 'FlutterPlatformView'`（协议见证不允许协变返回） |
| **macOS 是完全另一套 API**：`FlutterPlatformViews.h` 里 `FlutterPlatformViewFactory` 的 `createWithViewIdentifier:arguments:` **直接返回 `NSView`**，没有 `FlutterPlatformView` 这个类型 | 我一开始照 iOS 写，macOS 报 `cannot find type 'FlutterPlatformView' in scope`。Swift 侧注册入口是 registrar 的 `register(_:withId:)`（ObjC `registerViewFactory:` 被重命名） |
| 两端都注册同一个视图类型名 `ws_scrcpy/video_surface` | Dart 侧一个 `NativeVideoSurface` 两端通用 |

| 文件 | 改什么 |
|---|---|
| `ScrcpyVideoDecoder.swift` | 增加"**显示目标**"抽象：`TextureSink`（现有，保留为兜底）与 `LayerSink`（新，持有 `AVSampleBufferDisplayLayer`）。解码出 `CVPixelBuffer` 后：走 LayerSink 时**不做额外拷贝**，直接 `enqueue`；走 TextureSink 时保持原逻辑 |
| 新增 `ScrcpyVideoSurfaceView.swift` | iOS：`UIView` 子类，`override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }`；macOS：`NSView` 子类，`makeBackingLayer()` 返回 `AVSampleBufferDisplayLayer`，并 `wantsLayer = true` |
| 新增 `ScrcpyVideoPlatformViewFactory.swift` | 给 Flutter 注册平台视图工厂（`FlutterPlatformViewFactory`），把 view 的 id ↔ 那个 layer 建立映射，交给解码器 |

**enqueue 的关键代码形状**（两端共用）：

```swift
private func display(_ pixelBuffer: CVPixelBuffer) {
    guard let layer = displayLayer, layer.isReadyForMoreMediaData else { return }  // 跟不上就丢这一帧，别排队
    var format: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: .invalid,
                                    presentationTimeStamp: .invalid,   // 立即显示
                                    decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                             imageBuffer: pixelBuffer,
                                             formatDescription: format!,
                                             sampleTiming: &timing,
                                             sampleBufferOut: &sampleBuffer)
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true) {
        // ★ 低延迟的关键：不等排程，立刻显示
        CFArrayGetValueAtIndex(attachments, 0).assumingMemoryBound(to: CFDictionary.self) // …设置下面这个键
    }
    layer.enqueue(sampleBuffer!)
}
```
> `kCMSampleAttachmentKey_DisplayImmediately` 要用 `CMSetAttachment(...)` 写进 attachment 数组；
> 上面的片段只是形状示意，实际按 `CMSampleBufferGetSampleAttachmentsArray` + `CMSetAttachment` 写。

### 3.2 平台注册（两端各一处）

- iOS：`ios/Runner/AppDelegate.swift`（或现有插件注册处）注册 `FlutterPlatformViewFactory`；
- macOS：`macos/Runner/MainFlutterWindow.swift` —— 与现有"注册视频通道"同一个位置
  （见 AGENTS §15.8，那里已经注册过通道与纹理，加一行动作最小）。

### 3.3 Dart（平台无关那层，两端共用）

新增 `lib/feature/stream/presentation/view/video_surface.dart`：

```dart
/// 原生视频层：把解码结果直接交给平台视图显示（不进 Flutter 合成）。
/// 平台不支持 / 初始化失败 → 回退到现有的 Texture 路径（[fallbackBuilder]）。
class NativeVideoSurface extends StatefulWidget {
  const NativeVideoSurface({required this.viewType, this.fallbackBuilder, ...});
}
```

- `viewType`：`'ws_scrcpy/video_surface'`（两端同一个）；
- 视图创建成功 → 原生侧把该 view 的 layer 交给解码器（**不需要 Dart 传句柄**：
  原生内部用 view id 关联即可，Dart 只在"视图建好/销毁"时通知一次）；
- `player_page.dart:_VideoStage` 改成：
  `if (nativeSurfaceAvailable) NativeVideoSurface(...) else Texture(textureId: …)`；
- **坐标换算一行都不用改**：`VideoViewport` 仍按"画面区矩形"算（它只关心几何，不关心怎么画）。

### 3.4 显示模式的边界（先做 contain，cover 下一轮）

- 现有 `VideoFitMode`（contain / cover）现在由 `FittedBox` 实现；
  换成原生层后，**裁切要由原生层做**（layer 的 `videoGravity` / 视口裁剪）。
- 建议 P0 **只支持 contain**（`videoGravity = .resizeAspect`，与现在行为一致），
  cover 先用"回退到 Texture 路径"顶着（开关是现成的），等 P1 再把 cover 做进原生层。

## 4. 风险与对策

| 风险 | 对策 |
|---|---|
| **平台视图的层级/裁剪**（横屏灵动岛避让、顶栏浮层压在上面） | 复用现有 `MediaQuery.paddingOf` 的避让矩形，把它同时喂给原生层；顶栏是 Flutter 浮层 —— 平台视图在 Flutter 视图**之上**还是之下需要实测（Android SurfaceView 的老问题同源） |
| `enqueue` 跟不上会积压 | 代码里已按 `isReadyForMoreMediaData` **丢帧不排队**（与现有"队列上限 4"的策略一致） |
| 无头测试测不了"真上屏" | 遵守 AGENTS 纪律：**上屏必须真机截图确认**（macOS 本机 `screencapture`；iOS 模拟器 `xcrun simctl io booted screenshot`）。widget 测试只断言"平台视图存在 / 回退到 Texture / 几何正确" |
| 与现有 Texture 路径共存 | 新路径做成**开关 + 能力探测**，任何异常自动回落；现有 272 个测试必须全绿 |
| 截图/录屏功能 | 我们没有"应用内截图"功能 ✓，不受影响 |

## 5. 验收（按顺序）

1. **单元/widget**：`NativeVideoSurface` 在"平台不支持"时回退到 Texture；几何断言（避让矩形一致）。
2. **本机 macOS**：`flutter run -d macos` + 自动投流 → **自己 `screencapture` 确认画面上屏**，
   并对比"新层 vs 旧纹理"两条路径的观感；日志里打一条"当前显示路径 = layer/texture"。
3. **iOS 模拟器**：`flutter run -d <sim>` + `xcrun simctl io booted screenshot` 确认上屏。
4. **测量**（与低延迟讨论共用）：设备上跑毫秒表 → 高帧率拍屏算 input-to-photon，
   记录"纹理路径 vs 原生层路径"的差值（预期 10–25 ms）。

## 5.1 ★ macOS 实测记录（2026-10-07）：接上了但**不显示**

日志（`ScrcpyVideo` 前缀）：

```
原生视频层视图已创建（macOS）：id=0
原生视频层已接入：解码结果将直接送 layer（纹理路径让位）
原生层首帧：layer bounds=(736.0, 400.0) status=1 ready=true     ← status=1 即 rendering
```

| 已排除 | 结论 |
|---|---|
| 布局/尺寸 | `bounds=736x400` 正常 ✓ |
| layer 状态 | `status=rendering` ✓、`isReadyForMoreMediaData=true` ✓ |
| 视图注册与工厂 | 创建成功 ✓ |

**⇒ 问题在 CMSampleBuffer/attachment 这一侧**，最可疑的是
`CMSampleBufferGetSampleAttachmentsArray` + `unsafeBitCast` 那段：如果
`kCMSampleAttachmentKey_DisplayImmediately` 实际没写进 attachment 字典，
而我们的 PTS 又是 `.invalid`，layer 就会**永远不显示**（黑）。

**还有一个设计教训（已改）**：我一开始用"成功 enqueue ≥3 帧 + status==rendering"当作
"原生层在工作"的判据 → 它一成立就把纹理路径切断 → **黑屏且无兜底** ✗。
"enqueue 成功"≠"看得见"；在没有可靠判据之前，**原生层必须显式开启**
（`NativeVideoSurface.debugForceEnabled = true`），默认走纹理路径。

待查项（下次继续）：① 用 `CMSetAttachment` 前先 `CFArrayGetValueAtIndex` 的返回是否真的是
NSMutableDictionary；② 试 `CMSampleBufferSetInvalidateCallback`? 不用；③ 试**不等 vsync**
的 `layer.flush()` 组合；④ 最后手段：改用 `AVSampleBufferDisplayLayer` 的
`enqueue` + 明确 PTS（用帧序号造一个递增时间）看是否显示。

## 6. 分阶段

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | darwin：`AVSampleBufferDisplayLayer` 共享实现 + 两端平台视图 + Dart 开关（contain only） | **待做（下一步）** |
| P1 | cover 模式进原生层；把"生效编码边界/放大倍率"的诊断接到新链路 | 待做 |
| P2 | Android `SurfaceView`（解码器已往 Surface 画，改动最小）；Windows `SwapChainPanel` | 待做 |
