# ws-scrcpy 专用客户端 —— 开发文档(Flutter,多端)

> **本文件是给"开发机"看的**,服务器那边只提供 ws-scrcpy 服务。
> 目标:写一个 **Flutter App**,作为 ws-scrcpy 的显示/操作客户端,能跑在 **Android / iOS / Windows(桌面)**。
>
> 服务器信息(**不含密码,自行填**):
> - 公网入口:`https://android.dorkytiger.top/`(wss 走 443;开了 Basic Auth,**用户名/密码找服务器主人要**)
> - 内网(可选,调试用):`http://192.168.11.132:8000/`
> - 服务端:ws-scrcpy(Node,容器 `scrcpy-web`),设备端 `scrcpy-server.jar`

---

## 实现进度（2026-09-30 更新）

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M0 协议探测 | ✅ 完成 | 实测记录见 `docs/ws-scrcpy-protocol.md`（§2.5 清单已回填）；含**真实视频帧**：SPS+PPS → IDR → P 帧，一条 WS 消息一帧裸 Annex-B；复现：`dart run tools/probe.dart` |
| 协议层 | ✅ 完成 | 复用层、控制消息逐字节编码、初始信息头解析、投流会话与指数退避重连；`test/` 下 117 项测试通过 |
| M1 WebView 壳 | ✅ 完成 | 用 `webview_all` 覆盖 Android / iOS / macOS / Windows / Linux（官方 `webview_flutter` 桌面端不够用）|
| M2 原生解码 | ⏳ 未开始 | 前置能力全部就绪；接入点：`lib/feature/stream/presentation/view/player_page.dart` 的 `_VideoStage`，Annex-B 解析见 `lib/core/stream/annex_b_parser.dart` |
| M3 输入与 UX | ⏳ 部分 | 快捷栏（Home/Back/Recents/电源/音量/旋转）已可发送；触摸坐标映射未做 |
| M4 桌面与打磨 | ⏳ 未开始 | 日志面板已可用 |

> **曾经的误判（重要）**：第一次探测"只收到反复重发的初始头、没有视频帧"，
> 我一度写成"服务端 `scrcpy-server` 未启动"。真实主因是**探测脚本每收到一次初始头就回发一次
> 视频参数**，与服务端形成反馈循环、编码器被反复重启；改成"每条连接只发一次"后立刻出帧。
> 教训与细节见 `docs/ws-scrcpy-protocol.md` §6.2。

---

## 0. 目标与非目标

**目标**
- 连接到 ws-scrcpy,实时显示安卓画面(H.264)
- 支持触摸/鼠标、键盘、滚动、剪贴板(文本)、Home/Back/Recents/电源/音量等按键
- 全屏 / 常亮 / 自动重连 / 保存凭据 / 记住上次设备
- 至少 Android 与 Windows 可用;iOS 尽量

**非目标(第一版不做)**
- 不做音视频录制、不做多设备墙、不做文件推送(ws-scrcpy 有这些能力,但属于二期)
- 不改服务端协议(客户端必须适配服务端,不能反过来)

---

## 1. 前置:先把服务端弄成"可连"

**⚠️ 已知问题**：设备端 `scrcpy-server` 目前会崩,日志:

```
F DEBUG : Abort message: 'No pending exception expected:
          java.lang.ClassNotFoundException: com.genymobile.scrcpy.CleanUp'
F DEBUG : pid: ..., name: main  >>> app_process <<<
```

这说明**推送到设备上的 `scrcpy-server.jar` 与 ws-scrcpy 期望的版本不一致**,投流起不来(网页表现为白屏)。
开发前必须先在服务器侧解决(参考:重建/更新 `scrcpy-web` 镜像,或清掉设备上的旧 jar 让它重推):

```bash
# 服务器上(示例)
cd ~/redroid && sudo docker compose pull scrcpy-web && sudo docker compose up -d
adb -s 127.0.0.1:5555 shell "rm -f /data/local/tmp/scrcpy-server.jar /data/local/tmp/ws_scrcpy.pid"
```

**验收(网页端能出画面)** 才算服务端就绪:
`https://android.dorkytiger.top/` → 点设备 → 看到安卓桌面。

---

## 2. 协议参考(逆向自 ws-scrcpy 源码)

> 源码:`https://github.com/NetrisTV/ws-scrcpy`(**master 分支**);下面每条都标了对应文件,实现时以源码为准。

### 2.1 传输与握手

