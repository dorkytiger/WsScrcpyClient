# ws-scrcpy 协议实测记录（M0 产出）

> 本文是 `FLUTTER_AGENT.md` §5「M0 协议探测」的产出，用于回填 §2.5 的未确定项。
> **事实来源**：① 真实服务端 `https://android.dorkytiger.top/` 的实连抓取；
> ② 同站点网页 `bundle.js`（未混淆，可读，含完整客户端实现）。
> 所有结论都可以用 `dart run tools/probe.dart` 复现（命令见文末）。

探测时间：2026-09-30；服务端 `scrcpy-server` 版本字符串（bundle 内常量 `SERVER_VERSION`）：`1.19-ws6`。

---

## 1. 结论速览

| 问题 | 结论 |
|---|---|
| 设备列表接口 | **不是 HTTP 接口**，是复用层通道：`wss://<entry>/?action=multiplex` + `CreateChannel("GTRC")` |
| 设备列表消息 | 通道内文本帧，JSON `{"type":"devicelist","data":{"list":[…]}}` |
| 投流地址 | 由客户端构造：内层 `ws://<设备IPv4>:8886/?action=stream&udid=<udid>`，公网再包一层 `wss://<entry>/?action=proxy-ws&ws=<内层>` |
| 复用层通道名 | 设备列表 `GTRC`（安卓）/ `ATRC`（苹果）；还有 `FSLS`（文件列表）、`HSTS`（主机）、`SHEL`（终端）、`WDAP`、`QVHS` |
| 视频通道 | **不走复用层**，`action=stream` 直接返回裸数据 |
| 视频首帧 | 是**初始信息头**（magic `scrcpy_initial`），不是 H.264 |
| 元数据/SPS/PPS | 初始头里给分辨率、编码器、连接数、编码参数；视频参数可由客户端用 `CHANGE_STREAM_PARAMETERS(101)` 覆盖 |
| 客户端必须先 CreateChannel 吗 | 设备列表要；投流不要（连接即出初始头） |
| 心跳 | 未观察到心跳；服务端在参数变更时会重发初始信息头 |
| 视频数据 | ✅ 已实测：**一条 WS 消息一帧裸 H.264**（`00 00 00 01` 起始码），SPS+PPS → IDR → P 帧，见 §4.4 |

> ⚠️ 客户端**每条投流连接只能下发一次**视频参数，否则会与服务端形成重发初始头的反馈循环，
> 表现为"一直收不到视频帧"（详见 §4.4 与 §6.2）。

---

## 2. 复用层（multiplexer）

### 2.1 帧格式（与文档 §2.2 一致，实测确认）

```
offset size field
0      1    type      : uint8
1      4    channelId : uint32 little-endian
5      N    payload   : N = 帧长 - 5
```

**关键实测补充**：帧头里**没有长度字段**，因为**一个 WebSocket 消息恰好承载一个复用帧**
（服务端实现按 `message` 事件逐个 `Message.parse`）。因此不存在跨消息的粘包问题，
只有"消息短于 5 字节"的非法帧需要防御。

`MessageType`（实测自 bundle 模块 2701）：

| 名称 | 值 | 方向与语义 |
|---|---|---|
| `CreateChannel` | 4 | 双向；payload = 通道码（4 字节 ASCII）|
| `CloseChannel` | 8 | payload = `[code:uint16LE][reasonLen:uint32LE][reason:utf8]`（reason 本体固定从偏移 6 开始）|
| `RawBinaryData` | 16 | 通道内二进制 |
| `RawStringData` | 32 | 通道内 utf8 文本（设备列表走这个）|
| `Data` | 64 | 通道内数据帧 |

### 2.2 连接与握手

```
GET wss://android.dorkytiger.top/?action=multiplex
Authorization: Basic <base64(user:pass)>     ← 服务端开了 Basic Auth
```

- 客户端分配通道 id：从 **1** 开始递增；服务端主动开通道时客户端要避让（取 `max(已见 id)+1`）。
- 打开通道 = 发 `CreateChannel`，payload 就是通道码（**无长度前缀**，如 `GTRC` 四个字节）。
- 通道内数据发送：二进制用 `RawBinaryData`，文本用 `RawStringData`，部分通道用 `Data`。

