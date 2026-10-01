# AGENTS.md — ws_scrcpy_client（项目级）

> 本文件补充/收紧全局规范（`~/.dsh/AGENTS.md`），**不得放宽**第 0 节十条铁律。
> 冲突裁决：本文件 > 全局规范 > 临时约定。

---

## 1. 项目是什么

ws-scrcpy 的**多端显示/操作客户端**（Flutter）。需求与里程碑见 `FLUTTER_AGENT.md`，
协议实测记录见 `docs/ws-scrcpy-protocol.md`（**改协议相关代码前先读它**）。

当前进度：

- ✅ M0 协议探测（设备列表、投流地址、初始信息头、控制消息逐字节、**裸 H.264 视频帧**）
- ✅ 协议层（复用层、控制消息编码、初始头解析、投流会话与重连）
- ✅ M1 WebView 壳（`webview_all`：Android / iOS / macOS / Windows / Linux）
- ✅ M2 路线 A：Android 原生硬解（`MediaCodec` → `SurfaceProducer` → Flutter `Texture`）
- ✅ M2 路线 A：Windows 原生解码（Media Foundation H.264 解码器 MFT → NV12 → **D3D11 GPU 转
  RGBA → 共享纹理 → `GpuSurfaceTexture`**；CPU `PixelBufferTexture` 路保留为兜底，见 **§12.8**）。
  **已实机确认能出画面**（2026-10-01 用户确认）；此前的崩溃/黑屏/卡顿/"270 帧只解出 1~2 帧"
  的根因与修法见 §12.1 / §12.4 / §12.5 / §12.6（全文在 `docs/windows-decoder-history.md`）
- ✅ M3 核心输入：触摸（多指）/ 滚轮 / 物理键盘（含修饰键 metaState）
- ⏳ M3 余项：剪贴板同步、软键盘文本注入、双指缩放等手势增强

### 1.1 交接：当前状态与下一步（新会话从这里读起）

**能用了**：设备列表 → 投流 → Windows 原生解码 → 画面 + 触摸/滚轮/键盘输入。
Android 端同样可用（MediaCodec 路线）。真机日志验证过 `已发布 332/370 帧`、`ProcessOutput 失败 0`。

**当前状态（2026-10-01 真机第四轮后）**：
1. ★ **`MF_LOW_LATENCY` 是"全黑 + 时不时卡几秒"的根因与修法**（见 §12.8 末尾）——
   已本机自动投流 + 自己截屏确认：`已发布 22/23`、画面正常；
2. §12.7 的"**禁止放大 + 16 宏块对齐**"——真机验证过（`已解码 67 / 已发布 67`）；
3. **GPU 共享纹理路默认关闭**（双显卡跨适配器，详见 §12.8 第三次），
   现在默认走 **CPU 像素缓冲路**；要看 GPU 路显式 `WS_SCRCPY_GPU=1`（可用 `WS_SCRCPY_GPU_ADAPTER` 选核显）；
4. **队列上限 60→4** + 两侧吞吐诊断计数已落地。

**教训（最贵的两条）**：① **`已发布 N 帧` ≠ 画面上屏**——日志全绿也可能黑屏，
**上屏问题必须自己截图确认**；② 排查要有"自己的眼睛和手"：`WS_SCRCPY_AUTOSTART=1` 自动投流 +
运行中可读的日志/抓包，让我能自己复现，不必让用户反复当测试机。

**已知未做**：Mac/Linux 原生解码（macOS/iOS 可行性见 `docs/platform-feasibility.md`，
macOS 的 `network.client` entitlement 已补）；剪贴板同步、软键盘文本注入、双指缩放；
`sendFrameMeta=true` 未验证；应用标识仍是 `com.example`。

**这个仓库以前没有 git**（`fatal: not a git repository`）：2026-10-01 已 `git init` 并做首次提交
（根 `.gitignore` 已补齐 `build/`、`.tmp/`、`.probe/`、`capture.bin`、日志、各平台 `ephemeral/` 等）。
**注意**：密码只存在系统安全存储里，任何情况下都不要把凭据写进仓库。

**今天踩过的坑都记在 §12.1–§12.7**（越界读、`destroying_` 未复位、参数下发方式、
协商顺序 + 脏样本、禁止放大）。**动解码/协议前先读它们**，尤其：
"日志里的顺序 ≠ 代码里的顺序"、"跨实例日志先按 pid 分组"、
"诊断工具不要维护第二份业务逻辑"、"先测量后优化"。

### 1.2 ★★ 关键点：平台解码器必须开"低延迟模式"（Windows 已踩，macOS 必看）★★

**这一条是整轮真机排查的结论，别再走一遍弯路**：

| 平台 | 解码器 | 必须做的事 | 不做的后果 |
|---|---|---|---|
| **Windows** | Media Foundation H.264 解码器 MFT | 创建后、开始流**之前**：`IMFAttributes::SetUINT32(MF_LOW_LATENCY, TRUE)` | **默认缓冲约 1.2 秒（30fps ≈ 38 帧）才吐第一张图**：画面静止时服务端只给二十来帧 → **永远黑屏**；编码器一重建就再攒一批 → **隔几秒卡一下然后一次性追平** |
| **macOS / iOS** | VideoToolbox（`VTDecompressionSession`） | **`kVTDecompressionPropertyKey_RealTime = true`**（同理还有 `kVTDecompressionPropertyKey_MaximizePowerEfficiency=false`、以及用 `AVSampleBufferDisplayLayer` 时设 `lowLatency`/必要时 `requiresFlushToResumeDecoding=false`） | 同样会攒帧：表现为首帧慢、画面滞后、静止时不出画 |
| Android（已实现） | `MediaCodec` | 已经是实时模式（SurfaceProducer），**无需改** | — |

**判断方法（不依赖肉眼）**：看心跳里 `已发布 / 已喂入` 的比例。
**`已发布 ≪ 已喂入` 就是"解码器在憋"**（Windows 上实测：不设开关 8/43、设了 42/43）。
**注意：`已发布 N 帧` ≠ 画面上屏** —— 日志全绿也可能是黑屏；上屏问题必须**自己截图确认**。

**离线验证入口**：`tools\run_mft_replay_probe.cmd [抓包]` 会同时打印"不设 / 设低延迟"两种结果，
谁把这里改坏会立刻暴露（抓包用 `WS_CAPTURE_FRAMES` 或 exe 同目录放 `ws_capture.txt`）。

**macOS 现状**：原生解码**还没实现**（桌面端可先用设备卡片的"网页"入口）；
可行性见 `docs/platform-feasibility.md`，macOS 的 `network.client` entitlement 已补。
在 Mac 上实现时请照上表第一列之外的两点做，并**第一件事就是截图确认画面**。

---

## 2. 技术栈与版本

| 项 | 版本 |
|---|---|
| Flutter | 3.47.1（stable） |
| Dart | 3.13.1 |
| drift / drift_flutter | ^2.35.0 / ^0.3.1（本机 SQLite 持久化；`*.g.dart` 由 build_runner 生成） |
| webview_all | ^1.4.3（Android / iOS / macOS / Windows / Linux 均有实现）|
| flutter_secure_storage | ^9.2.4（只存密码） |
| wakelock_plus | ^1.2.10（实际 1.5.2） |
| url_launcher | ^6.3.1 |

状态管理：**Flutter 内置 `ChangeNotifier` + `ListenableBuilder`**，未引入额外状态库；
依赖注入用 `lib/app/app_scope.dart` 里的 `AppDependencies` + `InheritedWidget`。

改过 drift 表结构 / 生成源之后要重跑：

```powershell
& 'C:\Users\Warren\Dev\flutter\bin\cache\dart-sdk\bin\dart.exe' run build_runner build
```


---

## 3. 常用命令

```powershell
# 依赖
& 'C:\Users\Warren\Dev\flutter\bin\cache\dart-sdk\bin\dart.exe' pub get

# 静态检查（三个目录都要过）
& 'C:\Users\Warren\Dev\flutter\bin\cache\dart-sdk\bin\dart.exe' analyze lib test tools

# 单元测试（复用层/控制消息/解析层/三态组件）
flutter test

# M0 协议探测（需要 Basic Auth 凭据）
$env:WS_PROBE_USER='<用户名>'; $env:WS_PROBE_PASSWORD='<密码>'
dart run tools/probe.dart

# 运行
flutter run -d windows      # 桌面（内嵌 WebView 走 webview_all；M2 后还可走原生协议层）
flutter run -d <android-id> # 手机（M1 网页壳可用）
```

### 3.1 Windows 构建前置（一次性）

`webview_all_windows` 的 CMake 每次构建都会执行
`nuget.exe install Microsoft.Web.WebView2 / Microsoft.Windows.ImplementationLibrary`。
该步骤依赖**可写的 `%TEMP%`**（nuget 要在 `%TEMP%\NuGetScratch` 建锁）与网络，
在受限环境里会以 `MSB3073 ... 已退出，代码为 1` 失败（且不打印 nuget 的真实报错）。

本项目已把这条链改成**完全离线、只写工作区、构建期不调用 nuget**：