- 传输:**WebSocket**(公网是 `wss://`),握手时可以带 `Authorization: Basic ...`(Dart:`WebSocket.connect(url, headers: {...})`)。
- 连接 URL 带查询参数(见 `src/app/googDevice/client/StreamClientScrcpy.ts`):
  - `action` = 投流动作(`ACTION.STREAM_SCRCPY`)
  - `udid` = 设备序列号(设备列表接口里给的那个)
  - `ws` = 服务端下发的路径/参数(客户端原样回填)
- 设备列表来自 HTTP 接口(网页端启动时调的),**要在协议探测阶段抓一次**(见 §5 里程碑 M0)。

### 2.2 复用层(自定义,协议的心脏)

所有数据都包在**自己的一层复用协议**里(`src/packages/multiplexer/`):

```
MessageType (src/packages/multiplexer/MessageType.ts)
  CreateChannel = 4
  CloseChannel  = 8
  RawBinaryData = 16
  RawStringData = 32
  Data          = 64

帧格式 (src/packages/multiplexer/Message.ts):
  [0]      type      : uint8
  [1..4]   channelId : uint32 **little-endian**
  [5..]    payload   : 原始字节(长度 = 帧长 - 5)
```

- 打开一条逻辑通道 = 发 `CreateChannel` + payload(**通道名字符串**,utf8)
- 通道内数据 = `Data` / `RawBinaryData` / `RawStringData`
- 关闭 = `CloseChannel`
- `CloseEvent` 的 payload 是 `[code:uint16le][reasonLen:uint32le][reason]`

> **待探测(写代码前必须确认)**:通道名到底叫什么(视频/控制/音频各是哪个名字、谁是 server→client 谁是 client→server)。
> 方法见 M0:连一次、把 `CreateChannel` 的 payload 打出来即可。

### 2.3 视频

- 通道内传的是 **H.264 码流**(scrcpy-server 编码;可能有元数据帧描述分辨率)。
- ws-scrcpy 网页端提供三种解码器(README):
  - **MsePlayer**:把 H.264 用 `h264-converter` 重新封装成 **fMP4**,交给 `<video>` + MSE(`video/mp4; codecs="avc1.42E01E"`)
  - **TinyH264**:WASM 软解
  - **WebCodecs**:浏览器硬解
- **给客户端的启示**:除了"原生硬解",**"重封装成 fMP4 交给系统播放器"是被验证过的路线** ✓
  (Android 侧就是 ExoPlayer/MediaCodec 吃 fMP4;iOS 侧 AVPlayer 同理)

### 2.4 控制(客户端要发的消息)

`src/app/controlMessage/` 下有完整实现,可直接**逐字节移植**:

| 文件 | 用途 |
|---|---|
| `ControlMessage.ts` | 消息基类 + 类型常量 |
| `TouchControlMessage.ts` | 触摸/鼠标 |
| `KeyCodeControlMessage.ts` | 物理键/按键 |
| `ScrollControlMessage.ts` | 滚轮 |
| `TextControlMessage.ts` | 文本(剪贴板粘贴) |
| `CommandControlMessage.ts` | 命令(如 屏幕开关、剪贴板同步) |

**触摸消息的精确字节布局**(`TouchControlMessage`,共 29 字节,**全部大端**):

```
offset  size  field
0       1     type        = TYPE_TOUCH
1       1     action      (0=down, 1=up, 2=move)
2       4     pointerId   高位 4 字节(java long)
6       4     pointerId   低位 4 字节
10      4     x           像素
14      4     y           像素
18      2     screenWidth
20      2     screenHeight
22      2     pressure     0xFFFF 表示 1.0
24      4     buttons
```

> 注意:scrcpy 是**先写 java long 的高 4 字节再写低 4 字节**(见其 `writeUInt32BE(0, ...)` 占位),照抄即可。

### 2.5 未确定项清单（**已在 M0 用真实连接确认，结论见 `docs/ws-scrcpy-protocol.md`**）

- [x] 设备列表的获取方式与返回结构 —— **不是 HTTP 接口**：连 `wss://<入口>/?action=multiplex`，
      再 `CreateChannel("GTRC")`，服务端在该通道下发
      `{"type":"devicelist","data":{"list":[…]}}`（拿 `udid`）✓ 已实测
- [x] WS 连接 URL 的完整参数 —— 复用/列表：`?action=multiplex`；
      投流：设备直连 `ws://<设备IPv4>:8886/?action=stream&udid=<udid>`，
      公网再包一层 `?action=proxy-ws&ws=<内层地址>` ✓ 已实测（`action` 常量值为 `stream`，不是 `stream-scrcpy`）