---

## 3. 设备列表（GTRC 通道）

实连抓取到的原始消息（440 字节，已存为测试夹具 `test/fixtures/device_list.json`）：

```json
{
  "id": -1,
  "type": "devicelist",
  "data": {
    "list": [
      {
        "udid": "redroid:5555",
        "state": "device",
        "interfaces": [{ "name": "eth0", "ipv4": "192.168.112.2" }],
        "pid": 6261,
        "ro.build.version.release": "12",
        "ro.build.version.sdk": "31",
        "ro.product.manufacturer": "redroid",
        "ro.product.model": "redroid12_x86_64_only",
        "ro.product.cpu.abi": "x86_64",
        "last.update.timestamp": 1790776473357
      }
    ],
    "id": "5131ece376d066cab3d72fc689ceae91",
    "name": "aDevice Tracker [31006c670346]"
  }
}
```

要点：
- 设备数组在 **`data.list`**（不是 `data`）；
- `state` 取值为 `device` / `offline` / `unauthorized`（客户端已建枚举，未知值回落到"未知状态"）；
- `interfaces[].ipv4` 是**设备侧**网卡地址（Docker 网段 `192.168.112.2`），公网客户端无法直连，
  只能用于构造 `proxy-ws` 的内层地址；
- 服务端会持续推送该消息（设备上下线时更新），客户端取一次快照即可。

---

## 4. 投流（action=stream）

### 4.1 地址构造

```text
内层（设备直连）：ws://<interfaces[].ipv4>:8886/<path>?action=stream&udid=<udid>
公网（服务端代理）：wss://android.dorkytiger.top/?action=proxy-ws&ws=<URL-encoded 内层地址>
```

- 8886 是 ws-scrcpy 服务端自身端口（bundle 常量 `SERVER_PORT = 8886`）。
- 实测：公网入口下**代理地址可用、内层直连地址超时**（设备内网 IP 不可达），
  因此客户端把代理地址排在候选列表前面（见 `StreamTarget.candidateUris`）。

### 4.2 服务端下发：初始信息头（`scrcpy_initial`）

实测首帧 239 字节，头部字段布局（全部大端）：

```
offset size field
0      14   magic = "scrcpy_initial"
14     64   deviceName（utf8，\\0 填充）
78     4    displayCount
            每个 display：
              24  DisplayInfo
              4   connectionCount
              4   screenInfoLength + screenInfo（可为 0）
              4   videoSettingsLength + videoSettings（可为 0）
            4   encoderCount
            每个编码器：4 长度 + utf8 名称
            4   clientId
```

- `DisplayInfo`（固定 24 字节）：`displayId:i32 | width:i32 | height:i32 | rotation:i32 | layerStack:i32 | flags:i32`。
- `ScreenInfo`（固定 25 字节）：`contentRect(left/top/right/bottom : i32) | videoWidth:i32 | videoHeight:i32 | deviceRotation:u8`。
- `VideoSettings`（基础 35 字节）：`bitrate:i32 | maxFps:i32 | iFrameInterval:i8 | bounds.w:i16 | bounds.h:i16 |
  crop(l,t,r,b : i16) | sendFrameMeta:i8 | lockedVideoOrientation:i8 | displayId:i32 |
  codecOptionsLen:i32 + bytes | encoderNameLen:i32 + bytes`。

实测样本（脱敏后）：

```text
设备名     : redroid12_x86_64_only      clientId: 3
display=0  : 1280x720, rotation=0
screenInfo : contentRect=(0,0,1280,720), videoSize=1280x720, deviceRotation=0
编码器     : c2.android.avc.encoder, OMX.google.h264.encoder
```

### 4.3 客户端必须回一次视频参数（**否则不启动编码**）

网页端逻辑（bundle `StreamClientScrcpy.onDisplayInfo`）：收到 `displayInfo` 后，
只要"当前请求的参数与服务端参数不一致 或 尚未 join"，就发送
`CHANGE_STREAM_PARAMETERS(101)`：

