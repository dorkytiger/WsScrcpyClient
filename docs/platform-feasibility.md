# macOS / iOS 原生投流解码 + 操控 —— 可行性评估

> 评估对象：把 M2 路线 A（Android `MediaCodec` → Flutter `Texture`）**照抄到 Apple 两端**，
> 用 VideoToolbox 硬解 ws-scrcpy 下发的裸 H.264，并复用已有的纯 Dart 输入层完成操控。
>
> 事实来源：① 本项目已完成并实测的 Android 实现
> （`android/app/src/main/kotlin/com/example/ws_scrcpy_client/ScrcpyVideoDecoder.kt`、
> `lib/feature/stream/data/remote/native_video_decoder.dart`）；
> ② `docs/ws-scrcpy-protocol.md` 的协议实测结论；
> ③ Apple 官方文档与 Flutter embedder 头文件（链接见 §7）。
>
> 撰写时间：2026-10；作者未持有 Apple 开发者账号，**本文所有 Apple 侧结论都没有真机验证**，
> 每条都标了可信度，核验清单见 §6。
>
> 标注约定：`✅实测` = 本项目已在本仓库验证过；`🔶文档/推断` = 来自官方文档或结构推断；
> `⚠️需实测` = 必须上真机才能确认，禁止当成已知条件写代码。

---

## ⚠️ 实施结果回填（2026-10-02）：**iOS 与 macOS 都已实现**，请看 AGENTS.md §15

**两端共用同一份代码**：三个 Swift 文件放在仓库根的 `darwin/`（Flutter 生态里 iOS+macOS 共享源码的
惯例目录名），两个 Xcode 工程都用 `path = ../darwin` 的分组引用它们——**改一处两端同时生效**。
两端都实跑并截图确认了画面上屏；macOS 侧只写了"注册"那一层（AGENTS §15.8）。

本文是**实施前**的评估，下面的推断有几条被实践修正了。**实现细节与踩坑记录以
`AGENTS.md` §15 / §15.8 为准**，这里只留"本文哪几条被推翻/证实"的索引：

| 本文的说法 | 实际结果 |
|---|---|
| §3.1.1 `nalUnitHeaderLength: 4`、必须先做 Annex-B→AVCC | ✅ 正确，就是这条路 |
| §3.1.2 起始码切分"建议先判 4 字节再判 3 字节，别照抄上面那段顺序" | ✅ 正确且关键；离线探针里有专门断言 |
| §3.1.3 喂 `CMSampleBuffer` 的示例代码 | ⚠️ **不完整**：`CMBlockBufferCreateWithMemoryBlock(memoryBlock: nil)` 之后必须先 `CMBlockBufferAssureBlockMemory` 再 `ReplaceDataBytes`，否则静默失败、一帧都出不来 |
| §3.1.4 建议把 `kVTDecompressionPropertyKey_MaximizePowerEfficiency` 设成 false | ❌ **不要照做**：`VTDecompressionProperties.h` 写明"与 `RealTime` 同设是未定义行为"，而它默认就是 false——不设才对 |
| §3.1.5 输出像素格式选 `kCVPixelFormatType_32BGRA` | ✅ 正确，`FlutterTexture.h` 明写支持 32BGRA / 420v / 420f |
| §3.2.1 从 `FlutterImplicitEngineBridge.pluginRegistry` 拿 `textures` | ⚠️ **要改**：`pluginRegistry` 给的是 registrar，而 `applicationRegistrar.textures()` 在隐式引擎 + Scene 下**注册返回 0**（relay 的 parent 是 weak）；必须退到 `FlutterViewController`（它自己实现了 `FlutterTextureRegistry`） |
| §3.2.2 `copyPixelBuffer` 返回 `Unmanaged<CVPixelBuffer>?` + `passRetained` | ✅ 正确（已用 `xcrun swiftc -typecheck` 对着 `FlutterTexture` 验证过签名） |
| §3.2.3 平台通道的整数类型（`textureId` 必须是 Dart 的 `int`） | ✅ 传 `Int64` 正常，Dart 侧拿到 `int` |
| §1 "iOS 只在模拟器可行、真机没验证" 的保留 | 模拟器上**确实能跑**（走软件解码）；真机仍未验证 |
| §3.1.4 "RealTime 建议设为 true" | ✅ 设了；且离线 A/B 证明 Apple 侧**默认就是实时**（true/false/不设三种都是 90/90 帧），没有 Windows 那种缓冲问题 |

另外两条**本文完全没预见到**的：

1. **`kVTDecompressionPropertyKey_...` 命名的 Swift 导入坑**：`VideoToolbox.apinotes` 把
   `VTDecompressionSessionDecodeFrameWithOutputHandler` 重命名成
   `VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:infoFlagsOut:outputHandler:)`，
   照 C 头文件写会报 `Extraneous argument labels`。
2. **编码边界（bounds）的宽高比必须跟设备一致**：本文只讨论了"别超过原生分辨率"，
   没提比例。iOS 上（竖屏视口 + 横屏设备）因此出过一次"画面能出但很糊"——
   详见 `AGENTS.md` §15.7。这条改的是**共享 Dart 逻辑，Windows 也受益**。
3. **macOS 侧的注册路径与 iOS 不同**（§3.4 只写了"入口不同"）：macOS 的
   `FlutterPluginRegistrar` 上 `messenger` / `textures` 是**属性**，iOS 的
   `applicationRegistrar` 上是**方法**；模块名也从 `Flutter` 变成 `FlutterMacOS`。
   实际做法（含 `darwin/` 共享目录与构造函数注入兜底注册表）见 `AGENTS.md` §15.8。


---

## 1. 核心结论（先看这段）

> 逐平台的完整对照表在文末 §8。

| 结论 | 判定 |
|---|---|
| macOS 能不能做原生解码投流？ | **能，而且比 iOS 简单得多。** 无审核、无签名门槛；VideoToolbox + `FlutterTextureRegistry` 是 Flutter 桌面插件的成熟套路。**唯一的硬阻碍是当前 macOS 沙箱 entitlements 缺 `com.apple.security.network.client`**（见 §4.1），现在这个配置下 Release 版连不出网。 |
| iOS 能不能做？ | **技术路径完全成立**，与 macOS 共用同一份 Swift 代码。但工程与分发成本高：需要改 `project.pbxproj` 加 Swift 文件、需要真机 + 签名、还要过 App Store 远程控制类审核。 |
| 输入层还要不要做？ | **不需要。** 触摸/多指/滚轮/键盘已在 `lib/feature/stream/application/input/` 实现，纯 Dart、纯 `Listener`/`Focus`/`HardwareKeyboard`，跟平台无关（`AGENTS.md` §10）。两端只差"解码 + 渲染"。 |
| 唯一的 Dart 侧改动？ | **一行门禁**：`isNativeDecodingSupported` 现在覆盖 `TargetPlatform.android \|\| windows`（Windows 原生解码已落地），做 Apple 两端时再加上 `macOS` / `iOS`。通道契约本身不用动。 |
| 两端工作量 | macOS **约 6~9 人天**；iOS 在此基础上 **+4~6 人天**（工程/签名/ATS/审核）；两端新增 Swift **约 500~650 行**、Dart **约 20~40 行**。见 §6。 |
| 建议顺序 | **先 macOS**（验证 Annex-B→AVCC、像素格式、纹理线程模型）→ 再 iOS（复用同一份 Swift，只做工程与合规）。 |
| 风险最高的一环 | **`copyPixelBuffer` 的并发与零拷贝语义**（帧撕裂/内存暴涨），其次是**投流中分辨率变化时重建 `VTDecompressionSession`**。两者都不可靠静态推理，必须实测。 |
| 与 `webview_all` 的关系 | WebView 路线两端都已经能用（README 已列 ✅）。原生解码是**延迟/交互质量的升级**，不是"能不能用"的前提；建议保留双入口。 |