- [x] 复用层通道名 —— 设备列表 `GTRC`（安卓）/ `ATRC`（苹果）；另有 `FSLS`/`HSTS`/`SHEL`/`WDAP`/`QVHS` ✓ 已实测
- [x] 视频通道的元数据/帧头 —— **视频通道不走复用层**；连接后第一条二进制消息是
      magic 为 `scrcpy_initial` 的初始信息头（设备名 64 字节 + 显示器信息 + 编码器 + clientId，
      含分辨率/编码参数），字段布局见 `docs/ws-scrcpy-protocol.md` §4.2 ✓ 已实测并已实现解析
- [x] 控制通道是否需要先 `CreateChannel` —— **不需要**：投流连接建立后，
      控制消息直接以二进制帧发在同一条 WS 上 ✓ 已实测
- [x] 心跳/keepalive —— 未观察到应用层心跳；服务端会周期性重发初始信息头 ✓ 已实测

> ⚠️ 仍待服务端修复后复验：**视频帧本身**（`sendFrameMeta` 的 12 字节帧信息）。
> 本次实测未收到任何视频数据，原因与 §1 的已知问题一致（设备端 `scrcpy-server` 未起来），
> 详见 `docs/ws-scrcpy-protocol.md` §6。

---

## 3. 技术选型(三档,建议按顺序走)

| 方案 | 做什么 | 工期 | 拿到什么 | 风险 |
|---|---|---|---|---|
| **A. WebView 壳** | `webview_flutter` 加载公网 URL;注入 JS 隐藏页面工具栏;全屏 + 屏幕常亮 + 保存 Basic Auth + 返回键映射 | **半天~1 天** | 真 App 图标、真全屏、常亮、免输凭据;三端一致 | 低 |
| **B. Flutter + 手写协议 + 原生/插件解码** | 实现 §2 全部协议 + 解码渲染 + 输入 | **1~3 周**(MVP) | 完全自控的 UI/手柄/多设备 | 中高(协议无文档、要跟版本) |
| **C. 自建网关 + 自定义协议** | 写 Node/Go 网关直连 `scrcpy-server`,对外用**你自己定**的协议 | **3~6 周** | 长期最稳,不受 ws-scrcpy 私有 framing 影响 | 中(活多) |

**解码后端的可选路线(B 方案内部)**

| 路线 | 说明 | 评价 |
|---|---|---|
| 平台通道 + 原生 | Android:`MediaCodec` + `Surface`/`Texture`;iOS:`AVSampleBufferDisplayLayer` | 最可控,工作量最大 |
| **重封装 fMP4** | 把 H.264 包成 fMP4 分片,喂系统播放器(Android ExoPlayer / iOS AVPlayer) | **最省事且被浏览器验证过** ✓ |
| `fvp`(libmdk/FFmpeg) | 硬解 + 自定义数据源 | 需先验证"能不能喂裸包"(README 未明确) |
| `media_kit`(libmpv) | 用 `lavf` + 本地 socket/fifo 喂流 | 可行但要 hack |

> **建议**:先用 §5 的 M0 把协议摸清,同时花 1 小时验证"**重封装 fMP4**"这条路线能不能喂进 Flutter 的播放器(能的话 M2 会快很多)。

---

## 4. 架构设计

```
┌──────────────────────── Flutter App ────────────────────────┐
│ SettingsStore(服务地址/Basic Auth/设备 udid/画质参数)         │
│        │                                                     │
│  WsClient ──(WebSocket + Authorization)──► ws-scrcpy 服务端  │
│        │                                                     │
│  Multiplexer(§2.2 解复用:按 channelId 分发)                  │
│        ├── VideoChannel ──► VideoSource                     │
│        │                       ├─(路线1) Fmp4Remuxer ──► Player │
│        │                       └─(路线2) NativeDecoderChannel    │
│        ├── ControlChannel ◄── InputMapper(触摸/键/滚/文本)     │
│        └── MetaChannel(分辨率/编码参数/心跳)                  │
│  Renderer:Texture/Surface + 全屏 + 缩放策略(scale/1:1)       │
│  UX:常亮、返回键、手势区、快捷栏、自动重连、错误提示           │
└──────────────────────────────────────────────────────────────┘
```

