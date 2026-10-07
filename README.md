# ws-scrcpy 客户端

[![build](https://forgejo.dorkytiger.top/u758272094/WsScrcpyClient/badges/workflows/build.yml/badge.svg?branch=master)](https://forgejo.dorkytiger.top/u758272094/WsScrcpyClient/actions)
[![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter)](https://flutter.dev)
[![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20iOS%20%7C%20Windows%20%7C%20macOS%20%7C%20Web-success)](#平台支持)

把 [ws-scrcpy](https://github.com/NetrisTV/ws-scrcpy) 的安卓投流装进一个**真正的 App**：
五端都能出画面、都能操作，走的是**原生协议层**（不是套一层 WebView），
触摸 / 滚轮 / 物理键盘直接可用，延迟低到**可以远程玩游戏**。

> 设备端画面由安卓的**硬件编码器**产出（scrcpy 路线：显示合成 Surface 直连编码器，
> 像素不进 CPU），客户端这一侧再按平台挑最快的解码路径 —— 这也是它比
> "装在手机上的 VNC / 远程桌面 App"流畅得多的根本原因。
>
> **目标**：内网端到端 **< 300ms**、流畅到可以交互（拖动、玩游戏）；
> **非目标**：音视频录制、多设备墙、文件推送、音频通道 —— 以及**不改服务端协议**
> （客户端适配服务端，不能反过来）。

---

## 功能

| | |
|---|---|
| **画面** | 裸 H.264（Annex-B，一条 WS 消息一帧）→ 各平台原生硬解 → 纹理 / canvas 上屏；**低延迟模式**全开（见下） |
| **输入** | 触摸（多指）/ 鼠标拖拽 / 滚轮 / 物理键盘（含修饰键 `metaState`）；坐标按视频像素换算，配 DOWN/UP 配对状态机（不会把设备端的手指卡住） |
| **快捷栏** | 返回 / 主页 / 最近 / **旋转本机** / 更多（音量、电源、旋转**被控设备**、下拉面板、断开、**日志**、清晰优先都在"更多"里）；横屏另有一个「顶栏」按钮（在快捷栏里，**不压在画面上**）。「旋转本机」转的是这个 App 自己的朝向（竖屏 ⇄ 横屏），与「更多」里那条转设备的命令不是一回事 |
| **显示适配** | **填满屏幕**（右上角一键：隐藏上下边栏、把整块屏幕交给画面；画面按 **fit** 铺进去 —— **不裁切、不超出屏幕**，横竖屏各自算；**画面上左滑退出**）；横屏顶栏收起 + 快捷栏竖排贴右（把省下的高度全给画面）；画面区外的黑边点击不会误发 |
| **画质** | 三档下拉：**流畅运行**（只编原生，设备最省力）/ **推荐**（原生 ×1.5）/ **最高画质**（原生 ×2，默认）。按画面区的**物理像素**向设备要编码尺寸，并照抄服务端网页端的码率/帧率（7 Mbps / 60fps）；面板里直接显示**生效编码边界 + 本地放大倍率**，切了有没有生效一眼可查 |
| **连接** | 代理地址优先 + 直连兜底、指数退避重连、鉴权失败不重连（把提示交给用户）、多套配置（设置页切换） |
| **凭据** | 随配置一起存本机 SQLite（**密码是明文列**，2026-10-07 起不再用系统安全存储，见 AGENTS §7）；web 端由浏览器代管凭据，见下 |
| **诊断** | 毫秒时间戳日志 + 应用内日志面板；`视口诊断`（本秒下发了几条编码参数）、`画面诊断`（生效编码边界 / **本地放大倍率** / 输入层是否接上）、原生解码心跳（`帧间隔` vs `平均处理`）—— 出问题先看这三行 |

### 平台支持

| 平台 | 解码 | 上屏方式 | 状态 |
|---|---|---|---|
| Android | `MediaCodec`（异步 + `SurfaceProducer`） | Flutter `Texture`（零拷贝） | ✅ 实机验证 |
| Windows | Media Foundation H.264 解码器 MFT → NV12 → D3D11 GPU 转 RGBA（CPU 路兜底） | 共享纹理 / `PixelBufferTexture` | ✅ 实机验证 |
| iOS / macOS | VideoToolbox `VTDecompressionSession`（`RealTime = true`） | `CVPixelBuffer` → `FlutterTexture` | ✅ macOS 已实跑；**iOS 仅模拟器**（差真机签名） |
| **Web** | **WebCodecs `VideoDecoder`**（Annex-B 直喂，参数集随关键帧一起送） | canvas 平台视图（几何与触摸换算同源） | ✅ 2026-10-07 实测出画面；**触摸未复验** |
| Linux | — | — | ⏳ 未做（可先用设备卡片上的"网页"入口） |

---

## 快速开始

### 0. 你要先有一个能用的 ws-scrcpy 服务端

验收标准很简单：**用浏览器打开服务端自带的网页版，能看到安卓桌面**。
看不到就是服务端/设备端没就绪（`scrcpy-server.jar` 版本、容器里的显示服务等），
客户端这边再怎么调都没用。另外服务端若开了 Basic Auth，准备一份账号密码。

### 1. 环境

```bash
# Flutter 3.47+（stable）
flutter --version
flutter pub get
```

需要的话：
`dart analyze lib test tools` 应无问题，`flutter test` 应有 **271 通过 / 1 skip**。

### 2. 运行

```bash
flutter run -d <android-device-id>   # Android
flutter run -d windows               # Windows 桌面
flutter run -d macos                 # macOS 桌面
flutter run -d <ios-simulator-id>    # iOS 模拟器（macOS + Xcode + CocoaPods）
```

**首次进入**是连接配置表单：填服务端入口（开了 Basic Auth 再填账号密码），
保存后进入设备列表。配置存在本机 drift(SQLite)，密码是同一张表里的一列（明文），支持多套配置。

每个**设备卡片有两个入口**：

| 按钮 | 行为 |
|---|---|
| **网页** | 内嵌 WebView 打开该设备的网页版投流页（深链直达画面），带 Basic Auth 质询应答 |
| **投流** | 走原生协议通道（设备列表 → 初始化头 → 视频参数 → 解码渲染），触摸/滚轮/键盘直接可用 |

### 3. 网页端（web 构建）

```bash
tools/build_web.sh            # 产物在 build/web（已带 --no-web-resources-cdn）
tools/build_web.sh /app/      # 要挂到服务端子路径下时传 base-href
cd build/web && python3 -m http.server 8765   # 本地验证
```

两个**平台约束**必须先知道（否则会以为程序坏了）：

1. **浏览器不给 WebSocket 加自定义请求头** —— 所以 web 端不存密码，
   Basic 凭据只能由浏览器在 401 挑战时代管。跨源访问（`127.0.0.1:8765` → 你的服务端）
   **第一次必然要弹一次登录框**；把产物挂在**服务端同一个源站**下（如 `/app/`）
   就只会弹这一次。
2. **CanvasKit 要打到产物里**（`tools/build_web.sh` 已经加了 `--no-web-resources-cdn`），
   否则离线/内网打开永远白屏。

### 4. 各平台构建注意

<details>
<summary><b>Windows</b>：依赖已改成离线，构建期不调用 nuget</summary>

首次或换机器：`tools\prepare_windows_deps.cmd`（幂等，只写工作区），
之后 `flutter clean` + `flutter build windows` 无需任何手工步骤。
细节见 [docs/ci.md](docs/ci.md) 与 [AGENTS.md](AGENTS.md) §3.1。
</details>

<details>
<summary><b>iOS / macOS</b>：必须装 CocoaPods；两端共用同一份 Swift 解码器</summary>

```bash
brew install cocoapods
flutter build ios --debug --no-codesign     # 真机才需要签名
tools/run_vt_replay_probe.sh                # 离线验证 VideoToolbox 解码器（不需要设备）
```

`darwin/` 下的三个 Swift 文件被两个 Xcode 工程用 `path = ../darwin` 引用 —— 改一处两端同时生效。
</details>

<details>
<summary><b>受限环境</b>（沙箱 / 受限令牌）：进程写不了 %TEMP% 时怎么办</summary>

症状是 `flutter run` 报 `_createDevFS: ... Temp (errno = 5)`，或界面提示读取本地设置失败。
**首选从普通终端运行**；Windows 上也可以用 `tools\run_windows.cmd`
（把 `TEMP/TMP` 与应用数据目录都指到工作区）。见 [AGENTS.md](AGENTS.md) §3.2。
</details>

---

## 架构

```
                    ┌─────────────── Flutter（一份代码，五端） ───────────────┐
 ws-scrcpy 服务端    │  设备列表 → 投流页                                        │
 （HTTP + WebSocket）│    │                                                      │
        │           │    ├── StreamSessionService   复用层 / 控制消息 / 重连       │
        ├─ 设备列表  │    │      └── videoFrames（裸 H.264 Annex-B）               │
        └─ 投流通道  │    ├── PlayerViewModel         视口/边界、输入状态机、诊断     │
             │      │    │      └── VideoDecoder 接口 ──┬── 原生：MethodChannel   │
             └──────┼────┘                             └── web：WebCodecs         │
                    │                                                            │
                    │  上屏：Texture（原生）/ canvas 平台视图（web）                 │
                    │  输入：触摸/滚轮/键盘 → 控制消息（与视频同一条连接）             │
                    └────────────────────────────────────────────────────────────┘
```

```
lib/
├── app/         依赖装配（AppDependencies / AppScope）与跨模块导航
├── common/      设计 token、主题、三态通用组件
├── core/        无业务语义的能力：异常/Result/日志、复用层、控制消息、
│                投流协议模型、H.264 Annex-B 解析（web 端要用）
└── feature/
    ├── settings/  服务地址与凭据（drift；密码为明文列）
    ├── device/    设备列表（复用层 GTRC 通道）
    ├── stream/    投流会话、输入映射、播放页（五端解码分支都在这里）
    └── shell/     WebView 壳（网页版投流入口）
darwin/          iOS / macOS 共用的 VideoToolbox 解码（两个 Xcode 工程都引用）
windows/runner/  Windows 的 Media Foundation 解码 + D3D11 呈现
android/…/       Android 的 MediaCodec 解码
tools/           协议探测、离线探针（解码器自测）、打包脚本
docs/            协议实测、Apple 签名与上架、解码历史、CI
.forgejo/        ★ 当前在用的 CI：verify / android / web / windows
.github/         GitHub Actions（默认只手动触发，见 docs/ci.md §9）
```

---

## 文档

| 文档 | 什么时候读 |
|---|---|
| [AGENTS.md](AGENTS.md) | **改代码前先读**：工程约定、目录映射、各平台解码实现细节、踩过的坑与教训（很长，按 § 号查） |
| [docs/ws-scrcpy-protocol.md](docs/ws-scrcpy-protocol.md) | **动协议相关代码前必读**：逐字节实测记录、复用层、控制消息、视频帧结构 |
| [docs/apple-distribution.md](docs/apple-distribution.md) | 要给 iOS / macOS 签名、公证、上架时：已落地的工程配置、审核风险与对策 |
| [docs/windows-decoder-history.md](docs/windows-decoder-history.md) | Windows 解码从崩溃/黑屏到可用的完整证据链（排查同类问题的模板） |
| [docs/ci.md](docs/ci.md) | CI（Forgejo Actions：Android / web / Windows）与本机打包；另附 GitHub Actions 的说明 |

---

## 路线图

| 里程碑 | 状态 |
|---|---|
| M0 协议探测（设备列表 / 投流地址 / 初始信息头 / 控制消息逐字节 / 裸 H.264） | ✅ |
| M1 WebView 壳（`webview_all`：五端都有实现，全屏 / 常亮 / 带鉴权 / 返回键映射） | ✅ |
| M2 原生解码：Android `MediaCodec` / Windows MF MFT / iOS·macOS VideoToolbox / **web WebCodecs** | ✅ 五端出画面 |
| M3 输入：触摸（多指）/ 滚轮 / 物理键盘 | ✅ |
| M3 余项：剪贴板同步、软键盘文本注入、双指缩放 | ⏳ |
| M2 余项：**Linux 原生解码** | ⏳ |
| 打磨：应用标识从 `com.example` 改掉、iOS 真机签名、web 端触摸复验 | ⏳ |

---

## 已知限制

- **设备画面静止时不会有帧** —— scrcpy 只在画面变化时发帧，这是它的设计，不是卡了。
  想确认是"没帧"还是"卡住"，看日志里的 `帧间隔` 与 `WS 帧吞吐/s`。
- **iOS 只在模拟器上验过**，真机要过签名；`NSAllowsLocalNetworking` 与本地网络权限
  在真机上会不会拦也还没实测。
- **web 端的触摸还没复验**（画面上盖的是 DOM 平台视图，已设 `pointer-events: none`
  让事件回到 Flutter，但需要真机/真浏览器确认）。
- **清晰优先是有代价的**：向设备要更多像素意味着容器里的软编码器更吃力；
  掉帧明显就切回"省设备算力"（两者都在"更多"面板里，切换会立刻生效）。
- 应用标识仍是 `flutter create` 默认的 `com.example`。

---

## 相关项目

- [ws-scrcpy](https://github.com/NetrisTV/ws-scrcpy) —— 服务端（本项目只做客户端） 
- [scrcpy](https://github.com/Genymobile/scrcpy) —— 协议与"显示 Surface 直连硬编码器"这条路的源头

## 许可

本仓库**尚未指定开源许可证**（默认保留所有权利）。若要开源，请先补一个 `LICENSE`。