---

## 2. 两端共用的地基（先说清哪些不用动）

### 2.1 协议与数据面：完全复用

`docs/ws-scrcpy-protocol.md` §4.4 实测：`sendFrameMeta=false` 时**一条 WS 消息 = 一帧裸 H.264 Annex-B**，
起始码 `00 00 00 01`，SPS+PPS 作为单独一条消息先到，随后 IDR、P 帧。这条事实对三端一致，
所以 `StreamSessionService.videoFrames`（`lib/feature/stream/application/service/stream_session_service.dart`）
产出的 `Uint8List` 直接喂给新的 Swift 解码器即可，中间不需要任何重封装。

### 2.2 通道契约：照抄，一个字都不改

现契约（Android 已实现，Dart 侧 `native_video_decoder.dart`；Kotlin 侧 `MainActivity.kt`）：

| 方向 | 名称 | 参数 | 返回 |
|---|---|---|---|
| Dart → 原生 | `create` | 无 | `{"textureId": int}` |
| Dart → 原生 | `pushFrame` | `Uint8List`（一帧 Annex-B） | `null` |
| Dart → 原生 | `release` | 无 | `null` |
| 原生 → Dart | `onSizeChanged` | `{"width": int, "height": int}` | — |

通道名 `ws_scrcpy/video`。macOS / iOS 直接实现同一份契约，Dart 侧**不需要新协议**。

### 2.3 Dart 侧需要改的两处（都很小）

1. **门禁**：`lib/feature/stream/presentation/viewmodel/player_viewmodel.dart`

   ```dart
   bool get isNativeDecodingSupported =>
       !kIsWeb &&
       (defaultTargetPlatform == TargetPlatform.android ||
           defaultTargetPlatform == TargetPlatform.windows);
   ```

   > 📌 现状（2026-10，Windows 原生解码落地后）：门禁已经是 `android || windows`。
   > 做 Apple 两端时在这里再加上 `macOS` / `iOS` 即可。
   > ⚠️ `player_page.dart` 用这个布尔决定"不支持的平台显示提示"，改完要同步检查 UI 文案
   > （现在写的是"原生解码目前已在 Android 与 Windows 上实现"）。

2. **错误文案**：`native_video_decoder.dart` 的文案与类名已经中性化
   （`NativeVideoDecoder`，"目前支持 Android / Windows"）——Windows 落地时顺手收敛掉了。
   Apple 两端**直接复用同一个 Dart 类**，不要复制平行类，否则多端契约会漂移。

### 2.4 输入层：确认无需改动

`AGENTS.md` §10 的实现是纯 Dart：

```
手势/键盘 ──► _VideoStage（Listener/Focus）
                │  坐标用 VideoViewport 换算成视频像素（黑边上的点直接忽略）
                ▼
        PlayerViewModel.sendTouch / sendScroll / handleKeyEvent
                ▼
        StreamSessionService.sendTouch / sendScroll / sendControlMessage
                ▼
        core/control 的 TouchControlMessage / ScrollControlMessage / KeyCodeControlMessage
```

- `Listener` / `onPointerSignal` / `Focus.onKeyEvent` / `HardwareKeyboard` 都是 Flutter 框架层，
  macOS（桌面窗口）与 iOS（触摸屏）走的是**同一套指针/键盘管线**；
- 坐标换算发生在 `VideoViewport`，输入是 Flutter 逻辑坐标、输出是视频像素坐标，
  **与设备像素密度、安全区域、旋转都无关**（因为换算基准是 `_VideoStage` 的布局尺寸）；
- 所以两端**不需要为本功能写一行输入代码**。

各端的实际情况（要点，不是工作项）：

| 端 | 实际情况 |
|---|---|
| iOS 触摸 | 直接来自 Flutter 的触摸事件，多指天然支持（`event.pointer` 当 `pointerId`）。**不要把原生 `UITouch` 接进来**——那会绕过 `VideoViewport`，反而要重做坐标系与安全区域。 |
| iOS 安全区域 | 刘海/灵动岛/Home Indicator 区域内的点击会被系统手势抢走（边缘返回、底部上滑）。`_VideoStage` 若铺满全屏，建议给左右边缘与底部留出 `SafeArea` 内边距，或干脆让系统手势优先。这是 UX 取舍，不是可靠性问题。 |
| iOS 旋转 | 投流页默认横屏。`Info.plist` 已声明支持竖屏 + 左右横屏（`UISupportedInterfaceOrientations`）；横竖屏切换时 `player_page.dart` 的 `LayoutBuilder` → `applyViewportSize` → 下发 `bounds` 那条链路已经是平台无关的（`AGENTS.md` §11 末段），无需改动。 |
| iPad 外接键盘 | 与桌面键盘同路径：`HardwareKeyboard` → `KeyboardMapping` → `KeyCodeControlMessage`。映射表是 **Android keycode**（`keyboard_mapping.dart`，字母 A=29…Z=54 等），iPad 键盘的 `LogicalKeyboardKey` 会被正确翻译。**未覆盖的键返回 null 直接忽略**——这条纪律在 iPad 上尤其重要：iPad 键盘上大量按键在这个映射表里没有对应 Android keycode，宁可忽略也不要猜。 |
| macOS 键鼠 | 已经是"触摸 → 鼠标"：`Listener` 把鼠标当单指触摸，`onPointerSignal` 把滚轮转 `ScrollControlMessage`（符号与服务端网页端一致）。物理键盘同理。 |

---

## 3. 平台实现：macOS 与 iOS

> 两端的解码与渲染代码**可以完全共用**（同一个 `ScrcpyVideoDecoder.swift`）。
> 差异只在"谁来注册 MethodChannel / 从哪拿 `FlutterTextureRegistry`"，见 §3.4。

### 3.1 解码：VideoToolbox

#### 3.1.1 SPS/PPS → `CMVideoFormatDescription`

✅ 依据协议实测，SPS(nal type 7) 与 PPS(8) 单独作为一条 WS 消息先到。用
[`CMVideoFormatDescriptionCreateFromH264ParameterSets`](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptioncreatefromh264parametersets(allocator:parametersetcount:parameterSetpointers:parametersetsizes:nalunitheaderlength:formatdescriptionout:))
构造：

```swift
// 从那条先到的消息里按起始码切出 SPS / PPS（去掉起始码本身）
let parameterSets: [[UInt8]] = splitAnnexB(spsPpsFrame).filter { $0[0] & 0x1F == 7 || $0[0] & 0x1F == 8 }
let pointers = parameterSets.map { UnsafePointer<UInt8>($0) }
var formatDescription: CMFormatDescription?
let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
    allocator: kCFAllocatorDefault,
    parameterSetCount: pointers.count,          // 正常是 2（SPS + PPS）
    parameterSetPointers: pointers,
    parameterSetSizes: parameterSets.map { $0.count },   // 不含起始码
    nalUnitHeaderLength: 4,                     // ★ 见下
    formatDescriptionOut: &formatDescription)
```

**关键点（⚠️需实测）**：`nalUnitHeaderLength` 必须是 **4**。
VideoToolbox 的 H.264 输入约定是 **AVCC（长度前缀）**，不是 Annex-B，
所以这个参数描述的是"我接下来喂给你的 NAL 前面有 4 字节大端长度"，
也就是告诉解码器：后续 sample buffer 里的 NAL 是长度前缀的，不是起始码的。