**模块职责**
- `WsClient`:建连/重连(指数退避)、Basic Auth 头、wss、日志
- `Multiplexer`:5 字节头解析、通道表、粘包/半包处理(**必须写单元测试**)
- `VideoSource`:把 H.264 取出并交给解码路线;处理 SPS/PPS
- `InputMapper`:把 Flutter 手势映射成 §2.4 的消息(注意屏幕尺寸要与视频尺寸一致)
- `SettingsStore`:`flutter_secure_storage` 存凭据(别明文存)

---

## 5. 里程碑(M0 必须先做,否则后面全是猜)

### M0 —— 协议探测(半天,**产出文档 + 抓包**)
1. 用 Dart 或 Python 连一次 WS,把**每条复用帧**的 `type / channelId / payload 前 64 字节` 打出来
2. 确认 §2.5 的全部未确定项,回填本文档
3. 产出:一份"协议实测记录"(含通道名、参数、视频首帧结构)

**验收**:能用脚本打印出视频通道的首几个包,并能从中看出 H.264 起始码(`00 00 00 01`)或 SPS/PPS。

### M1 —— WebView 壳(半天,先让手机上有东西可用)
- `webview_flutter` 加载 `https://android.dorkytiger.top/`
- 注入 CSS/JS 隐藏页头、撑满窗口;监听 `onWebResourceError` 给出友好提示
- 屏幕常亮(`wakelock_plus`)、全屏、返回键 = 网页后退
- 凭据:首次手工输入后写入 `flutter_secure_storage`,或直接用 `WebViewController.loadRequest` 带 `Authorization` 头

**验收**:Android/Windows 上点开 App → 直接看到安卓画面、可操作、不熄屏。

### M2 —— 原生解码 MVP(1~2 周)
- 完成 §2 的 WS + 复用 + 视频通道
- 解码先选**最省事的那条**(优先 fMP4 重封装)
- 渲染到 Flutter 的 `Texture` / `PlatformView`
- 只做"看":暂不发控制消息

**验收**:延迟可接受地显示画面;断线能自动重连;720p30 连续 10 分钟不崩、不泄内存。

### M3 —— 输入与 UX(3~5 天)
- 触摸(§2.4 的 29 字节消息)、长按、滑动;键盘;滚动;文本粘贴
- 全屏/缩放/旋转锁定、快捷栏(Home/Back/Recents/音量/电源)
- 手势冲突处理(边缘滑动 vs 安卓手势导航)

**验收**:能完成一次真实的游戏点击流程(进游戏、点确认、拖动)。

### M4 —— 桌面端与打磨(3~5 天)
- Windows/macOS:`flutter build windows`,窗口缩放/置顶/多窗口
- 手柄(gamepad)映射、快捷键、截图
- 崩溃与协议异常的可观测性(日志面板)

---

## 6. 工程骨架

> **实际落地结构见项目根目录 `AGENTS.md` §4 的映射表**：文档这里的骨架是"按技术分层"，
> 实现按全局规范的 `common / core / feature` 三分层落地，文件级对应关系已在那里列全。

**依赖(pubspec)**（实际已装版本）
```yaml
dependencies:
  flutter_secure_storage: ^9.2.4   # 凭据安全存储
  wakelock_plus: ^1.2.10           # 屏幕常亮
  webview_flutter: ^4.10.0         # M1 壳（仅 Android/iOS/macOS）
  url_launcher: ^6.3.1             # 桌面端打开系统浏览器
  # 解码路线二选一(先用 M0/1 小时 PoC 决定):
  # fvp: ^0.2x
  # media_kit: ^1
dev_dependencies:
  flutter_test:                    # 测试用 flutter_test（项目未引入 test 包）
```

**目录**
```
lib/
  main.dart
  core/{ws_client.dart,multiplexer.dart,message.dart,channel.dart}
  video/{video_source.dart,fmp4_remuxer.dart,native_decoder.dart}
  input/{input_mapper.dart,control_messages.dart}
  settings/settings_store.dart
  ui/{player_page.dart,settings_page.dart,device_list_page.dart}
  shell/webview_shell.dart        # M1
test/multiplexer_test.dart        # ★ 半包/粘包必测
tools/probe.dart                  # M0 协议探测脚本
```

**复用层解析(伪代码,Dart)**
```dart
// 收到一段字节流,可能粘包/半包 → 必须用累积缓冲区
void onData(Uint8List chunk) {
  _buf.addAll(chunk);
  while (_buf.length >= 5) {
    final type = _buf[0];
    final channelId = ByteData.sublistView(_buf, 1, 5).getUint32(0, Endian.little);
    // 帧长未知!→ 依赖通道内部协议自带长度(见 M0 实测),或按消息类型解析
    //  👉 这也是 M0 必须确认的点之一
  }
}
```