1. `windows/CMakeLists.txt` 在 `include(generated_plugins.cmake)` 之前预置了 CMake 的
   `NUGET` 变量，指向 `tools/nuget_shim.cmd`（`find_program` 对已设置的变量是空操作，
   因此插件不会再去找/下载真正的 nuget）。
2. `tools/nuget_shim.cmd` 在构建时做两件事：`build\windows\x64\packages` 已就绪就直接放行；
   否则从 `.tmp\nuget-source\*.nupkg` 离线解包（`flutter clean` 只删 `build\`，不删 `.tmp\`，
   所以 clean 之后普通重建**无需任何手工步骤**）。缺包时给出可执行的修复提示。
3. `.tmp\nuget-source\` 里的两个 `.nupkg` 由一次性脚本准备（优先取本机 NuGet 缓存，不联网）：

   ```powershell
   tools\prepare_windows_deps.cmd      # 幂等；只在项目内写文件
   ```

   - 该脚本还会生成仓库根的 `NuGet.Config`（已被 `.gitignore` 忽略），把包源指向
     `.tmp\nuget-source`、把 `globalPackagesFolder` 重定向到 `.tmp\nuget-packages`；
   - 它自身调用 nuget 时会临时把 `TEMP`/`TMP` 指到工作区（nuget 5.10 不认 `NUGET_SCRATCH`）；
   - 因此**不需要把 nuget 放进 PATH**。
4. `windows/CMakeLists.txt` 末尾还有针对 VS 2026（MSVC 14.51）的协程弃用断言修补，**不要删**。


### 3.2 本会话（DSH）里启动 App 的注意点

DSH 沙箱下由工具链拉起的子进程写不了 `%TEMP%` 与 `%APPDATA%`，`flutter run` 会以
`_createDevFS: PathAccessException ... Temp (errno = 5)` 失败，界面里也会提示
`读取本地设置失败：PathAccessException ... com.example\ws_scrcpy_client`。

**首选：从普通终端（不受限）运行**，那里不需要任何额外配置。

受限会话里需要一个把临时目录与应用数据目录都放进工作区的启动器：

```powershell
tools\run_windows.cmd          # 等价于：TEMP/TMP→.tmp\ + --dart-define=WS_DATA_DIR=.tmp\appdata + flutter run -d windows
```

- `WS_DATA_DIR` 让 drift 数据库落到工作区（见 `lib/core/database/app_database.dart`）；
- 密码仍走系统安全存储；它在受限环境写不进去时会降级为"仅本次会话有效"并在界面提示；
- 构建（`flutter build windows`）**不受这些限制影响**，见 §3.1。


---

## 4. 目录结构与命名映射

文档 `FLUTTER_AGENT.md` §6 的骨架是"按技术分层"（`core/`、`video/`、`input/`、`ui/`），
实际实现按全局规范的 `common / core / feature` 三分层组织。映射关系：

| 文档骨架 | 实际位置 | 说明 |
|---|---|---|
| `core/ws_client.dart` | `lib/core/ws/`（`ws_url_builder`、`web_socket_transport`、`multiplexed_socket`、`multiplexer_message`、`reconnect_policy`、`ws_error_translator`） | 按能力拆成多个文件，避免单文件膨胀 |
| `core/multiplexer.dart` / `message.dart` / `channel.dart` | `lib/core/ws/multiplexed_socket.dart`（含 `MultiplexedChannel`）+ `lib/core/ws/multiplexer_message.dart` | 通道与消息拆两个文件 |
| `video/video_source.dart`、`fmp4_remuxer`、`native_decoder` | Android：`android/app/src/main/kotlin/.../ScrcpyVideoDecoder.kt`；Windows：`windows/runner/scrcpy_video_decoder.{h,cpp}` + `windows/runner/flutter_window.cpp`（通道）；Dart 侧共用 `lib/feature/stream/data/remote/native_video_decoder.dart`（M2 路线 A：Android / Windows） | 未做 fMP4 重封装：Android 走 `MediaCodec`，Windows 走 Media Foundation 解码器 MFT；Dart 侧只做平台分支，见 §11 / §12 |
| `input/control_messages.dart` | `lib/core/control/`（8 个文件） | 逐字节编码层，纯 Dart、无 Flutter 依赖 |
| `input/input_mapper.dart` | `lib/feature/stream/application/input/`（`video_viewport.dart` 坐标换算、`keyboard_mapping.dart` 键盘映射） | 纯逻辑、可单测；手势与焦点接线在 `player_page.dart` 的 `_VideoStage` |
| `settings/settings_store.dart` | `lib/feature/settings/`（`data/local` + `data/model` + `application/repository` + `application/service` + `presentation`） | 按 feature 分层 |
| —（新增） | `lib/core/database/app_database.dart`（+ 生成的 `app_database.g.dart`） | drift(SQLite) 表定义与打开；见 §7 |
| `ui/player_page.dart` | `lib/feature/stream/presentation/view/player_page.dart` | — |
| `ui/settings_page.dart` | `lib/feature/settings/presentation/view/settings_page.dart` | — |
| `ui/device_list_page.dart` | `lib/feature/device/presentation/view/device_list_page.dart` | — |
| `shell/webview_shell.dart` | `lib/feature/shell/presentation/view/webview_shell_page.dart` | — |
| —（新增） | `lib/core/stream/`（`display_info`、`video_settings`、`stream_initial_info`、`stream_target`） | 投流通道的协议模型，脚本与 App 共用 |
| —（新增） | `lib/common/`（`theme/`、`widget/`）、`lib/app/`（`app_scope`、`home_page`） | 设计 token、三态通用组件、依赖装配与跨模块导航 |

**跨 feature 依赖纪律**：`device` 只依赖 `settings` 的 **service**；
跨 feature 的页面跳转（设备列表 → 投流页）集中在 `lib/app/home_page.dart`，
feature 之间**不互相 import presentation/data**。

---

## 5. 与全局规范的有意偏差（逐条说明原因）

1. **`Result.failure(...)` 代替 `Result.error(...)`**
   全局规范示例里同时有实例字段 `error` 与静态工厂 `Result.error`，Dart 编译不过
   （"Class can't define static member and instance member with the same name"）。
   实例侧契约保持 `data` / `error` / `isSuccess` / `isError` 不变，只把构造入口改名为 `failure`；
   另有 `successVoid()` / `failureVoid(error)` 用于 `Result<void>`。

2. **内嵌浏览器统一走 `webview_all`，官方 `webview_flutter` 已弃用**
   官方 `webview_flutter` 只覆盖 Android / iOS / macOS，桌面端不够用，
   因此改用 `webview_all`（Android / iOS / macOS / Windows / Linux 均有实现）。
   Windows 上额外需要 NuGet 依赖与一处协程弃用断言修补（见 §3.1）。
   `BrowserFallbackView` 只在某平台实现初始化失败时兜底（例如缺 WebView2 运行时），
   不再是"Windows 不可用"的常规路径。

3. **触摸消息第 29 字节**
   文档 §2.4 写"共 29 字节"但字段只列到偏移 27；实测服务端 `Buffer.alloc(29)` 后
   只写前 28 字节，**偏移 28 恒为 0x00**，已在 `TouchControlMessage` 里用
   `trailingPaddingLength` 显式表达。

4. **`AppDefaults` / `AppBreakpoints` 放在 `lib/common/theme/app_tokens.dart`**
   该文件是**纯 Dart**（不 import Flutter），因此 data 层可以安全引用其中的协议默认值
   （如设备列表超时），不违反分层。

5. **文本消息长度用 utf8 字节数而非 JS 的 `text.length`**
   服务端 bundle 用 UTF-16 码元数，中文会少算；设备端按字节读，故客户端按字节写。
   依据见 `docs/ws-scrcpy-protocol.md` §6.3 第 2 条（需真实中文输入复验）。

---

## 6. 协议相关改动纪律

- 协议常量（`MessageType`、`Action`、`ChannelCode`、控制消息 type）**只能来自实测**：
  真实服务端 `bundle.js` 或 `docs/ws-scrcpy-protocol.md`，禁止凭记忆猜。
- 新增/修改协议后必须：① 更新 `docs/ws-scrcpy-protocol.md`；② 补/改
  `test/core/**` 的字节级断言；③ 用 `tools/probe.dart` 对真实服务端复验。
- `test/fixtures/` 里是从真实服务端抓下的报文（`device_list.json`、`stream_initial_info.hex`、
  `stream_first_video_frames.txt`），用 `WS_PROBE_WRITE_FIXTURES=1 dart run tools/probe.dart`
  重新采集，**禁止手改**。

---

## 7. 本地数据（drift/SQLite）与首次进入流程

**表**（`schemaVersion = 1`，`onCreate → createAll()`；drift 默认列名为 snake_case）：

| 表 | 列 |
|---|---|
| `connection_profiles` | `id` / `name` / `server_url` / `username` / `keep_screen_on` / `last_udid` / `is_active` / `created_at` / `updated_at` |
| `recent_devices` | `id` / `udid`(UNIQUE) / `display_name` / `last_connected_at` |

- **密码不在数据库里**：只存系统安全存储，键 `settings.password.<profileId>`。
  安全存储**写不进去**时不报错：密码留在内存（仅本次会话有效），
  `AppSettingsVo.passwordPersisted = false`，UI 据此提示"重启后需重填"；**读失败**按"没有密码"处理。
- **库文件位置**：`AppDatabase.databaseFileName = ws_scrcpy_client.sqlite`；
  目录优先取编译期常量 `WS_DATA_DIR`，否则 `getApplicationSupportDirectory()`，都会自动创建。
- **全局最多一个 active**：切换/删除/新建都在事务里维护这条不变量；
  删除 active 时把剩余配置里 `updated_at` 最大（同值取 `id` 最大）的一条提升为 active，
  没有剩余则 `hasAnyProfile() == false`。
- **首次进入**：应用启动先 `hasAnyProfile()`；为 false 时把
  `ProfileSetupPage(isFirstRun: true)` 当首屏（`lib/app/home_page.dart` 里判定），
  保存成功后切到设备列表。设置页可再新增/切换/删除配置。
- 改表结构必须：改 `app_database.dart` → 提升 `schemaVersion` 并补 `onUpgrade` →
  重跑 `build_runner build` → 补 `test/core/database/**` 断言。**禁止手改 `*.g.dart`**。

---

## 8. 网页投流（WebView 深链）

- 入口在**设备卡片**上（"网页"按钮），**不是**独立标签页：
  `lib/app/home_page.dart` 的 `_openWebStream` → `StreamTarget.webPlayerUri()` 生成深链 →
  以路由方式打开 `WebviewShellPage`（退出时 dispose 掉它的 viewmodel）。
- 深链参数逐条实测自服务端 bundle：
  `#!action=stream&udid=…&player=mse&secure=false&hostname=<设备IPv4>&port=8886&pathname=/&useProxy=true&ws=<内层 ws 地址>`；
  `player` 可选 `mse`（默认，Android WebView 兼容性最好）/ `tinyh264` / `webcodecs` / `broadway`。
- **Basic Auth 铁律（踩过坑）**：**不要**用 `loadRequest(headers: {'Authorization': …})` 预置凭据。
  那样页面本身能打开，但页面里 JS 自己发起的 WebSocket 不会带这个头 → 设备列表一直拉不到 →
  界面表现为**全黑**。必须让服务端发 401，交给
  `NavigationDelegate.onHttpAuthRequest` 应答（`WebViewCredential`），
  WebView 才会把凭据缓存到该 realm，后续请求（含 WS 握手）自动带上。
- 排查黑屏：JS 控制台消息、HTTP 状态（401/403）都已接到 `AppLogger`（tag `WebviewShellPage`）。
- 平台实现走 `webview_all`；初始化失败（如缺 WebView2 运行时）落到 `BrowserFallbackView`。

---

## 9. 已验证与遗留

**已端到端验证（2026-09-30）**：设备列表 → 投流连接 → 初始信息头 → 视频参数下发 →
**裸 H.264 视频数据**（SPS+PPS、IDR、P 帧；10 秒 295 条消息 / 1.2 MB）。

**曾经的误判（务必记住）**：早期探测"只收到反复重发的初始头、没有视频帧"，
被误判成服务端 `scrcpy-server` 未启动。真实主因是**探测脚本每收到一次初始头就回发一次
视频参数**，与服务端形成了反馈循环，编码器被反复重启。
排查顺序：先查自己的请求时序，再看服务端；判断"有没有流"要看**单位时间收到的字节数**，
只看"有没有视频帧"会被循环刷包骗过。详见 `docs/ws-scrcpy-protocol.md` §6.2。

**待做**：macOS / Linux 的原生解码（Windows 已跑通，做法见 §1.2 与 §12.8）；
M3 余项（剪贴板同步 `TYPE_GET/SET_CLIPBOARD`、软键盘文本注入 `TYPE_TEXT`、双指缩放等手势）；
`sendFrameMeta=true` 时每帧前 12 字节帧信息未验证（改走 fMP4 重封装才需要）；
应用标识仍是 `flutter create` 默认的 `com.example`（`android/`、`ios/`、`windows/runner/` 三处）。

---

## 10. M3 输入映射实现说明

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

- **坐标换算**（`video_viewport.dart`）：画面按 contain 居中，先算 `scale = min(view/video)`、
  再减黑边偏移，最后 `round()` 并 clamp 到 `[0, w-1]`；落在黑边上返回 null、
  不发送——投过去设备就会点到他不想点的地方。
- **触摸**：`Listener` 的 down/move/up/cancel → `TouchAction`；
  `pointerId` 直接用 Flutter 的 `event.pointer`（连接内唯一即可），因此天然支持多指；
  `ACTION_UP` 强制把压力置 0；鼠标事件额外带 `AndroidMotionEventButtons.primary`。
- **滚轮**：`onPointerSignal` → `ScrollControlMessage`，符号与服务端网页端一致
  （`delta>0` 记 `-1`，`delta<0` 记 `1`）。
- **键盘**：`Focus` + `onKeyEvent` → `KeyboardMapping`（字母 A=29…Z=54、数字 0=7…9=16、
  方向/确认/回车/退格/删除/Tab/空格/Esc/F1..F12），修饰键合成 `metaState`；
  **没覆盖的键返回 null 直接忽略**，绝不猜一个 keycode 发过去。
- 单测：`test/feature/stream/video_viewport_test.dart`（含横屏/竖屏/极端宽高比/黑边）、
  `keyboard_mapping_test.dart`、以及 `player_page_test.dart` 里"点画面正中 → 发出
  `type=2` 的触摸消息、坐标为视频中心、抬手压力为 0"的端到端断言。

---

## 11. M2 路线 A（Android 原生硬解）实现说明

```
WS 视频帧 ──► StreamSessionService.videoFrames ──► PlayerViewModel ──► MethodChannel
                                                                        │
                              android/app/src/main/kotlin/.../ScrcpyVideoDecoder.kt
                              MediaCodec(video/avc, 异步模式) ──► SurfaceProducer
                                                                        │
                              Flutter 侧 Texture(textureId) ◄────────────┘
```

- **一条 WS 消息 = 一帧 Annex-B**（实测）。只含 SPS/PPS 等非 VCL NAL 的那条按
  `BUFFER_FLAG_CODEC_CONFIG` 喂；含 1/5 号 NAL 的按普通输入喂。
- 解码跑在**独立 HandlerThread**（MediaCodec 异步回调），不阻塞 platform thread；
  等待队列超过 60 帧就丢最旧的帧，避免解码跟不上时内存无界增长。
- 真实分辨率以 `onOutputFormatChanged` 为准（投流中可能变化）→ `SurfaceProducer.setSize`
  + 反向通知 Dart（`onSizeChanged`），UI 用 `AspectRatio` 跟着调。
- **Dart 侧接口**：`NativeVideoDecoder`（`create/pushFrame/release` + `sizeChanges`；
  类名从 `AndroidVideoDecoder` 改名为平台无关，Android / Windows 共用同一份契约），
  `PlayerViewModel.textureId/videoSize/decoderError/retryDecoder`，
  `_VideoStage` 有纹理就渲染 `Texture`，否则显示占位与错误重试。
- **只在拿到 displayInfo 之后**才创建解码器并订阅 `videoFrames`：
  更早的帧由广播流丢弃，不会喂给未就绪的解码器。
- **横竖屏 / 窗口尺寸变化会自动重新适配**：
  - 原生路径：`_VideoStage` 用 `LayoutBuilder` 拿到可用区域 → `PlayerViewModel.applyViewportSize`
    → `StreamSessionService.applyViewportBounds` 下发 `bounds` 让编码按新尺寸输出
    （service 内对相同边界去重，避免旋转动画期间反复刷参数）；
  - 网页路径：页面里注入的脚本挂了 `resize`/`orientationchange`（防抖 350ms）重新点 `Fit`，
    Dart 侧再监听 `didChangeMetrics` 兜一次底。
- **底部快捷栏只放高频入口**：返回 / 主页 / 最近 / 更多（4 个），
  音量、电源、旋转、面板、断开都收进"更多"底部面板。
  早期版本把 8 个按钮平铺在底部，既挤画面又在横屏下容易溢出；
  面板本身用"紧凑按钮墙 + 可滚动"，因为投流页默认横屏、可用高度很小。
- 验证：`flutter build apk --debug` 通过（Kotlin 编译过），
  `test/feature/stream/stream_session_service_test.dart` 用真实报文夹具覆盖了
  "初始头只回一次参数 / 帧转发 / 控制消息走同一连接 / 视口边界去重"等管线行为，
  `test/feature/stream/player_page_test.dart` 覆盖了快捷栏布局、更多面板、
  原生解码就绪（渲染 Texture + 帧被喂进去）与创建失败（可读错误 + 重试）两条分支；
  **实机解码效果需要在设备上跑一次确认**（本机没有连设备）。

---

## 12. M2 路线 A（Windows 原生解码）实现说明

```
WS 视频帧 ──► StreamSessionService.videoFrames ──► PlayerViewModel
                                                      │ MethodChannel('ws_scrcpy/video')
                              windows/runner/flutter_window.cpp（create/pushFrame/release/getSize）
                                                      │
                              windows/runner/scrcpy_video_decoder.cpp
                              MF H.264 解码器 MFT（CLSID_CMSH264DecoderMFT）→ NV12
                                 ├─ GPU（默认，见 §12.8）：D3D11 上传 → 着色器转 RGBA → 共享纹理 → GpuSurfaceTexture
                                 └─ CPU（兜底，本节细节）：NV12→RGBA → flutter::PixelBufferTexture
                                                      │
                              Flutter 侧 Texture(textureId) ◄──────┘
```

- **一消息一样本**：`MFVideoFormat_H264` 的约定就是"每个样本一个完整压缩帧"
  （SDK `mfapi.h` 注释），与实测"一条 WS 消息 = 一帧 Annex-B"完全对齐；
  不设 `MF_NALU_LENGTH_SET`，样本按起始码解释。解码器用的是系统内置的 H.264 解码器
  MFT（`CLSID_CMSH264DecoderMFT`，软件 MFT、内部可能走 DXVA），**不是** `MFTEnumEx`
  枚举出来的硬件 MFT——想换硬解只要替换这一处创建逻辑。
- **线程模型**：`PushFrame` 只在调用线程上入队（platform thread 不做重活），
  解码 / NV12→RGBA 换算 / `MarkTextureFrameAvailable` 都在一个专用线程上串行执行；
  该线程自己 `CoInitializeEx(MTA)` + `MFStartup`（MF 要求 MTA，MFT 只在这一个线程上用）。
  队列上限 **60 帧**（与 Android 一致），超出丢最旧的帧，靠下一个关键帧重新同步。
- **纹理（CPU 兜底路；默认走 GPU 共享纹理，见 §12.8）**：从引擎的 plugin registrar 取
  `texture_registrar()`（`flutter_window.cpp` 的 `TextureRegistrarFor()`），用
  `flutter::PixelBufferTexture` 注册（CPU 缓冲路线）。引擎按 `GL_RGBA` +
  `GL_UNSIGNED_BYTE` 上传（`shell/platform/windows/external_texture_pixelbuffer.cc`），
  所以 CPU 侧写 RGBA 字节序，且返回描述符里的宽高才是纹理尺寸。
- **不撕裂、不悬空**：解码线程写自己的 `scratch`，整帧写完后在锁内与 `latest` 交换；
  raster 线程的回调在锁内把 `latest` **拷**进要交给引擎的那张缓冲
  （每帧多一次 memcpy，远小于 YUV→RGB 的换算量），然后发一张 **Grant**：
  Grant 用 `shared_ptr` 钉住那一帧，并把 `release_callback` 指成"删除自己"。
  这是官方契约里的所有权移交写法（引擎在 `TexImage2D` 之后立刻回调），
  因此**不会**出现"我们释放了缓冲、引擎还在读"的 use-after-free——
  这也是首跑崩溃里同族问题的第二处修法。
- **尺寸变化（已改为"回执 / 拉取"，不再反向推送）**：真实宽高只认解码输出类型的
  `MF_MT_FRAME_SIZE`；变化时重建缓冲 → `MarkTextureFrameAvailable`，并把新尺寸记进
  实现类内部加锁的 `SizeState`（对外只暴露 `ScrcpyVideoDecoder::CurrentSize()`）。
  投流中分辨率变化由解码器的 `MF_E_TRANSFORM_STREAM_CHANGE` 触发重新协商输出类型。
  **Dart 侧通过两条路拿到尺寸**：① `create` 与每次 `pushFrame` 的**回执**里带
  `{width,height}`（Dart 顺手更新，尺寸没变就不通知，避免每帧重建 UI）；
  ② `getSize` 主动拉一次（重建解码器之后、或 UI 需要立刻知道时）。
  曾经的 `onSizeChanged` 反向推送 + `PostPlatformThreadTask` **已整体删除**，
  原因见下面"0x58CA5 / 0x5AAE5 崩溃"一条。
- **释放路径**：`release` 方法与窗口销毁（`FlutterWindow::OnDestroy`）都调
  `ScrcpyVideoDecoder::Release()`，**可重复调用**；`OnDestroy` 的顺序是
  "置 `destroying_` 标记 → 停解码线程 + 注销纹理 → 显式摘掉通道 handler → 最后销毁
  controller（引擎）"，这样注销回调还能在引擎活着时跑完，也不会有捕获 `this` 的
  `std::function` 活过窗口。
- **参数集与失败恢复**：**先**把 SPS/PPS 作为 `MF_MT_MPEG_SEQUENCE_HEADER` 写进输入类型
  （`ReinitializeInputType`），让解码器在协商输出类型之前就知道真实分辨率——**不要**像
  早期实现那样"在喂入前就协商"，那时拿到的是默认类型（1920x1080），与真实码流不符。
  协商由三条路径触发：`ProcessInput` 的 `MF_E_TRANSFORM_TYPE_NOT_SET`、
  `ProcessOutput` 的 `MF_E_TRANSFORM_STREAM_CHANGE` / `TYPE_NOT_SET`、
  以及"喂够 `kOutputTypeNegotiationFrames` 帧还没协商出来"的兜底；
  连续 5 次 `ProcessOutput` 失败还会走 `ForceRenegotiate()` 自愈（见 §12.6）。
  COM / MF / MFT 建不起来的错误会在 `create` 阶段同步回给 Dart
  （可读文案 + 现有"重试解码"入口），不会变成永远黑屏。
- **色彩**：主路径 NV12，YV12 / IYUV 也能转（三种 4:2:0 都支持，含自下而上的负 stride）；
  固定按 **BT.601 视频范围**换算，暂未解析 SPS VUI 里的色彩空间/范围。
- **构建**：`windows/runner/CMakeLists.txt` 只加源文件与系统库
  （`mfplat` / `mfuuid` / `wmcodecdspuuid` / `ole32`），**没有新增 NuGet 依赖**，
  §3.1 的离线链路不受影响；因为要拿引擎的 `TextureRegistrar`，runner 额外链了
  `flutter_wrapper_plugin`（插件用的是同一套 registrar 机制）。
  runner 的 C++ 带中文注释，编译选项里显式加了 `/utf-8`（见本节最后一条），
  因此**不再依赖"文件必须带 BOM"**。
- **性能（实测数据，不是估计）**：`tools\run_nv12_bench.cmd` 直接链接真实的
  `yuv_to_rgba.cpp` 量过（本机 x64）：

  | 分辨率 | Debug(/Od) 换算 | +memcpy 合计 | Release(/O2) 换算 | +memcpy 合计 |
  |---|---|---|---|---|
  | 1280×720 | 4.14 ms/帧 | 4.23 ms | 1.61 ms | 1.71 ms |
  | 1898×853 | 7.26 ms | 7.43 ms | 2.80 ms | 2.99 ms |
  | 1920×1080 | 9.55 ms | 9.79 ms | 3.59 ms | 3.84 ms |

  结论：**换算不是瓶颈**——Debug 下 720p 也只占单核 12.7%（30fps），1080p 是 29%；
  那次"整帧 memcpy"只值 **0.09–0.25 ms（2–5%）**。因此 ① 把换算写进引擎缓冲以省掉 memcpy、
  ② SIMD/SSE2 版换算，**经数据判定不做**（收益 <5%，却要重新引入刚修完的跨线程/所有权风险）。
  **但 ③ D3D11 零拷贝当初也被一起判成"不做"，那条是错的**——它漏量了每帧整帧 RGBA 的
  **上传与锁竞争**，已在 **§12.8** 实施（GPU 共享纹理路）。
- **实机首跑崩溃的根因（越界读）与修法**：首跑表现为 debug 下"卡死"后进程结束、
  release 下直接崩；Windows 事件日志给出 `0xC0000005`（调试版）/ `0xC0000409`
  （发布版，CRT 的 fastfail），两者都是"内存越界"的签名。根因在 YUV→RGBA 之前那步的
  **长度校验**：旧实现用 `pitch * height * 3 / 2` 判断解码输出缓冲够不够，
  **奇数高度时整数除法会把 UV 平面的最后一行截掉**（真实需要 `ceil(height/2)` 行），
  于是最后一行的 UV 读越界——用户日志里的高度正是奇数 853。
  修法：把换算抽成不依赖 Media Foundation 的纯函数 `windows/runner/yuv_to_rgba.{h,cpp}`，
  由它按平面布局 + `ceil(height/2)` 自己算真实需求，**不够就拒绝整帧**（返回 false，
  一个字都不写）；跨距改成"只信解码器真正用的那个"：优先 `MF_MT_DEFAULT_STRIDE`，
  其次 `MFGetStrideForBitmapInfoHeader`，最后才退回宽度，**不再假设 pitch == width**。
  另外顺手修掉一处同族的 use-after-free：像素缓冲改用官方契约的
  `release_callback`/`release_context` 做所有权移交（每帧一张 Grant，内部用 shared_ptr
  钉住那一帧），这样注销回调释放缓冲时引擎也不会读到已释放内存。
  **本机可跑的验证**（没有真机也能给出证据）：
  - `tools\run_yuv_test.cmd` → 普通 `/Od` 与 AddressSanitizer 各跑一遍边界自测
    （padding 跨距、奇数宽高、1x1、半个 UV 平面、目标容量差一字节、自下而上、
    2400 组随机组合 + 输出缓冲容量），当前 **9653 项检查 0 失败**；
  - 同一个自测带 `--reproduce-old-bug`：把旧逻辑原样复刻后用 ASan 跑，
    **预期并被证实**报 `heap-buffer-overflow ... READ of size 1`——这就是根因证明；
  - `tools\run_mf_probe.cmd`：确认解码器 MFT 的输出样本归属（实测
    `PROVIDES_SAMPLES = no`，所以"自己给输出样本"的写法是**对的**，不要改；
    `cbSize = 4147200` @1920x1080，取 `max(frame_bytes, cbSize)` 也是对的）。
- **runner 的 C++ 不再依赖 BOM**：`windows/runner/CMakeLists.txt` 加了 `/utf-8`。
  以前靠"必须存成 UTF-8 with BOM"规避 C4819（源码里有中文注释 + `/W4 /WX`），
  但编辑器/自动改写工具会把 BOM 吃掉，构建就会莫名失败——现在与 BOM 无关。
- **解码器的日志必须同时写 stderr**：`DebugLog` 原来只走 `OutputDebugStringA`，
  在 `flutter run` 的控制台里完全看不见（只有调试器能看），实机首跑因此全程静默。
  现在两边都写，并用 `LogOnce` 打"已解出第一帧 / 引擎已取走第一帧 / 拒绝某帧"这类
  一次性关键节点——排查运行期问题先看这几行。
- 验证：`flutter build windows --debug` 与 `--release` 均通过（C++ 真编译 + 链接，
  exe 里能看到通道名 `ws_scrcpy/video`、方法名 `create/pushFrame/release/getSize`、
  `模块已加载`、`通道入口：`、`心跳：已解码` 等新日志锚点；
  **`onSizeChanged` 已经不在二进制里**——这就是"反向推送被删干净"的证据）；
  `dart analyze lib test tools` 无问题；`flutter test` 全过（**206 通过 / 1 skip**，
  其中 `native_video_decoder_test.dart` 的 9 条覆盖"回执/拉取尺寸 + 尺寸去重 + 老契约兼容"，
  `player_page_test.dart` 有"Windows 且解码器就绪 → 渲染 Texture + 帧被喂进去"
  与"'更多'面板里唤醒开关默认关且能打开"的断言，
  `stream_session_service_test.dart` 覆盖"首发只发一条且带 UI 最终尺寸 / 回显服务端值 /
  UI 尺寸晚到的兜底路径 / 未连接时上报尺寸不算失败 / 唤醒默认关且只发一次"）。
  **本机没有真实设备与 ws-scrcpy 服务端**：越界与内存安全已用 ASan 自测覆盖，
  但画面/色彩/性能仍需真机复验；首跑重点看：是否有画面、红蓝是否颠倒（RGBA 字节序）、
  旋转后分辨率是否跟着变、以及 CPU 占用。

### 12.1 `0xC0000005` 崩溃（偏移 0x58CA5 / 0x57255 / 0x5AAE5）

**已修**（完整证据链见 `docs/windows-decoder-history.md`）：跨线程投递出去的尺寸回调任务
活过了它捕获的状态。修法是把"推送"换成"回执 / 拉取"（`create`/`pushFrame` 回执 + `getSize`），
`PostPlatformThreadTask` 那条路径整体删除。教训：**跨构建比地址没有意义**（要用当次 exe 反汇编）；
"日志文件没被创建过"不能证明崩溃点靠前（那版根本没写日志）。

### 12.2 原生日志：路径、时间戳格式、心跳与警告、下次要看哪几行

日志实现集中在 `windows/runner/decoder_log.{h,cpp}`（platform thread 与解码线程共用一份，
保证时间基准一致 + 串行写文件）。

- **文件路径**：优先 **exe 同目录** `scrcpy_decoder.log`；写不进去退
  `%TEMP%\scrcpy_decoder.log`；都失败就只走 `stderr` + `OutputDebugStringA`。
  单文件上限 **2 MB**，超过就地截断重开。
  每次运行启动时会打一条 `日志启动，文件=<实际路径>`，**先看这一行就知道日志在哪**。
- **时间戳格式**：每条都是 `[YYYY-MM-DD HH:MM:SS.mmm | +Nms | pid=NNN] 模块名: 正文`
  （壁钟含毫秒 + 相对"模块首次写日志"的毫秒数 + **进程号**）。三条出口都写，
  **文件每条 flush**（进程崩了也留得下最后一条面包屑）。pid 的用途见 §12.4：
  日志文件是追加写的，多实例记录混在一起时**先按 pid 分组再读**。
- **心跳（用户要求"要监控时间，不然卡死都不知道"）**：解码线程约每秒一条。
  **字段口径必须分清**（含糊过一次，见 §12.5）：
  - `帧间隔`：两次发布之间的间隔，**由服务端给帧的节奏决定**（30fps 就是 ~33ms）；
  - `平均处理`：出队 → 发布的整帧耗时（**我们自己的开销**），并拆成 `解码`（MFT）+ `换算`；
  - `本帧处理` / `本帧换算`：最近这一帧的瞬时值；
  - `收到` / `已喂入` / `已发布` / `丢弃`：Dart 推入 → 喂进 MFT → 换算成功 → 丢弃；
  - `尺寸(初始)`：configure 时按 displayInfo 定下、并用于创建像素缓冲的尺寸；
    `尺寸(最后一帧)`：解码器输出类型真正给出的尺寸（首帧解出前是 `0x0`）。
  样例：

  ```
  [2026-10-01 11:13:05.393 | +22844ms | pid=3716] ScrcpyVideoDecoder: 心跳：收到 512，已喂入 512，已发布 512，丢弃 3，队列深度 0，帧间隔 33ms，平均处理 12ms（解码 8ms + 换算 4ms），尺寸(初始)=1280x720，尺寸(最后一帧)=1280x720，本帧处理 11ms，本帧换算 4ms，ProcessOutput 失败 0（最近 S_OK），ProcessInput 失败 0，流格式变化 0 次，强制重新协商 0 次，结束=否
  ```

  **怎么用这张表判断"卡"在哪**：
  - `帧间隔` >> `平均处理` → **服务端没给帧**（编码器正在重建、画面无变化、或流已停）；
    客户端侧到此为止，去查设备/服务端编码侧（黑屏的正解见 §12.5）。
  - `帧间隔` ≈ `平均处理` 且两者都大 → 我们这条链路慢，看 `解码` 与 `换算` 谁占大头。

- **警告（同样落文件）**：
  - 距上一帧超过 **5000ms**（阈值从 3000ms 提到 5000ms，措辞也改成把"画面无变化"放在最前面：
    scrcpy **只在画面变化时发帧**，静止时"没有帧"是正常的，以前 3 秒就喊 WARNING，
    用户点完按钮看到的第一条就是"服务端没给帧"，像个报错——被问过一次）：
    ```
    [.. | +20123ms] ScrcpyVideoDecoder: WARNING 距上一帧已 15000ms（阈值 5000ms）：**最常见的原因是设备画面这段时间没有变化**（scrcpy 只在画面变化时发帧，属正常现象）；其次才是编码器重建中 / 流已停。队列深度 0，尺寸(初始)=1280x720，尺寸(最后一帧)=1280x720，收到 0，已发布 0
    ```
  - 单帧间隔超过 **1000ms**，样例：
    ```
    [.. | +25123ms] ScrcpyVideoDecoder: WARNING 单帧解码过慢：1420ms（阈值 1000ms，指两帧之间的间隔），尺寸(最后一帧)=1280x720，队列深度 7
    ```
  - 两种情况都按 `kWarningRepeatMs`（2 秒）抑制重复，异常不会刷屏但也不会只报一次。
- **create 各阶段耗时**：启动时一条汇总
  （`create 各阶段耗时（相对模块首次写日志）：COM 初始化=…ms，MFStartup=…ms，
  创建 MFT=…ms，configure=…ms，注册纹理=…ms，注册通道方法=…ms`），
  另外每一步还有自己的单条日志。
- **首帧链路锚点**（按出现顺序 grep 这些词）：
  `模块已加载` → `通道入口：create` → `create 完成：textureId=` →
  `首个 pushFrame 到达` → `通道入口：pushFrame 第 N 帧` → `首个样本喂入` →
  `首次输出类型协商完成` → `首次换算成功` → `首次 MarkTextureFrameAvailable` →
  `已解出第一帧并发布`；尺寸变化是 `尺寸变化…：AxB → CxD`；拒绝帧是 `拒绝一帧解码输出`；
  流格式变化是 `解码器报告流格式变化（第 N 次，上一次输出 WxH）`；
  自愈触发是 `连续 5 次 ProcessOutput 失败（第 N 次强制重新协商）`。
- **下次真机运行后请把这些发回来**（按顺序）：
  1. **`日志启动，文件=…`**（确认日志落在哪、有没有退到 `%TEMP%`）；
  2. **`模块已加载`** —— 没有它 = exe 根本没跑到 `OnCreate`，与解码器无关；
  3. **`通道入口：create` / `create 完成：textureId=…`** —— 有 `模块已加载` 但没有它
     = 崩在 Dart 侧或通道派发之前；
  4. **`create 各阶段耗时：…`** 这一整行（看是不是某一步（通常是"创建 MFT"）特别慢）；
  5. **`通道入口：pushFrame 第 30 帧…` 起的前几条 + 第一条 `心跳：…`** ——
     有 create 但没有首帧 = 崩/卡在解码器内部；
  6. **最后一条 `心跳：…` / 任何 `WARNING …`** —— 崩溃或卡死前的最后状态
     （`帧间隔`、`队列深度`、`平均处理`、`收到`）；
  7. **`警告/崩溃前 5 行`** 整段原文（不要只发一行，日志是按时间排的）。
- **心跳参数在哪调**：`windows/runner/scrcpy_video_decoder.cpp` 文件顶部的
  `kHeartbeatInterval`（心跳间隔，默认 1 秒）、`kHeartbeatStallWarningMs`（5000ms）、
  `kHeartbeatSlowDecodeWarningMs`（1000ms）、`kHeartbeatTimingWindow`（平均耗时的帧数 N=60）、
  `kWarningRepeatMs`（2000ms）。日志文件上限 `kLogFileMaxBytes` 在
  `windows/runner/decoder_log.cpp`（2 MB）。
- **引擎 stderr 落到 `engine_stderr.log`，且重定向有安全铁律（真机踩过，2026-10-01）**：
  为了离线读引擎报错（`Could not create external texture` 那类），`main.cpp` 把引擎 stderr
  复制到 exe 同目录 `engine_stderr.log`。**第一版写法直接把应用搞崩**：
  `SetStdHandle` + `_wfreopen_s(stderr, …)` 在从 VS 以 "Windows (desktop)"（**没有控制台**）
  启动时失败，之后任何一句 stderr 写都命中
  `Debug Assertion Failed! … lowio\write.cpp(50)
   Expression: (fh >= 0 && (unsigned)fh < (unsigned)_nhandle)` —— 一启动就弹断言框。
  **三条铁律别再犯**：① 用 `_open_osfhandle` + `_dup2(fd, 2)` 做 CRT 层重定向（fd 2 必有效）；
  ② 任何一步失败就**什么都不改**；③ 写 stderr 前用 **`GetStdHandle`** 判断可用性，
  **不要用 `_fileno`/`_get_osfhandle`**——它们对失效 fd 自己就会断言（自测证实）。
  回归自测：`tools\run_stderr_redirect_test.cmd`（GUI 子系统 = 无控制台、每个探针独立进程；
  `freopen-fail-then-write` 在 Debug CRT **预期断言**，`redirect-then-write` 必须不挂且标记落盘）。

### 12.3 本机可跑的验证（四条自测 + 一条编译检查）

- `tools\run_d3d11_present_test.cmd`：**GPU 呈现路**——NV12 重排的字节级断言 + 着色器数值与
  CPU 参考实现逐像素比对 + **跨设备共享句柄**（模拟引擎/ANGLE 的 `OpenSharedResource`），
  普通 + ASan 各一遍，**检查项 61 / 失败 0**（细节见 §12.8）。
- `tools\check_runner_compile.cmd`：`/W4 /WX /utf-8` 下把全部 runner 源文件编译一遍；
  受限沙箱里 `flutter build` 起不来（工具链子进程管道被拒）时，用它当编译门禁。
- `tools\run_yuv_test.cmd`：YUV→RGBA 边界自测 + **输出缓冲容量**（普通 + ASan），
  **9653 项检查 0 失败**（含 §12.6 新增的容量用例）。
- `tools\run_pixel_store_test.cmd`：像素缓冲所有权（Grant / `release_callback` /
  尺寸变化 / `Clear` 与在用 Grant 并存 / 解码线程与 raster 线程并发）+ **日志机制**
  （文件真的被创建、每条真的 flush 到盘、2 MB 真的会截断），普通 + ASan 各一遍，
  当前 **executed=18，检查项 89，0 失败**（脚本里有 `executed >= 6 && checks >= 40`
  的断言，防"空跑型假绿"；并且每次强制全量重建，因为 MSVC 增量构建在这个仓库里
  出现过"exe 时间戳是新的、代码却是旧的"）。
  本机受限沙箱**不允许把正在被日志句柄持有的文件再打开读**，所以"内容/时间戳格式"
  这一项在本机只验证到元数据层面（脚本会明确打印"未在本机验证"），
  真机运行时请人工看日志前几行。
- `tools\run_nv12_bench.cmd`：NV12→RGBA 换算基准（`/Od` 与 `/O2` 各一遍，直接链接
  真实实现）。**它自己踩过两个 bug，不要再回退**：
  ① 旧版照抄了一份老逻辑，而自己按 `w*h*3/2` 申请缓冲 → 1898x853（奇数高）读越界，
  进程以 `0xC0000005` 退出且块缓冲把已算出的行也丢了（表现为"没有输出"）；
  ② 它的 memcpy 基准写成 `memcpy(rgba, nv12, rgba.size())`，而 NV12 只有 RGBA 的 3/8 大
  → 每次多读 2 MB 越界。现在缓冲按 `ceil(h/2)` 算、memcpy 用同尺寸源、每行 `fflush`，
  `pitch` 故意取 16 对齐（贴近解码器的真实对齐跨距）。
  **教训**：诊断工具也要有自己的边界校验，而且**不要维护第二份业务逻辑**——
  链接真实实现才能保证量的是真东西。

### 12.4 "点投流立刻提示窗口正在销毁"（`destroying_` 未复位）

**已修**（完整证据链见 `docs/windows-decoder-history.md`）：`Win32Window::Create()` 第一句就是
`Destroy()` → 我们的 `OnDestroy()` 把 `destroying_` 置真且**从不复位**，于是之后每一次通道调用
都被判成"窗口正在销毁"。修法：`OnCreate` 里 `destroying_.exchange(false)`；`OnDestroy` 先判断
有没有东西可收尾（没有就直接返回、不动标记）；错误码区分 `window_destroyed` / `window_not_ready`；
日志前缀加 pid。教训：多实例日志**先按 pid 分组**，"日志里的顺序 ≠ 代码里的顺序"。

### 12.5 实机"进去黑屏 / 点一下才有反应 / 非常卡"

**已修**（完整证据链见 `docs/windows-decoder-history.md`）：黑屏真因是**视频参数下发方式**——
连发两条 `CHANGE_STREAM_PARAMETERS` + 不回显服务端给的 `VideoSettings`，服务端因此两次重建编码器
且不会立刻给 IDR。修法：首发只发一条且带 UI 最终尺寸、逐字段回显服务端值（只覆盖 `bounds` 与
`sendFrameMeta:false`）；自动唤醒默认关（它**不是**黑屏的正解）。
"非常卡"的归因已被 §12.7★修正 与 §12.8 推翻：不是换算，而是**像素路上 CPU 整帧搬运 + 队列延迟**。

### 12.6 `ProcessOutput 0x80004005` 洪水 + "270 帧只解出 1~2 帧"

**已修**（完整证据链见 `docs/windows-decoder-history.md`）：两个缺陷叠加——① 在喂样本**之前**
协商输出类型，选到默认的 `1920x1080`（真实码流 1280x720）→ 每次 `ProcessOutput` 都失败；
② 复用输出样本时没清 `CurrentLength`。修法：输出样本每轮现造（`MakeOutputSample`）、
先把 SPS/PPS 写进输入类型再协商、连续 5 次失败走 `ForceRenegotiate()` 自愈、
缓冲容量统一用 `ValidateYuv420Source`、失败日志限流、心跳补 `ProcessOutput 失败` 计数。

### 12.7 帧率低 / 首帧慢 / 时快时慢：**不要向服务端索要放大**

**现象（真机，pid=3260）**：画面能出来，但**首帧要等很久**、帧率只有个位数且抖动、
输入响应时快时慢。同一设备在**网页端流畅**。

**决定性数据（同一次运行）**

| 指标 | 实测 | 含义 |
|---|---|---|
| 我们单帧开销 | **6 ms**（解码 ~0 + 换算 5–6） | **客户端不是瓶颈** |
| `帧间隔`（服务端给帧节奏） | **53–166 ms**，偶发 3000ms+ | ≈ **6–19 fps**，抖动大 |
| 我们发的 `bounds` | **1898×853**（UI 视口） | 设备原生只有 **1280×720** → **要求放大 1.77 倍像素** |

容器里的软编码器被要求"放大 + 高码率"编码，扛不住 → 首帧慢、帧率低、节奏抖。
**规则：`bounds` 永远不许超过设备原生分辨率。** 放大是**显示层**的职责
（客户端已有 `Texture` + `AspectRatio` 缩放），不该让被控设备多编像素。

**实现**（`lib/feature/stream/application/service/stream_session_service.dart`）

- `clampBoundsToNative({viewport, native})`：`scale = min(1, min(native.w/viewport.w, native.h/viewport.h))`，
  按比例收敛到原生范围内；视口本来 ≤ 原生时**保持不动**（也不上抬到原生，避免白烧编码）。
  `native` 来自初始信息头的 `displayInfo.size`。
- `_sendVideoSettings(...)` 里对 `bounds ?? base.bounds` 一律过一遍它——注意**服务端自己给的
  `bounds` 也可能大于原生**（夹具里是 `1856x960`），所以两条来源都要收敛；收敛时打日志说明。
- 单测：`test/feature/stream/stream_session_service_test.dart` 覆盖
  "视口 1898x853 → 收敛"、"服务端给 1856x960 → 同样收敛"、"视口 ≤ 原生时不动"、
  "等比（不变形）"。当前 `flutter test` **213 通过 / 1 skip**。

**服务端没给 `VideoSettings` 时的回落**（同一次运行里出现了 `服务端初始头给的 VideoSettings：null`）：
`fallbackVideoSettings` **照抄网页端 `VideoSettings` 的默认构造**，bundle 原文：

```
this.bitrate=0; this.bounds=null; this.maxFps=0; this.iFrameInterval=0;
this.sendFrameMeta=!1; this.lockedVideoOrientation=-1; this.displayId=0
```

**因此 `maxFps: 0` 不是我们的发明**——网页端也这么发（曾经把它当成"帧率低"的嫌疑犯是**误判**，
已纠正）。以前我们自己塞的 `bitrate 8000000 / iFrameInterval 10` 才是"我们自己编的值"，
已删除，改为逐字段回显服务端 / 按上表回落。

**验收（下次真机运行）**：
1. 日志里 `请求的编码边界 … 超过设备原生 … 收敛为 …` 出现且**收敛值 ≤ 1280×720**；
2. 心跳 `帧间隔` 明显下降（目标 ~33ms ≈ 30fps）、`已解码/已发布` 持续增长；
3. 体感：首帧快、画面连续、输入跟手。

**教训**：①"我们不慢"要用数据说清（6ms vs 53–166ms），否则会在客户端白折腾；
②向服务端要什么，**逐字段对齐网页端**——它是同一协议下已验证可用的参考实现。

**★ 重要修正（后续真机数据推翻了本节上面的归因）**

三方对比（决定性）：网页端 = 浏览器 GPU 解码 + GPU 合成 → **丝滑**；Android = `MediaCodec →
SurfaceProducer`（GPU 直写纹理）→ **没问题**；Windows = MF 解码 → **CPU 转 RGBA → memcpy →
引擎上传 + 互斥锁** → **~10fps、间歇停帧**。
①"服务端只给 10fps"是**错的**（Android 与 Windows 跑同一份 Dart、同一套参数）；
②日志里 `收到 143` 之后十几秒不涨而**队列深度恒为 0** ⇒ 不是解码慢（慢会堆队列），
是客户端这一侧不再推进；③根因是**架构不对称**——每帧整帧 RGBA 的**上传与锁竞争**
（当初的性能基准只量了 CPU 换算，漏掉了这两项，所以"SIMD/D3D11 不做"的结论被推翻）。
修法见 §12.8（GPU 呈现路 + 队列收到 4 帧 + 诊断计数）。

### 12.8 Windows 投流"又卡又延迟"：三个独立原因 + GPU 呈现路（已实施）

**现象（用户原话）**："windows 端投流高延迟，android、web 都很流畅，不可能 windows 就做不到。"
补充事实（决定性）：同一台 Windows 机器上，**手动开浏览器访问 `android.DORKYTIGER.top` 的网页端是流畅的**，
App 内嵌 WebView 也"不算差"。

**这条事实的价值**：它一次性排除了"网络 / 服务端编码 / 这台 PC 的 GPU 合成能力"——
网页端在同一台机器上跑的就是 GPU 解码 + GPU 合成。**唯一与 Android/网页不同的，是我们自己的
"解码输出 → 上屏"这一段。**

#### 三个独立原因（必须分开修，别混在一起）

| # | 原因 | 为什么 Android/网页没有 | 修法 |
|---|---|---|---|
| 1 | **像素路上 CPU 整帧搬运** | Android 是 `MediaCodec → SurfaceProducer`（解码器直接写 GPU 纹理）；网页是浏览器 GPU 解码 + GPU 合成。Windows 却是 MF 解出 NV12 → **CPU 整帧转 RGBA** → 每帧整帧交给引擎 `glTexImage2D`（720p **3.7MB/帧**、1080p 8.3MB/帧，上传发生在**光栅线程**上） | 新增 **GPU 呈现路**（本节主体）：CPU 只做 NV12 重排 + 上传（720p **1.4MB/帧**），换算交给像素着色器 |
| 2 | **排队把延迟放大** | Dart 侧 `unawaited(pushFrame)` 无上限在途 + 原生队列上限 **60 帧 ≈ 2 秒**；Android 产能够、队列恒空，所以同一份 Dart 代码不卡 | 队列上限 **60 → 4 帧**（≈130ms）；新增"队列等待"心跳，把延迟变成可观测数字 |
| 3 | **引擎 present 节奏不可控** | Flutter 引擎经 ANGLE 合成，present 队列深度我们控制不了（原生栈才可能） | **未解决**（1+2 修好后延迟已与 Android 同级；只有要压到"1 帧管线"才需要换栈） |

#### GPU 呈现路的设计（`windows/runner/d3d11_video_presenter.{h,cpp}`）

```
WS 帧 → MF H.264 解码器 MFT → NV12（系统内存，含跨距）
      → PackNv12：按行重排成 D3D11 要的紧凑布局（Y 平面 + UV 平面，行跨距 = 物理宽）
      → UpdateSubresource 上传（720p 1.4MB；NV12 纹理要求偶数宽高，奇数尺寸向上对齐）
      → 像素着色器（BT.601 视频范围，整数定点，**与 yuv_to_rgba.cpp 逐位一致**）画出 RGBA
      → R8G8B8A8_UNORM 共享纹理（DXGI 共享句柄 + keyed mutex）
      → flutter::GpuSurfaceTexture(kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle) → Flutter Texture
```

- **像素格式只能用 RGBA8888**（真机实测，第二轮）：按 `B8G8R8A8_UNORM` + `kFlutterDesktopPixelFormatBGRA8888`
  建纹理时，引擎每帧刷 `[ERROR:embedder_external_texture_gl.cc(170)] Could not create external texture`
  ——引擎 DLL 里紧跟其后的那行字符串就是原因：**`Only support GL_RGBA8 format now`**。
  着色器本来就写 `(R,G,B,A)` 到 `SV_Target`，对 RGBA8 目标字节序天然正确，数值不用改。

- **为什么用共享句柄而不是 `kFlutterDesktopGpuSurfaceTypeD3d11Texture2D`**：那一种要求纹理建在
  **引擎自己的 D3D11 设备**上，而引擎没有暴露取设备的 API（本机 SDK 头文件里没有）；
  共享句柄是"我们自己的设备 + 引擎跨设备打开"，插件生态（如 camera_windows）走的就是这条。
- **句柄类型选"传统 `IDXGIResource::GetSharedHandle`"**：三条本机证据都指向它——
  ① `flutter_texture_registrar.h` 的枚举注释直接链接 `idxgiresource-getsharedhandle`；
  ② `flutter_windows.dll` 里编进了 `external_texture_d3d.cc`，其邻近报错串是 ANGLE 的
  `Binding D3D surface failed.` / `-Failed to open share handle, ` /
  `Failed to query ID3D11Texture2D object from share handle.`（ANGLE 走传统
  `ID3D11Device::OpenSharedResource`）；③ 本机自测**用第二个 D3D11 设备成功打开**了我们的句柄。
- **同步默认 keyed mutex（key 0）**：写入前 `AcquireSync(0, 100ms)`、写完 `ReleaseSync(0)`；
  超时就**丢掉这一帧**（宁可掉帧也不把解码线程堵死）。这组 key 与 ANGLE 共享句柄路径的约定一致，
  也兼容"引擎不取锁"的情况（那时我们是唯一持有者）。
- **尺寸变化**：物理尺寸向上对齐到偶数（`1898x853 → 1898x854`），真实尺寸通过描述符的
  `visible_width/height` 告诉引擎；重建纹理会换新句柄，旧纹理进 `retired_` 列表保留几帧
  （引擎"打开句柄"可能晚于下一次回调，句柄在打开前必须有效——`flutter_texture_registrar.h` 的硬要求）。
- **CPU 路完整保留为兜底**（D3D11 建不起来 / 远程桌面 / 驱动异常），两条路对 Dart 侧的契约
  完全一样（textureId + 尺寸回执），Dart 不需要知道走了哪条。

#### 出问题时的一分钟 A/B（环境变量，不用重编译）

| 变量 | 默认 | 作用 |
|---|---|---|
| `WS_SCRCPY_GPU=0` | 开 | 完全回退 CPU 像素缓冲路 |
| `WS_SCRCPY_GPU_SYNC=none` | `keyed` | 共享纹理不带 keyed mutex（排查"引擎取锁与我们不一致"） |
| `WS_SCRCPY_GPU_HANDLE=nth` | `legacy` | 改用 `IDXGIResource1::CreateSharedHandle`（NTHANDLE） |

#### 本机验证（不需要真机与服务端）

- `tools\run_d3d11_present_test.cmd`（普通 + ASan 各一遍）：**检查项 61 / 失败 0**，
  6 组 GPU 帧与 CPU 参考实现**逐像素相等**（含 1898x853 奇数高、stride=1344），
  并用**第二个 D3D11 设备**打开我们的共享句柄（引擎/ANGLE 走的同一条 API）。
- `tools\run_pixel_store_test.cmd`（executed=18 / 89 项 / 0 失败）、
  `tools\run_yuv_test.cmd`（9653 项 / 0 失败，含 ASan 复刻旧 bug 仍如期报 `heap-buffer-overflow`）。
- `tools\check_runner_compile.cmd`（`/W4 /WX /utf-8` 编译门禁）、
  `tools\run_d3d11_adapter_probe.cmd`（共享句柄跨适配器矩阵）、
  `tools\run_mft_replay_probe.cmd`（12 种解码驱动方式对比）。


#### 第二轮真机（2026-10-01 14:07）：0 帧 —— 根因是**编码边界没对齐 16**（细节见 docs 历史）

`解码器可用输出类型` 只有默认 `1920x1080` + `已发布 0` + `流格式变化 0 次`。
对照同一天**成功出帧**的会话（下发 `1280x720` / `992x560`，都 16 对齐）与失败那次
（`1280x575`）⇒ **非 16 对齐尺寸会让容器编码器产出 MF 解不出来的码流**（网页端不发 `bounds` 所以没事）。
修法：`clampBoundsToNative` 收敛后**向下对齐到 16**（`1898x853 → 1280x560`），绝不上抬。
（顺序修正只是 67 vs 64 的**正确性改进**，不是那次 0 帧的根因。）


#### 真机第三次（2026-10-01 14:13）：GPU 共享纹理路**全黑** → 默认关闭（细节见 docs 历史）

现象：`已解码 67 / 已发布 67 / 丢弃 0 / 光栅回调 154`，但屏幕**全黑**。
机制（已实测，`tools\run_d3d11_adapter_probe.cmd` 打印打开矩阵）：
本机有 **NVIDIA + Intel + Basic Render** 三块适配器，我们的 D3D11 设备建在 NVIDIA 上，
而引擎 ANGLE 多半在 Intel；**传统 DXGI 共享句柄不能跨适配器打开**（实测同适配器 3/3 OK、
跨适配器 **0/6**）⇒ 引擎拿不到纹理 ⇒ `Could not create external texture` ⇒ 黑屏。
**处置**：`WS_SCRCPY_GPU` 默认 **false**（走 CPU 像素缓冲路），要看 GPU 路显式 `WS_SCRCPY_GPU=1`，
并用 `WS_SCRCPY_GPU_ADAPTER=intel|nvidia|<索引>` 选与引擎同一块适配器；
引擎自己的报错写在 exe 同目录 `engine_stderr.log`（`main.cpp` 的重定向，见 §12.2 末尾）。
**教训：`已发布 N 帧` ≠ 上屏成功，日志全绿也可能是黑屏。**


#### ★ 真机第四次（2026-10-01 下午）：全黑 + 周期性卡几秒的真正根因（结论见 §1.2）

**根因（一行代码）**：MF 的 H.264 解码器 MFT **默认缓冲约 1.2 秒（30fps ≈ 38 帧）才吐第一张图**；
必须显式 `IMFAttributes::SetUINT32(MF_LOW_LATENCY, TRUE)`（开始流之前）。
它同时解释：画面静止时只来二十来帧 → **永远黑屏**；有操作时先黑 1~3 秒；
编码器一重建就再攒一批 → **"时不时卡几秒然后一次性追平"**；网页端无此缓冲所以一直流畅。

**离线证据（`tools\run_mft_replay_probe.cmd` + 真实抓包 43 帧）**：12 种驱动方式全试过
（协商顺序、输入类型带 SPS 尺寸、`MF_MT_FRAME_SIZE`、时间戳三种、取事件、重复调 ProcessOutput、
关硬件加速、不喂参数集、重复喂 IDR 预热、`COMMAND_DRAIN`）——**只有低延迟模式真正解决**：

```
不设 MF_LOW_LATENCY ：已发布  8/43 帧，首帧在第 38 帧
设   MF_LOW_LATENCY ：已发布 42/43 帧，首帧在第  1 帧   ← 唯一有效
COMMAND_DRAIN       ：首帧第 1 帧但之后不再产出（drain 后必须 flush，而 flush 丢参考帧）
```

**真机验证（本机自动投流 + 自己截屏）**：`MF_LOW_LATENCY 设置结果=0x00000000` →
`流格式变化（第 1 次）→ 992x560` → `已发布 22/23、平均处理 4ms、光栅回调 21` → **画面正常显示**。
两个坑写在 §1.2 后面：属性要用 `GetAttributes` 取；`CODECAPI_AVLowLatencyMode` 不支持。


#### 诊断与验收（第四轮后已收敛）

- 起手先看三行：`低延迟模式：MF_LOW_LATENCY 设置结果=`（必须是 `0x00000000`）、
  `呈现路径：CPU 像素缓冲`（默认；GPU 路要显式 `WS_SCRCPY_GPU=1`）、
  心跳里的 `已发布 / 已喂入`（应接近 1:1，`已发布 ≪ 已喂入` = 解码器在憋）。
- **`已发布` 涨但 `光栅回调` 不涨** = 卡在引擎侧（上传/合成）；两者都不涨 = 帧没到（服务端/网络）。
- 离线工具（不需要设备与用户）：`tools\run_mft_replay_probe.cmd [抓包]`、`run_mft_negotiate_probe.cmd`、
  `run_d3d11_adapter_probe.cmd`、`run_stderr_redirect_test.cmd`、`run_d3d11_present_test.cmd`。


#### 遗留与下一步

- MF 目前仍解到**系统内存**再上传 NV12（每帧 1.4MB）。再进一步就是给解码器配
  `IMFDXGIDeviceManager`（`MFCreateDXGIDeviceManager` + `MFT_MESSAGE_SET_D3D_MANAGER`）让它
  **直接输出 D3D11 纹理**，把这次的上传也省掉——属于优化，不是修 bug，**要先有数据说它值**。
- Android 侧同样是"每帧一次 MethodChannel `pushFrame`"，但走 SurfaceProducer，**不需要改**；
  这次只动 Windows 的呈现段与两处延迟/诊断。
- 教训：①**对照参考实现**（同一台机器上的浏览器）能一步定位"哪一段不一样"，比对着现象猜省一个数量级；
  ②"高延迟"要先拆成"吞吐 / 排队 / present 节奏"三件事再动手，否则会在客户端白折腾；
  ③诊断计数要**跨层对齐口径**（Dart 发起/完成、原生收到/已发布/光栅回调），否则拿到数字也判不出来。

---

## 13. 在 macOS 上继续开发（Windows 已跑通，Mac 从这一节读起）

**平台无关的部分直接照用，不用改**：协议层、投流会话、输入映射、UI、
以及 `NativeVideoDecoder` 的 MethodChannel 契约（`ws_scrcpy/video` 的
`create / pushFrame / release / getSize` + 每次 `pushFrame` 回执里带 `{width,height}`）——
Dart 侧已经按平台分支，见 `lib/feature/stream/data/remote/native_video_decoder.dart`。

**Dart 侧唯一要改的一处**：`lib/feature/stream/presentation/viewmodel/player_viewmodel.dart`
（约第 93 行）目前只放行 `TargetPlatform.android` / `TargetPlatform.windows`，把 macOS 加进去。

**原生侧照 Windows 的结构一一对应**：

| Windows（已实现） | macOS 对应物 |
|---|---|
| `windows/runner/scrcpy_video_decoder.{h,cpp}` | 新建 `macos/Runner/ScrcpyVideoDecoder.swift` |
| `flutter_window.cpp` 里注册通道 | `macos/Runner/MainFlutterWindow.swift` 里注册**同一个通道名** |
| MF H.264 解码器 MFT | **VideoToolbox `VTDecompressionSession`** |
| `MF_LOW_LATENCY`（§1.2，最容易漏） | **`kVTDecompressionPropertyKey_RealTime = true`** |
| 解出 NV12 → CPU/GPU 上屏 | `CVPixelBuffer`（NV12/BGRA）→ `FlutterTexture.copyPixelBuffer` 回传 |
| `PixelBufferTexture` / D3D11 共享纹理 | `FlutterTextureRegistry.register` + `textureId` |

**上屏最省事的第一版**：解码输出类型给
`kCVPixelBufferPixelFormatTypeKey = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`，
在 `copyPixelBuffer` 里把 Y/UV 平面拷进一块 BGRA 缓冲交给引擎。
**先跑通再谈零拷贝**（Windows 那轮的教训：先有数据再说值不值）；
后续可以走 `CVPixelBuffer` → `CVMetalTextureCache` → Metal 纹理省掉这次拷贝。

**签名 / entitlement**：`macos/Runner/*.entitlements` 的 `network.client` 已补（投流要联网）；
VideoToolbox 不需要额外 entitlement，但 **Debug 与 Release 两个 entitlements 文件都要看一眼**。

**验证方法（照 Windows 那套，别信日志）**：macOS 上截图是 `screencapture -x shot.png`；
**先确认画面出来**，再看计数。心跳口径保持一致：
`已发布 / 已喂入` 接近 1:1；`已发布 ≪ 已喂入` 就是"解码器在憋"（回去看 `RealTime` 有没有设上）。

**验收**：① 首帧立刻出（不是 1~3 秒后）；② 画面静止时不黑、不隔几秒跳一下；
③ `screencapture` 截到的图里确实有设备画面。