> 结论：**不能直接把 Annex-B 的 `CMSampleBuffer` 喂进去**。必须先做 Annex-B → AVCC 转换，见 §3.1.2。
> 这是与 Android 最大的差别：Android `MediaCodec` 原生吃 Annex-B（`ScrcpyVideoDecoder.kt` 直接把
> 带起始码的字节 `put` 进输入 buffer），VideoToolbox 不吃。

#### 3.1.2 Annex-B → AVCC（本任务最容易写错的一段）

一遍扫描，把每个 `00 00 00 01`（也要兼容 3 字节起始码 `00 00 01`）替换为"该 NAL 的长度（大端 4 字节）"：

```swift
/// 输入：一条 WS 消息（Annex-B，可能含多个 NAL）；输出：AVCC 字节流。
func annexBToAVCC(_ frame: [UInt8]) -> [UInt8] {
    var output: [UInt8] = []
    var starts: [(offset: Int, length: Int)] = []
    var i = 0
    while i + 3 < frame.count {
        if frame[i] == 0, frame[i+1] == 0, frame[i+2] == 1 {
            starts.append((i, 3)); i += 3
        } else if i + 4 < frame.count, frame[i] == 0, frame[i+1] == 0, frame[i+2] == 0, frame[i+3] == 1 {
            starts.append((i, 4)); i += 4
        } else {
            i += 1
        }
    }
    for (index, start) in starts.enumerated() {
        let nalStart = start.offset + start.length
        let nalEnd = index + 1 < starts.count ? starts[index + 1].offset : frame.count
        let length = UInt32(nalEnd - nalStart)
        output.append(contentsOf: [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF),
                                   UInt8(length >> 8 & 0xFF),  UInt8(length & 0xFF)])
        output.append(contentsOf: frame[nalStart..<nalEnd])
    }
    return output
}
```

坑（逐条）：

1. **`00 00 01` 与 `00 00 00 01` 都要认**。本项目实测样本全是 4 字节起始码（§4.4），
   但 SPS/PPS 混排或编码器切关键帧时出现 3 字节起始码是 H.264 标准允许的。上面的写法先判 3 字节再判 4 字节，
   实际上对 `00 00 00 01` 也能正确切（`i` 前进 1 后命中 3 字节分支），只是 `starts` 里会多记一次偏移——
   **写实现时建议先判 4 字节再判 3 字节**，别照抄上面这段顺序。⚠️需实测：拿
   `test/fixtures/stream_first_video_frames.txt` 跑一遍断言"切出的 NAL 数与类型序列"。
2. **不要动 emulation prevention byte（`00 00 03`）**。转换只处理起始码，`00 00 03 xx` 原样保留；
   解码器自己会去掉 `03`。
3. **一个 sample buffer 可以含多个 NAL**（Android 的 `isCodecConfigOnly` 就处理了这种情况）：
   转换后的 AVCC 流可以直接放进一个 `CMBlockBuffer`，不需要一个 NAL 一个 sample。
4. **不要跨消息合并**。协议是"一条消息一帧"，一帧一个 `CMSampleBuffer`。

#### 3.1.3 喂 `CMSampleBuffer`

```swift
// 1) 把 AVCC 字节拷进 CMBlockBuffer
var blockBuffer: CMBlockBuffer?
CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                   blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
                                   customBlockSource: nil, offsetToData: 0,
                                   dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer)
CMBlockBufferReplaceDataBytes(with: avcc, blockBuffer: blockBuffer!, offsetIntoDestination: 0,
                              dataLength: avcc.count)

// 2) 包成 CMSampleBuffer，带上当前 formatDescription
var sampleBuffer: CMSampleBuffer?
var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                          formatDescription: formatDescription, sampleCount: 1,
                          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                          sampleSizeEntryCount: 1, sampleSizeArray: &avcc.count,
                          sampleBufferOut: &sampleBuffer)

// 3) 送解码，输出走 outputHandler
VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer!, flags: [],
                                  frameOptions: nil, infoFlagsOut: nil) { status, flags, imageBuffer, pts, dur in
    guard status == noErr, let pixelBuffer = imageBuffer else { /* 记错误 */ return }
    // ★ 把 pixelBuffer 存为"最新一帧"并调 textureFrameAvailable
}
```

- **时间戳**：本项目没启用 `sendFrameMeta`，所以 WS 消息里**没有 PTS**（`docs/ws-scrcpy-protocol.md` §6.3 第 1 条）。
  解码器需要时间戳来排序/驱动。最简做法是按到达顺序自增，
  即 `pts = CMTime(value: frameIndex, timescale: 30)`（或按实际到达间隔）。
  ⚠️需实测：VideoToolbox 对单调递增但不反映真实帧间距的 PTS 是否会影响输出——
  预期只影响 frame reordering 的深度，不影响正确性，但必须实测确认。
- **`kVTDecodeFrame_...` 系列 flags**：默认 `[]` 即可。
  `kVTDecodeFrame_EnableTemporalProcessing`、`kVTDecodeFrame_EnableAsynchronousDecompression` 都属于调优项，
  不要一上来就开（开着会改变输出回调的顺序与时机，反而更难排查）。
- **错误的统一处理**：`outputHandler` 的 `status` 与 `VTDecompressionSessionDecodeFrame` 的返回值
  都要看。常见可诊断错误：
  - `kVTVideoDecoderBadDataErr`（`-12909`）：喂进去的字节不是解码器期待的东西
    （**绝大多数情况就是忘了做 AVCC 转换**，或 `nalUnitHeaderLength` 不是 4）；
  - `kVTFormatDescriptionChangeNotSupportedErr`（`-12916`）：中途换了 format description 而会话没重建（见 §3.1.4）；
  - `kVTVideoDecoderMalfunctionErr`（`-12911`）：解码器内部错误，一般只能整会话重建。
  建议把这三个常量映射成可读中文文案，通过 `onSizeChanged` 之外的方式（或日志）暴露给 Dart，
  方便在"黑屏"时一眼看出是帧格式问题还是会话问题。

#### 3.1.4 尺寸变化 / format description 变化

投流中分辨率会变（设备旋转、或客户端下发 `CHANGE_STREAM_PARAMETERS`，
见 `AGENTS.md` §11 "横竖屏 / 窗口尺寸变化会自动重新适配"）。Apple 侧要这样处理：

1. **重建 format description**：检测到新的 SPS/PPS（又一条"只含 7/8 号 NAL"的消息）时，
   用 §3.1.1 重新构造 `CMVideoFormatDescription`。
2. **重建解码会话**：不要在旧会话上直接喂新 format description 的 sample。
   `kVTFormatDescriptionChangeNotSupportedErr`（`-12916`）就是这条路的典型结果。
   `VTDecompressionSessionCanAcceptFormatDescription` 可以用来提前判断，
   但**最稳的写法是"参数集变了就整会话重建"**：
   `VTDecompressionSessionInvalidate` → `VTDecompressionSessionCreate`（带上新的 format description
   与新的 `destinationImageBufferAttributes`）。
3. **`kVTDecompressionPropertyKey_...` 的用途**：这些属性是"会话级调优/查询"，不是尺寸变化的主通道。
   与本任务相关的只有少数几个，且都是可选优化：
   - `kVTDecompressionPropertyKey_RealTime`：提示解码器这是实时流、可以牺牲画质换延迟。**建议设为 true**；
   - `kVTDecompressionPropertyKey_MaximizePowerEfficiency`（macOS/iOS 较新系统）：省电优先，
     实时投流**不建议**开；
   - `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`：只读，用来**验证**
     真的走了硬解（排障很有用）。
   ⚠️需实测：以上属性都要在 `VTDecompressionSessionCreate` 之后用
   `VTSessionSetProperty` 设置并检查返回 `noErr`，不同系统版本支持情况不同；不支持时要能静默跳过。