```
0      1    type = 101
1      N    VideoSettings.toBuffer()
```

`tools/probe.dart` 与 `StreamSessionService` 都实现了这一步（回服务端参数，`sendFrameMeta=false`）。

### 4.4 视频数据（✅ 已实测，裸 Annex-B）

`sendFrameMeta = false` 时，初始头之后同一条 WS 上的每条二进制消息就是**一帧裸 H.264**：

- **一条 WS 消息 = 一帧**，不需要自己做流式切分；
- 每条消息都以 **4 字节 Annex-B 起始码 `00 00 00 01`** 开头，随后是 NAL 单元；
- `sendFrameMeta = true` 时每帧前会多 12 字节帧信息（8 字节 PTS + 4 字节长度）——**本次未启用、未验证**。

实测样本（10 秒窗口，295 条消息 / 1 211 480 字节，平均 4107 字节）：

| 序号 | 长度 | 前几字节 | 判定 |
|---|---|---|---|
| #1 | 32 | `00 00 00 01 67 42 c0 29 … 00 00 00 01 68 ce 01 a8 …` | **SPS(7) + PPS(8)**，单独一条消息先发 |
| #2 | 57422 | `00 00 00 01 65 b8 00 04 …` | **IDR 片(5)**，关键帧 |
| #3 | 615 | `00 00 00 01 61 e0 00 20 …` | 非 IDR 片(1) |
| #4…#N | 179 ~ 26 KB | `00 00 00 01 61 …` | 非 IDR 片(1) |

结论：文档 §5 M0 的验收条件（"能打印出视频通道的首几个包，并能看出 H.264 起始码或 SPS/PPS"）**已达成**；
M2 的解码/重封装可以直接按"起始码切分 → SPS/PPS → IDR → P 帧"来写，
真实报文夹具已存为 `test/fixtures/stream_first_video_frames.txt`。

> ⚠️ 踩坑记录（很重要）：客户端**每条连接只能下发一次** `CHANGE_STREAM_PARAMETERS`。
> 曾经写成"每收到一次初始信息头就回一次视频参数"，结果与服务端形成反馈循环
> （改参数 → 服务端重发初始头 → 客户端再改参数），10 秒内刷了 36 次/秒的初始头、
> 却**一帧视频都收不到**，很容易被误判成"服务端坏了"。
> `StreamSessionService` 用 `_settingsSentForCurrentConnection` 保证只发一次。


---

## 5. 控制消息（客户端 → 服务端）

控制消息直接以**二进制帧**发在投流那条 WS 上（不是复用层通道）。类型常量（实测自 bundle 模块 831）：

| 名称 | 值 | 载荷 |
|---|---|---|
| `TYPE_KEYCODE` | 0 | `action:u8 | keycode:i32 | repeat:i32 | metaState:i32`（共 14 字节）|
| `TYPE_TEXT` | 1 | `length:u32 | utf8`（长度用**字节数**）|
| `TYPE_TOUCH` | 2 | `action:u8 | pointerId:u64(高4字节先写) | x:i32 | y:i32 | screenW:u16 | screenH:u16 | pressure:u16 | buttons:i32` + 1 字节零填充 = 29 字节 |
| `TYPE_SCROLL` | 3 | `x:i32 | y:i32 | screenW:u16 | screenH:u16 | hScroll:i32 | vScroll:i32`（共 21 字节）|
| `TYPE_BACK_OR_SCREEN_ON` | 4 | 无 |
| `TYPE_EXPAND_NOTIFICATION_PANEL` | 5 | 无 |
| `TYPE_EXPAND_SETTINGS_PANEL` | 6 | 无 |
| `TYPE_COLLAPSE_PANELS` | 7 | 无 |
| `TYPE_GET_CLIPBOARD` | 8 | 无 |
| `TYPE_SET_CLIPBOARD` | 9 | `paste:u8 | length:u32 | utf8` |
| `TYPE_SET_SCREEN_POWER_MODE` | 10 | `mode:u8`（1=开屏 0=关屏）|
| `TYPE_ROTATE_DEVICE` | 11 | 无 |
| `TYPE_CHANGE_STREAM_PARAMETERS` | 101 | `VideoSettings` |
| `TYPE_PUSH_FILE` | 102 | 二期（非目标）|