**触摸消息编码(Dart)**
```dart
Uint8List touch(int action, int pointerId, int x, int y, int w, int h, int pressure, int buttons) {
  final b = ByteData(29);
  b.setUint8(0, kTypeTouch);
  b.setUint8(1, action);          // 0 down / 1 up / 2 move
  b.setUint32(2, 0, Endian.big);  // pointerId 高 4 字节
  b.setUint32(6, pointerId, Endian.big);
  b.setUint32(10, x, Endian.big);
  b.setUint32(14, y, Endian.big);
  b.setUint16(18, w, Endian.big);
  b.setUint16(20, h, Endian.big);
  b.setUint16(22, pressure, Endian.big);
  b.setUint32(24, buttons, Endian.big);
  return b.buffer.asUint8List();
}
```

---

## 7. 测试与验收

**协议层**
- 单元测试:复用层(5 字节头、LE 解析、粘包/半包、CloseEvent)
- 集成:真实服务端连一次,断言能收到视频通道数据、能发出触摸消息并被安卓响应(屏幕上能看到点击效果)

**网络**
- `wss` + Basic Auth 握手成功(公网)
- 断网 30 秒后自动重连成功
- 服务器重启后能自动恢复

**性能(720p30 为基线)**
- 端到端延迟(手指到画面)< 300ms(内网);< 600ms(公网)
- 连续运行 30 分钟:无内存增长(用 DevTools 看),无崩溃

---

## 8. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 协议无文档、随服务端版本漂移 | 客户端可能突然连不上 | M0 记录实测协议;**锁服务端镜像版本**(别用 `:latest` 自动更新);方案 C 可根治 |
| 设备端 scrcpy-server 崩溃 | 完全没画面 | 开发前先修(§1) |
| Flutter 无裸 H.264 一等 API | M2 卡住 | 优先"重封装 fMP4";否则写平台通道 |
| 公网 Basic Auth + wss | 握手被 401 | WS 握手带上 `Authorization` 头;401 时给明确提示 |
| iOS 后台/常亮限制 | 体验不一致 | 明确文档化:锁屏即断;用画中画/常亮折中 |
| 输入坐标与视频缩放不一致 | 点击偏移 | 统一以"视频坐标系"发消息,渲染层做缩放换算 |

---

## 9. 参考资料

- ws-scrcpy 源码(逐行对照的最重要参考)
  - `src/packages/multiplexer/{MessageType,Message,Multiplexer}.ts` —— **复用协议**
  - `src/app/googDevice/client/StreamClientScrcpy.ts` —— 客户端连接与初始化
  - `src/app/googDevice/client/StreamReceiverScrcpy.ts` —— 收流/分发
  - `src/app/controlMessage/*.ts` —— **控制消息逐字节实现**
  - `src/server/goog-device/ScrcpyServer.ts` —— 服务端如何起 scrcpy-server
  - `src/app/googDevice/client/player/*`(Mse/TinyH264/WebCodecs) —— **解码路线参考**
- scrcpy 官方(协议本源):`Genymobile/scrcpy` 的 `app/src/control_msg.h`、`display/` 相关代码
- 解码/播放:`wang-bin/fvp`(libmdk/FFmpeg)、`media-kit/media-kit`(libmpv)
- 浏览器侧范式:`xevokk/h264-converter`(H.264 → fMP4,正是 MsePlayer 用的)

---

## 10. 给实现者的"第一小时"清单

1. `pnpm`/`npm` 起一个最小 Dart 控制台工程,`web_socket_channel` 连上 `wss://android.dorkytiger.top/`(带 Basic Auth)
2. 把所有收到的**原始字节**按 16 进制 dump 出来 → 对照 §2.2 找出 `CreateChannel` 与其 payload(通道名)
3. 拿到设备列表接口的返回(用浏览器 F12 → Network 抓一次也行),存成 fixture
4. 回填 §2.5 清单 → 这时你才知道 M2 到底要写多少代码
5. 顺手验证"fMP4 重封装"路线是否可行(能喂进 ExoPlayer/AVPlayer 就赢一半)

> 做完 1~5,再决定是继续 A(壳)还是投入 B/C —— **不要跳过 M0**。