4. **尺寸变化后要同步两件事**（与 Android 完全对称，`ScrcpyVideoDecoder.applySize`）：
   更新"最新一帧"的分辨率，并**反向通知 Dart** `onSizeChanged {width, height}`，
   Dart 侧 `PlayerViewModel.videoSize` 变化 → `_VideoStage` 的 `AspectRatio` 跟着调。

#### 3.1.5 输出像素格式

`VTDecompressionSessionCreate` 的 `destinationImageBufferAttributes` 里指定：

```swift
let attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],   // 让缓冲可被 Metal 采样（利于零拷贝）
]
```

- 选 **`kCVPixelFormatType_32BGRA`** 的理由：VideoToolbox 会**在硬件里**直接输出 BGRA
  （内部做 YUV→RGB），而 Flutter 的纹理目前只吃少数几种格式
  （见 [flutter#147242](https://github.com/flutter/flutter/issues/147242)：`FlutterTextureRegistry`
  只接受某几种 `CVPixelBuffer` 格式，且长期没写进文档）。
  ⚠️需实测：**这一条是本平台最大的不确定性之一**。必须真机验证以下组合哪一组能被 `FlutterTexture` 采到：
  `32BGRA` / `420v` / `420f`。如果 BGRA 不被接受，退路是"解码出 NV12 再用 Metal/CoreImage 转 BGRA"，
  代价是多一次拷贝与一段 GPU 代码，工期要加。
- `kCVPixelBufferIOSurfacePropertiesKey` 给空字典是让 IOSurface 生效的常规写法，
  这样 Flutter 引擎侧可以把缓冲直接映射成 Metal 纹理（潜在零拷贝）。
- 尺寸变化时必须重建会话（§3.1.4），`destinationImageBufferAttributes` 里的宽高约束（如果有）也要跟着换。

### 3.2 渲染：`CVPixelBuffer` → `FlutterTexture`

#### 3.2.1 注册方式

Flutter 的纹理机制在两端是同一个协议：实现 [`FlutterTexture`](https://api.flutter-io.cn/ios-embedder/protocol_flutter_texture-p.html)
（核心方法 `copyPixelBuffer`），向 `FlutterTextureRegistry.registerTexture(_:)` 注册，拿到一个 `Int64` 纹理 id，
Dart 侧 `Texture(textureId: id)` 就能渲染。

| 端 | 拿 `FlutterTextureRegistry` 的方式 | 备注 |
|---|---|---|
| iOS（本项目是 app 而非插件） | `FlutterImplicitEngineBridge.pluginRegistry.textures`。本项目的 iOS 入口是 `ios/Runner/AppDelegate.swift` 里的 `didInitializeImplicitFlutterEngine(_:)`（`@main class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate`），那里已经拿到了 `pluginRegistry` | 🔶需实测：`FlutterPluginRegistry` 上的 `textures` 属性名与类型。现有代码只用了 `GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)`；建议**先真机跑一个最小 demo** 确认这行能编过 |
| iOS（备选） | `(window?.rootViewController as? FlutterViewController)?.textureRegistry` | UIKit 路径，语义等价 |
| macOS | `flutterViewController.registrar(forPlugin: "…").textures`（`FlutterPluginRegistrar`） | macOS 的 `FlutterViewController` 也是 `FlutterTextureRegistry`，且 `MainFlutterWindow.swift` 里已经有 `flutterViewController` |

> ⚠️ 注意本仓库的 iOS 是 **Scene 生命周期 + `FlutterImplicitEngineDelegate`**（`AppDelegate.swift` 只有 16 行，
> `Info.plist` 声明了 `UIApplicationSceneManifest` + `SceneDelegate`）。这与网上绝大多数
> "在 `application(_:didFinishLaunchingWithOptions:)` 里拿 `window.rootViewController`" 的示例**不一样**，
> 照抄示例大概率拿不到 engine。**必须按本项目现有的 `didInitializeImplicitFlutterEngine` 路径注册**。

注册时机：与 Android 的 `configureFlutterEngine` 对齐——**在引擎初始化时注册 MethodChannel 与解码器**，
而不是在页面创建时。重复 `create` 时先释放旧解码器（Android `MainActivity.kt:36` 就是这么做的）。

#### 3.2.2 `copyPixelBuffer` 的线程与零拷贝（最高风险项）

协议签名（Swift 侧给 `NSObject` 子类手动桥接）：

```swift
func copyPixelBuffer(forTexture texture: FlutterTexture) -> CVPixelBuffer?
```

必须明确的语义：

1. **谁在调它**：Flutter 引擎的**光栅化线程**（raster thread），不是主线程，也不是解码队列。
   这是 [flutter#160520](https://github.com/flutter/flutter/issues/160520) 在讨论的核心问题——
   `copyPixelBuffer` / `textureFrameAvailable` 的调用时机在文档里长期不够明确。
2. **必须持有锁**：解码回调写"最新一帧"，`copyPixelBuffer` 读它，两者在不同的线程。
   用一把 `os_unfair_lock` 或 `NSLock` 保护一个 `CVPixelBuffer?` 属性即可，
   **不要**在锁里做解码或拷贝。
3. **不要复用已被引擎拿走的缓冲**。`copyPixelBuffer` 返回后，引擎会**持有**那个 `CVPixelBuffer`
   用于本帧渲染；如果你同时把它回收进 `CVPixelBufferPool` 或被下一个解码回调覆盖，就会**帧撕裂**
   甚至访问已释放内存。工程上的正确做法（按复杂度递增）：
   - **最简、先能用**：每帧在解码回调里新建缓冲（或从 pool 取、然后**不再回收**），
     交给 `copyPixelBuffer` 后由 ARC 管理生命周期。代价是每帧一次分配，实测再决定要不要优化；
   - **推荐**：维护一个"已交给引擎的缓冲"集合，只有当引用计数回到 1
     （`CFGetRetainCount` 或自己的引用表）才允许 `CVPixelBufferPool` 复用；
   - **零拷贝的真相**：真正省掉拷贝靠的是 IOSurface（§3.1.5）+ Metal 直接采样，
     而不是"避免 `CVPixelBuffer` 对象复用"。不要为了零拷贝牺牲正确性。
4. **`textureFrameAvailable` 的调用频率**：每解出一帧调一次 `registry.textureFrameAvailable(id)` 通知引擎
   （iOS 实现是 `- (void)textureFrameAvailable:(int64_t)textureId;`）。
   不要在一次解码回调里调多次，也不要在没有新帧时调。
5. **失败要能返回 nil**：`FlutterTexture` 的 `copyPixelBuffer` 现在允许返回可空
   （见引擎提交 [Set FlutterTexture copyPixelBuffer return nullable](https://github.com/flutter-team-archive/engine/commit/4883131507286def8cbd6f1ab9f32b0766c70c8c)）。
   还没解出第一帧时返回 `nil`，不要返回一个空的/未初始化的缓冲（会闪黑或崩）。
6. **线程数量**：整个解码链路建议只有两条队列——
   `decodeQueue`（串行：转换 + 喂帧 + 处理参数集变化）与主队列（回 Dart 的 `onSizeChanged`）。
   `VTDecompressionSession` 自己会用自己的队列回调 `outputHandler`。
   这与 Android 的"独立 `HandlerThread` + 等待队列上限 60 帧、满了丢最旧"是同一个设计意图，
   建议**照抄 60 帧上限**，否则解码跟不上时内存会无界增长。

#### 3.2.3 纹理 id 回传 Dart 的路径

和 Android 完全一致，**不需要新路径**：

```
Swift: let textureId = registry.registerTexture(pixelBufferTexture)   // Int64
     → result(["textureId": textureId])   // 或 invokeMethod 参数 map
     → MethodChannel("ws_scrcpy/video").invokeMethod("create")
Dart: native_video_decoder.dart:37  final raw = await _channel.invokeMethod<Map<Object?, Object?>>('create')
      → raw?['textureId'] as int → PlayerViewModel._textureId → Texture(textureId: textureId)
```

⚠️需实测：**平台通道的整数类型**。Dart 侧断言的是 `textureId is! int`
（`native_video_decoder.dart:39`）。Swift 侧如果传的是 `NSNumber` / `Int64`，
在 64 位设备上应桥接为 `int`；**但如果传成了 `Double` 或字符串，这里会静默走到"没有返回纹理 id"分支**。
第一次真机联调时优先确认这一点（打日志比读代码快）。

### 3.3 输入

见 §2.4：**不需要额外工作**。这里只把两端的"实际情况"再点一次，避免实现者误以为要写原生输入：

- **iOS 触摸**：`Listener` 收到的是 Flutter 逻辑坐标，`VideoViewport` 负责干净地映射到视频像素，
  黑边上的点直接忽略（`AGENTS.md` §10）。多指因为用 `event.pointer` 当 `pointerId` 而天然支持。
  **不要**引入 `UITouch` / 原生手势识别——那会绕过这套坐标系，且要自己处理安全区域与旋转。
- **iOS 安全区域**：刘海/灵动岛/Home Indicator 附近的触摸可能被系统边缘手势（左滑返回、底部上滑）抢走。
  投流页默认横屏、`_VideoStage` 通常铺满，建议在两端边缘留 `SafeArea` 内边距，或接受"贴边操作让位给系统"。
  这不是正确性问题，是 UX 取舍。
- **iOS 旋转**：`Info.plist` 已支持竖屏 + 左右横屏；旋转后 `LayoutBuilder` → `applyViewportSize`
  → `bounds` 下发这条链路与平台无关（`AGENTS.md` §11）。
- **iPad 外接键盘**：走同一套 `HardwareKeyboard` → `KeyboardMapping` → Android keycode 映射。
  注意映射表**故意只覆盖一部分键**，未覆盖返回 null 直接忽略——iPad 键盘上会有大量键落在这个集合外，
  这是预期行为，不要为了"支持更多键"去猜 keycode。
- **macOS**：鼠标即单指触摸，滚轮即 `ScrollControlMessage`，物理键盘同上；无需额外工作。

### 3.4 两端差异一览

| 维度 | macOS | iOS |
|---|---|---|
| 解码/渲染代码 | 同一份 Swift | 同一份 Swift |
| 引擎/注册入口 | `MainFlutterWindow.awakeFromNib()`（已有 `FlutterViewController`） | `AppDelegate.didInitializeImplicitFlutterEngine`（Scene + 隐式引擎） |
| 加文件的成本 | 同样要改 `project.pbxproj`（或走 Xcode） | 同左 |
| 网络权限 | **沙箱 entitlements：`com.apple.security.network.client`（当前缺失，必须加）** | 无沙箱；但明文 `ws://` 要 ATS 例外 |
| 分发 | 公证（notarization）+ Developer ID；**不走 App Store 审核**（可选） | 必须签名 + 真机 provisioning；上架需 App Review |

---

## 4. 工程与分发限制（具体到文件与条目）

### 4.1 macOS：沙箱、entitlements、公证

**已核对的现状**（读的是本仓库文件）：

`macos/Runner/DebugProfile.entitlements`：
```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.network.server</key><true/>
```

`macos/Runner/Release.entitlements`：
```xml
<key>com.apple.security.app-sandbox</key><true/>
```

**结论：两处都缺 `com.apple.security.network.client`。**

- App Sandbox 下，**向外的**网络连接（TCP 客户端、`URLSession`、WebSocket）需要
  `com.apple.security.network.client`；`network.server` 只覆盖"接受入站连接"。
  参考 [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)。
- 也就是说：**投流用的 `wss://` / `ws://` 客户端连接在 Release 配置下现在是被沙箱挡住的**
  （Debug 配置也只有 `network.server`，同样挡）。这一条与"是否做原生解码"无关，
  它同时影响已有的原生协议层和 WebView 路线——**如果 macOS 上"投流"按钮一直连不上，
  先查这里**。
- 需要往两个 entitlements 文件都加：
  ```xml
  <key>com.apple.security.network.client</key><true/>
  ```
- 🔶推断：`flutter_secure_storage` 在 macOS 上走 Keychain，沙箱下同 team 的应用通常无需额外
  `keychain-access-groups`；但如果实测发现密码存不进/读不出，第一件事就是查这条。
- **公证（notarization）**：如果分发给团队外的人（不走 Mac App Store），
  macOS 10.15 起要求 Developer ID 签名 + Hardened Runtime + 公证，否则 Gatekeeper 拦截。
  流程：`codesign`（Developer ID Application 证书，**签完再打 dmg/pkg**）→ `xcrun notarytool submit --wait`
  → `xcrun stapler staple`。entitlements 不参与签名之外的额外校验，但**必须随签名一起生效**
  （否则公证过了，运行时依然连不出网）。
- 硬性前置：需要 **Apple Developer Program（99 USD/年）**。macOS 若只在开发机上 `flutter run`
  自测，可以暂时不改 entitlements 分布、用 Debug 直接跑（但仍然要加 `network.client`）。

### 4.2 iOS：工程、签名、合规

**a) 加 Swift 文件与 MethodChannel 注册**

- Flutter app（非 plugin）的 iOS 原生代码放 `ios/Runner/`，必须**登记进 `ios/Runner.xcodeproj/project.pbxproj`**
  （新增 `PBXFileReference` / `PBXBuildFile` / 加入 `PBXGroup` 与 `PBXSourcesBuildPhase`）。
  手改 pbxproj 易错，**推荐用 Xcode 拖文件**，或实现期就把它当"一次性工程步骤"记录在案。
- 注册位置：`ios/Runner/AppDelegate.swift` 的
  `func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge)`。
  **这是本项目的现实，不是教科书写法**（见 §3.2.1 的警示）。
- `MethodChannel` 名与 Dart 侧一致：`ws_scrcpy/video`。
- 建议把解码器与通道注册拆成两个文件（`ScrcpyVideoDecoder.swift` + `VideoChannelHandler.swift`），
  便于 macOS 侧共用前者。

**b) 签名与真机调试门槛**

| 场景 | 要求 |
|---|---|
| 模拟器跑通测试 | 无需账号，但**模拟器没有 VideoToolbox 硬解保证**，解码路径必须真机验证 |
| 免费 Apple ID（Personal Team） | 可装到自己的 iPhone/iPad，但证书 7 天过期、需重新部署；无法使用某些能力 |
| 付费开发者账号 | 正规真机调试 + TestFlight + 上架；99 USD/年 |
| 上架 | 需要 App Store Connect 记录、隐私清单（Privacy Manifest）、截图、审核 |

⚠️需实测：免费账号下本项目是否需要额外 capability——当前用到的能力（网络、安全存储）不需要特殊 entitlement，
预计可行，但"7 天重签"对日常开发体验影响很大。

**c) App Store 审核风险（远程控制类）**

Apple 的 App Review Guidelines **§4.2.7** 专门针对"远程桌面 / 远程控制"客户端
（[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)，
历史上 2020 年因 Xbox/xCloud 争议被引用过，参见
[The Verge 的报道](https://www.theverge.com/2020/9/23/21452029/apple-microsoft-xbox-console-streaming-xcloud-app-store-guidelines)）。
该类条款的实质要求通常包括：

1. **应用本身要独立可用**，不能只是"另一个软件的壳"；
2. **如果只是镜像特定软件/服务**（而不是"通用地把主机设备镜像出来"），容易被拒——
   本项目的定位恰好是"通用地把 Android 设备镜像/操控出来"，方向上更接近被允许的一类，
   但需要在 App 描述与审核备注里把这一点讲清楚（"连接到用户自有的 Android 设备 / 自建 ws-scrcpy 服务器"）；
3. **"仅局域网"曾被作为这类应用的现实约束**（例如 Moonlight 曾收窄为只允许同一 LAN 的 PC，
   见 [moonlight-ios 那次提交](https://git.anidev.ru/moonlight-stream/moonlight-ios/commit/dbab07838d29388ac9e547905e00836d54c6dd17?files=Limelight%2fNetwork%2fDiscoveryManager.m)）。
   本项目默认就走公网 `wss://android.dorkytiger.top/`，**这条是最需要提前查证/沟通的审核风险**，别等提交后才发现。

  → 对策（成本从低到高）：
  a. 审核备注里说明"面向用户自有的服务器/设备，凭据用户自填"，并附自建服务端说明；
  b. 提供一个"仅局域网"模式作为默认展示路径，公网入口作为高级选项；
  c. 若被拒，改为**企业内分发 / TestFlight / 自签**，不走 App Store（macOS 侧本来就是这条路）。

**d) 加密出口合规（`ITSAppUsesNonExemptEncryption`）**

- 需要在 `ios/Runner/Info.plist` 增加：
  ```xml
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  ```
  含义是"本应用不使用非豁免的加密"，从而免去每次上传构建时的出口合规问答。
  参考 [ITSAppUsesNonExemptEncryption](https://developer.apple.com/documentation/BundleResources/Information-Property-List/ITSAppUsesNonExemptEncryption)。
- 本项目的实际情况：客户端**只使用操作系统提供的 TLS**（`wss://` 由 `dart:io`/系统网络栈完成），
  没有自研加密算法，因此 qualify 为豁免是合理判断；
  且 `ws://` 直连是**未加密**的，本身不涉及出口问题。
  参考 [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/Security/complying-with-encryption-export-regulations)。
- ⚠️需查证：`false` 的判定最终以 Apple 的问卷答案为准，且**中国市场还有额外的商用密码合规要求**
  （本项目公网入口域名非国内，暂不涉及，但要登记为已知事项）。

**e) ATS（明文 `ws://` 直连）—— 一个容易漏的硬阻碍**

`ios/Runner/Info.plist` 目前**没有 `NSAppTransportSecurity`**。
iOS 的 ATS 同样管 `ws://`。项目的"投流"路线里，`StreamTarget.candidateUris` 的**内层候选是
明文 `ws://<设备IPv4>:8886/...`**（`docs/ws-scrcpy-protocol.md` §4.1）。因此：

- 走公网 `wss://` 代理：ATS 无碍；
- 走局域网明文 `ws://`：**会被 ATS 拦掉**，需要例外，例如：
  ```xml
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  ```
  `NSAllowsLocalNetworking` 只放开本地/私网地址，比 `NSAllowsArbitraryLoads` 安全得多，
  对"局域网直连设备"这个场景正合适。若实测仍有拦截，再退到按域白名单。
- ⚠️需实测：`ws://` 是否被 `NSAllowsLocalNetworking` 覆盖，
  以及 iOS 14+ 的**本地网络权限弹窗**（`NSLocalNetworkUsageDescription`）是否会被触发。
  后者主要用于 Bonjour/mDNS/组播发现与**入站**连接；本项目是"出站连到已知 IP"，
  🔶推断不会弹窗，但**必须实测**——如果弹窗不出现且连接被拒，就是这条。
  同一问题在 macOS 13+ 也存在（本地网络权限），同理需实测。

**f) 其他 iOS 工程事项**

- `Info.plist` 的 `UISupportedInterfaceOrientations` 已包含横屏；投流页默认横屏，无需改。
- `wakelock_plus` 常亮已有实现；iOS 上锁屏即断流是系统限制，需在 UI 文案里说明。
- 应用标识仍是 `com.example`（`AGENTS.md` §9 待做），上架前必须改。

### 4.3 与现有 `webview_all` 路线的关系

WebView 路线（README 已列 ✅）在两端**都已经能用**：`StreamTarget.webPlayerUri()` 生成深链 →
`WebviewShellPage` 加载 → 服务端网页播放器自己用 MSE/WebCodecs 解码，Basic Auth 走
`onHttpAuthRequest` 质询应答（**这条铁律别忘**，`AGENTS.md` §8）。

**什么时候 WebView 就够：**

- 只想"看一眼设备在干什么"、偶尔点两下；
- 不想引入任何原生代码与签名/审核复杂度（尤其 iOS 上架前的探索期）；
- 服务端网页播放器（MSE/TinyH264/WebCodecs）在目标 WebView 上表现可接受；
- 想省掉"跟 ws-scrcpy 协议版本漂移"的风险（网页播放器跟服务端同源、天然对齐）。

**什么时候必须原生解码：**

- **延迟**：WebView 路线多一层页面 + JS 解码调度，端到端延迟通常明显高于
  MediaCodec/VideoToolbox 直解（项目目标：内网端到端 <300ms，见 `README.md`）；做交互（游戏/拖动）时差别可感；
- **交互质量**：网页播放器自带的手势与 Flutter 的 `Listener` 会互相抢；原生路径下画面是普通 `Texture`，
  触摸/滚轮/键盘全由我们自己控制（这正是 M3 已做的那套）；
- **输入与 UI 一致性**：原生路径才能让快捷栏、日志面板、错误重试、`VideoViewport` 黑边处理
  与 Android 完全一致；
- **可靠性与可观测性**：网页黑屏时的排查要穿过 JS 控制台；原生路径的错误可以直接映射成中文文案 + 重试；
- **局域网直连 / 自建服务端**：不走服务端公网入口时（WebView 深链依赖网页播放器那套页面与代理），
  原生协议层是唯一可控路径。

**建议**：保留设备卡片上的**双入口**（"网页" / "投流"），原生解码作为"投流"入口在 macOS/iOS 上的实现，
WebView 作为降级与排障手段。这已经与 Android 现状一致，不需要架构调整。

---

## 5. 实施建议（组件与顺序）

### 5.1 建议的文件落点

| 端 | 新增/修改 | 说明 |
|---|---|---|
| 共用 | `macos/Runner/ScrcpyVideoDecoder.swift`（新） | VideoToolbox 会话 + Annex-B→AVCC + PTS + 尺寸/参数集变化重建。**纯逻辑、不依赖 Flutter**，两端共享 |
| 共用 | `macos/Runner/PixelBufferTexture.swift`（新） | `FlutterTexture` 实现：latest-frame 缓存 + 锁 + `copyPixelBuffer` |
| macOS | `macos/Runner/MainFlutterWindow.swift`（改） | 注册通道、建解码器、把 `textures` 与 `binaryMessenger` 传进去 |
| macOS | `macos/Runner/{DebugProfile,Release}.entitlements`（改） | 加 `com.apple.security.network.client` |
| iOS | `ios/Runner/VideoChannelHandler.swift`（新） | 与 macOS 相同的注册逻辑，入口换成 `didInitializeImplicitFlutterEngine` |
| iOS | `ios/Runner.xcodeproj/project.pbxproj`（改） | 登记新文件（**用 Xcode 做**） |
| iOS | `ios/Runner/Info.plist`（改） | `ITSAppUsesNonExemptEncryption=false`；按需加 `NSAppTransportSecurity.NSAllowsLocalNetworking` |
| Dart | `lib/feature/stream/data/remote/native_video_decoder.dart`（改，可选中性化） | 文案/类名 |
| Dart | `lib/feature/stream/presentation/viewmodel/player_viewmodel.dart:72`（改） | `isNativeDecodingSupported` 加 macOS/iOS |
| Dart | `lib/feature/stream/presentation/view/player_page.dart`（检查） | `:468` 的"不支持"提示文案要跟着改 |

> 纪律提醒（`AGENTS.md` §6）：本次不动协议。视频帧的解析仍只能依据
> `docs/ws-scrcpy-protocol.md` 的实测结论；如实现中发现需要新事实（例如实测到 3 字节起始码），
> **先补协议文档再改代码**。

### 5.2 推荐的实施顺序

| 阶段 | 内容 | 预估 |
|---|---|---|
| 0. 前置核对（**先做，可能省掉几天**） | macOS Debug 直接 `flutter run` 验证：现有 WebView 路线与"投流"入口在 macOS 上到底能不能连出网；给两个 entitlements 加 `network.client` 前后各试一次 | 0.5 人天 |
| 1. macOS：最小解码链路 | Swift 解码器（**先只做 `create` + `pushFrame` + 硬编码 SPS/PPS**）→ 用 `test/fixtures/stream_first_video_frames.txt` 离线喂帧 → 确认能解出 `CVPixelBuffer` | 2~3 人天 |
| 2. macOS：纹理与线程 | `FlutterTexture` 注册 + `copyPixelBuffer` + `textureFrameAvailable`；确认像素格式被接受（§3.1.5）；打帧序号验证不撕裂/不泄漏 | 2~3 人天 |
| 3. macOS：完整契约 | 接上 `create/pushFrame/release/onSizeChanged`；改 Dart 门禁与文案；跑通真实服务端 | 1~2 人天 |
| 4. macOS：参数集/尺寸变化 | 重建 format description 与解码会话；旋转设备验证 `onSizeChanged` → `AspectRatio` | 1 人天 |
| 5. iOS：工程接通 | 文件进 pbxproj；`didInitializeImplicitFlutterEngine` 注册；真机跑出画面 | 1~2 人天 |
| 6. iOS：合规与体验 | `ITSAppUsesNonExemptEncryption`、ATS/本地网络实测、安全区域留边、签名与真机调试流程走通 | 2~3 人天 |
| 7. 上架准备（可选，仅 iOS） | 审核备注/局域网模式、隐私清单、`com.example` 改标识、截图与描述 | 2~3 人天（**不确定性最大**） |
| 8. 收尾 | 两端回归：断线重连、长时间运行内存、多分辨率、错误文案与重试 | 1~2 人天 |

**合计**：macOS 约 **6~9 人天**；iOS 约 **+4~6 人天**（不含上架准备，含上架准备则 +6~9）；
代码量约 **Swift 500~650 行 + Dart 改动 20~40 行**。

### 5.3 风险最高的一环

按"可能让工期翻倍"排序：

1. **`copyPixelBuffer` 的并发与缓冲生命周期**（§3.2.2）。表现是随机的画面撕裂、花屏、
   或内存持续增长。它没有编译期保护，靠实测与压力测试才能发现，**必须在阶段 2 专门压测**
   （连续 10 分钟 720p30，看内存曲线与画面）。
2. **`CVPixelBuffer` 像素格式能否被 `FlutterTexture` 接受**（§3.1.5）。
   如果不接受 BGRA，就要加 NV12→BGRA 的 GPU 转换，工期 +2~3 人天且引入新依赖面。
3. **投流中参数集/分辨率变化时重建会话**（§3.1.4）。写错了不会立刻崩，
   而是在旋转屏幕后黑屏或报 `-12916`，排查成本高。
4. **iOS 的"隐式引擎"注册路径与预期不符**（§3.2.1）。本项目是 Scene + `FlutterImplicitEngineDelegate`，
   网上示例不适用；建议阶段 5 一开始就写一个只 `registerTexture` 的空壳验证。
5. **App Store 审核**（§4.2c）。技术上无解，只能靠前期沟通与降级方案（TestFlight/自签）。

---

## 6. 不确定性与核验清单

> 这一节是本文最该被复查的部分。**下面每条都还没有真机证据**，实现前先逐条核销。

| # | 待确认 | 怎么核 | 影响 |
|---|---|---|---|
| U1 | `CMVideoFormatDescriptionCreateFromH264ParameterSets` + `nalUnitHeaderLength: 4` 后，喂 AVCC 的 `CMSampleBuffer` 能否正常解出 | 真机最小 demo，喂 `test/fixtures/stream_first_video_frames.txt` 的前 3 帧 | 解码路线成立与否（§3.1） |
| U2 | `FlutterTextureRegistry` 接受哪些 `CVPixelBuffer` 格式（BGRA / 420v / 420f） | 真机逐格式试；参考 [flutter#147242](https://github.com/flutter/flutter/issues/147242) | 需要不需要 GPU 颜色转换（工期 +2~3 天） |
| U3 | `copyPixelBuffer` 返回后引擎对 `CVPixelBuffer` 的持有语义（是否必须 retain / 何时可回收） | 真机压测 + 引用计数日志；参考 [flutter#160520](https://github.com/flutter/flutter/issues/160520) | 帧撕裂 / 内存无界（最高风险） |
| U4 | iOS 侧 `didInitializeImplicitFlutterEngine` 里从 `pluginRegistry` 取 `.textures` 的确切写法 | 真机编译一个只 `registerTexture` 的空壳 | iOS 工程能否接通（§3.2.1） |
| U5 | 平台通道的 `textureId` 在 Dart 侧是否确实为 `int` | 真机打日志；Dart 侧断言在 `native_video_decoder.dart:39` | 会静默走"没有返回纹理 id"分支 |
| U6 | `ws://` 局域网直连在 iOS 上是否需要 ATS 例外、是否触发本地网络权限弹窗 | 真机 + 内网 ws-scrcpy；`NSAllowsLocalNetworking` 开关对比 | 局域网直连能不能用（§4.2e） |
| U7 | macOS 沙箱加 `network.client` 之前，现有投流/WebView 是否真的连不出网 | `flutter run -d macos` 前后对比 | 可能是一个已存在的隐藏阻塞（§4.1） |
| U8 | App Store §4.2.7 对"公网连接用户自有服务器"的实际态度；是否必须"仅局域网" | 查最新 Guidelines 全文 + 必要时向 Apple 提审核咨询 | iOS 上架可行性（不可技术规避） |
| U9 | `ITSAppUsesNonExemptEncryption=false` 在本项目（仅系统 TLS）是否成立 | 走 App Store Connect 的出口合规问卷 | 上架流程中的一次性问答 |
| U10 | `kVTDecompressionPropertyKey_RealTime` 等会话属性的系统版本支持情况 | 真机 `VTSessionSetProperty` 检查返回码 | 仅调优，不支持可跳过 |
| U11 | 无 PTS（`sendFrameMeta=false`）时自增时间戳会不会影响解码输出顺序 | 真机对比自增 PTS 与按到达时间 PTS | 可能出现帧序错乱 |
| U12 | macOS 13+ 本地网络权限对"出站连私网 IP"的影响 | 真机实测 | 局域网直连（同 U6） |
| U13 | `ScrcpyVideoDecoder` 的 drop-oldest（60 帧上限）在 Apple 侧的等价策略是否够用 | 真机压测解码滞后场景 | 内存增长 / 延迟堆积 |

**明确标注为"查不到、需自行查证"的方向**（本文不编）：Apple 侧没有公开的
"ws-scrcpy 类 H.264 直喂 VideoToolbox"的官方示例；`FlutterTexture` 的线程模型在官方文档里长期表述不清，
只能以引擎源码与 issue 为准（[flutter#147242](https://github.com/flutter/flutter/issues/147242)、
[flutter#159162](https://github.com/flutter/flutter/issues/159162)、
[flutter#160520](https://github.com/flutter/flutter/issues/160520)）。

---

## 7. 参考链接

**本项目**
- 协议实测记录：[docs/ws-scrcpy-protocol.md](ws-scrcpy-protocol.md)（§4.4 视频数据、§4.2 初始信息头、§4.3 参数下发）
- 工程规范与 M2/M3 实现说明：[AGENTS.md](../AGENTS.md)（§10 输入、§11 Android 硬解）
- Android 参考实现：[ScrcpyVideoDecoder.kt](../android/app/src/main/kotlin/com/example/ws_scrcpy_client/ScrcpyVideoDecoder.kt)、
  [MainActivity.kt](../android/app/src/main/kotlin/com/example/ws_scrcpy_client/MainActivity.kt)
- Dart 通道契约：[native_video_decoder.dart](../lib/feature/stream/data/remote/native_video_decoder.dart)
- 待接入点：[player_viewmodel.dart](../lib/feature/stream/presentation/viewmodel/player_viewmodel.dart)、
  [player_page.dart](../lib/feature/stream/presentation/view/player_page.dart)
- 离线帧夹具：`test/fixtures/stream_first_video_frames.txt`

**Apple 官方文档**
- [`CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:parameterSetCount:parameterSetPointers:parameterSetSizes:nalUnitHeaderLength:formatDescriptionOut:)`](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptioncreatefromh264parametersets(allocator:parametersetcount:parametersetpointers:parametersetsizes:nalunitheaderlength:formatdescriptionout:))
- [`VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:frameOptions:infoFlagsOut:outputHandler:)`](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessiondecodeframe(_:samplebuffer:flags:frameoptions:infoflagsout:outputhandler:))（同一符号的 ObjC 拼写：`VTDecompressionSessionDecodeFrameWithOptions`，见[带 `frameRefcon` 的重载](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessiondecodeframe(_:samplebuffer:flags:frameoptions:framerefcon:infoflagsout:))）
- [`CVPixelBufferPool`](https://developer.apple.com/documentation/corevideo/cvpixelbufferpool-77o)、
  [`kCVPixelBufferPoolMinimumBufferCountKey`](https://developer.apple.com/documentation/corevideo/kcvpixelbufferpoolminimumbuffercountkey)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)（`com.apple.security.network.client`）
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)（§4.2.7 远程桌面）
- [`ITSAppUsesNonExemptEncryption`](https://developer.apple.com/documentation/BundleResources/Information-Property-List/ITSAppUsesNonExemptEncryption)
- [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/Security/complying-with-encryption-export-regulations)

**Flutter embedder**
- [`FlutterTexture` 协议参考（iOS embedder）](https://api.flutter-io.cn/ios-embedder/protocol_flutter_texture-p.html)
- [`FlutterTextureRegistry`（macOS embedder 实现源码）](https://main-api.flutter-io.cn/macos-embedder/_flutter_texture_registrar_8mm_source.html)
- [Set FlutterTexture copyPixelBuffer return nullable（引擎提交）](https://github.com/flutter-team-archive/engine/commit/4883131507286def8cbd6f1ab9f32b0766c70c8c)
- [flutter#147242 — 纹理只接受少数几种 CVPixelBuffer 格式](https://github.com/flutter/flutter/issues/147242)
- [flutter#159162 — Better implementation of FlutterTexture](https://github.com/flutter/flutter/issues/159162)
- [flutter#160520 — copyPixelBuffer / textureFrameAvailable 调用时机不清](https://github.com/flutter/flutter/issues/160520)
- [camera 插件的线程安全纹理注册封装（实现时可参考）](https://flutter.googlesource.com/mirrors/plugins/+/c9c234a53e563a0312f96ca7a77a8d015bfaab5f/packages/camera/camera/ios/Classes/FLTThreadSafeTextureRegistry.m)

**审核先例**
- [Moonlight iOS 是否收窄为"仅 LAN"的提交（远程控制类审核约束的实例）](https://git.anidev.ru/moonlight-stream/moonlight-ios/commit/dbab07838d29388ac9e547905e00836d54c6dd17?files=Limelight%2fNetwork%2fDiscoveryManager.m)
- [The Verge：2020 年 App Store 远程串流条款之争](https://www.theverge.com/2020/9/23/21452029/apple-microsoft-xbox-console-streaming-xcloud-app-store-guidelines)

---

## 8. 结论速览（平台 × 维度）

| 平台 | 解码可行性 | 渲染方式 | 输入 | 主要阻碍 | 建议 |
|---|---|---|---|---|---|
| **macOS** | **可行**。VideoToolbox `VTDecompressionSession` 解 H.264；需自做 Annex-B→AVCC；分辨率/参数集变化要重建会话 | `FlutterTexture`（`CVPixelBuffer` → `copyPixelBuffer`）→ Dart `Texture(textureId)`，与 Android 同一契约 | **无需改动**（纯 Dart：鼠标=单指触摸、滚轮、物理键盘） | ① 沙箱缺 `com.apple.security.network.client`（**现在就连不出网**，与解码无关）② `copyPixelBuffer` 并发/零拷贝语义 ③ 分发需公证 | **首选落地端**：无审核、无签名门槛，最适合验证整条 Apple 侧链路（含像素格式与纹理线程）。先加 entitlement 再做解码 |
| **iOS** | **可行**，与 macOS 共用同一份 Swift 解码/纹理代码 | 同上；`FlutterTextureRegistry` 从 `FlutterImplicitEngineBridge.pluginRegistry` 取（本项目是 Scene + 隐式引擎，**不能照抄网上示例**） | **无需改动**（触摸/多指天然支持；安全区域留边与旋转是 UX 取舍；iPad 键盘走同一 keycode 映射） | ① 需改 `project.pbxproj` 加 Swift 文件 + 真机签名/Provisioning ② 明文 `ws://` 可能被 ATS 拦（局域网直连）+ 本地网络权限 ③ **App Store §4.2.7 远程控制类审核**（可能被要求"仅局域网"）④ `ITSAppUsesNonExemptEncryption` 出口合规 | 先真机把"`registerTexture` 空壳 + 解码出画面"跑通，再谈上架；上架风险不可技术规避，**准备 TestFlight/自签的降级方案** |
| **共用结论** | 两端**同一份 Swift**（约 500~650 行）；Dart 只需改平台门禁一行 + 文案 | 纹理 id 通过既有 `ws_scrcpy/video` 通道回传，Dart 侧零改动 | 输入层零改动 | 最高风险：`copyPixelBuffer` 并发与缓冲生命周期 > 像素格式接受度 > 会话重建 | 顺序：**macOS 阶段 0~4 → iOS 阶段 5~6 →（可选）上架阶段 7**；工期 macOS 6~9 人天、iOS +4~6 人天 |

**一句话**：**两端都能做，macOS 是"照抄 Android 契约 + 换 VideoToolbox"，iOS 是"同一份代码 + 过工程与审核两道关"**；
真要做，先花半天核销 §4.1 的 macOS entitlements 与 §6 的 U1~U3，再动手写 Swift。