**文档 §2.4 的 29 字节触摸布局得到确认**，并补上了文档没写的第 29 字节：
服务端实现 `Buffer.alloc(PAYLOAD_LENGTH+1)`（29 字节）但只写前 28 字节，
**偏移 28 恒为 0x00**。`pointerId` 的高 4 字节先写（Java long 语义）。

按键常量（Android keycode）：HOME=3、BACK=4、APP_SWITCH=187、POWER=26、VOLUME_UP=24、
VOLUME_DOWN=25、ENTER=66、WAKEUP=224、MENU=82。

---

## 6. 验证状态与踩过的坑

### 6.1 已端到端验证

| 项 | 证据 |
|---|---|
| 复用层握手 + 设备列表 | `?action=multiplex` + `GTRC` 通道拿到 440 字节真实 devicelist（夹具 `device_list.json`）|
| 投流地址 | `?action=proxy-ws&ws=<内层>` 连接成功；内层直连地址从公网不可达 |
| 初始信息头 | 239~275 字节结构完整解析（设备名/分辨率/编码器/连接数，夹具 `stream_initial_info.hex`）|
| 客户端下发视频参数 | 服务端随后回显我们下发的参数，并开始推流 |
| **视频数据** | 295 条消息 / 1.2 MB，SPS+PPS → IDR → P 帧，见 §4.4 |
| 控制消息编码 | 逐字节单测（按键/触摸/滚动/文本/命令），见 `test/core/control/` |

### 6.2 曾误判为"服务端坏了"的坑

第一次探测时 10 秒内只收到反复重发的初始信息头、没有任何视频帧，我据此写过
"服务端设备端 scrcpy-server 没起来"的结论——**这个结论是错的**。真实原因是两条叠加：

1. **客户端反馈循环**（主因）：探测脚本每收到一次初始头就回发一次视频参数，
   服务端于是不停重启编码器，永远走不到推流；改成"每条连接只发一次"后立刻出帧（§4.4 踩坑记录）。
2. **服务端当时确实在修**：期间服务端侧调整过（服务端下发的参数从
   `bitrate 524288 / maxFps 24 / bounds 2496x1264` 变成 `bitrate 7340032 / maxFps 60 / bounds 1856x960`），
   修好之后配合上面的修正就能正常出流。

教训：**协议层收不到数据时，先怀疑自己的请求时序，再怀疑服务端**；
排查时要看"单位时间收到的字节数"，只看"有没有视频帧"会把循环刷包误判成服务端故障。

### 6.3 仍未验证

1. `sendFrameMeta = true` 时每帧前那 12 字节帧信息（本次全程 `false`）。
2. 文本消息长度语义：bundle 的 `TextControlMessage` 用 JS UTF-16 码元数当长度，
   而设备端按字节读；本项目改按 **utf8 字节数**写（中文才正确），需真实中文输入复验。
3. 触摸/按键是否真被安卓响应（缺少能看画面的端到端验证环境）。
4. 音频通道（本版本非目标）。


---

## 7. 复现方式

```powershell
# 1) 设备列表 + 投流地址探测（会打印每帧的类型/长度/前 64 字节）
$env:WS_PROBE_USER='<用户名>'
$env:WS_PROBE_PASSWORD='<密码>'
$env:WS_PROBE_SECONDS='8'
dart run tools/probe.dart

# 2) 同时把真实报文写成单元测试夹具 test/fixtures/
$env:WS_PROBE_WRITE_FIXTURES='1'
dart run tools/probe.dart
```

`tools/probe.dart` 只用 `lib/core/**` 里的协议实现（复用层、初始头解析、控制消息编码），
因此探测结果与 App 运行时行为同源，不存在"脚本能跑、App 不能跑"的偏差。
