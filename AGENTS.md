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
- ✅ M2 路线 A：**iOS / macOS** 原生硬解（VideoToolbox `VTDecompressionSession` → `CVPixelBuffer` →
  `FlutterTexture`；两端**共用同一份** `darwin/ScrcpyVideo*.swift`）。
  两端都已实跑并**自己截图确认画面上屏**（iOS 模拟器 2026-10-02；macOS 本机同日、用户也验过），见 **§15**
- ⏳ M2 路线 A：Linux 原生解码
- ⏳ M3 余项：剪贴板同步、软键盘文本注入、双指缩放等手势增强

### 1.1 交接：当前状态与下一步（新会话从这里读起）

**能用了**：设备列表 → 投流 → Windows 原生解码 → 画面 + 触摸/滚轮/键盘输入。
Android 端同样可用（MediaCodec 路线）。真机日志验证过 `已发布 332/370 帧`、`ProcessOutput 失败 0`。
**iOS 端（2026-10-02）也能用了**：VideoToolbox 路线，已在 iOS 模拟器上连真实服务端截图确认
画面清晰上屏（`1184x672`、`已喂入 12 / 已解出 12`、`丢弃 0`）——见 §15。

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

**已知未做**：Linux 原生解码；**iOS 只在模拟器上验证过、还没上真机**（要过签名，见 §15.6）；
剪贴板同步、软键盘文本注入、双指缩放；
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
| **macOS / iOS** | VideoToolbox（`VTDecompressionSession`） | **`kVTDecompressionPropertyKey_RealTime = true`**。**不要**顺手设 `kVTDecompressionPropertyKey_MaximizePowerEfficiency`——头文件原文写着"两者同设是未定义行为"，而它默认就是 false，不设才对（可行性文档 §3.1.4 那条建议与头文件冲突，已纠正）。 | **实测（iOS 2026-10-02）：Apple 侧没有 Windows 那种缓冲**——`RealTime` 默认就是 true，探针跑 true / false / 完全不设三种都是 90/90 帧全解（`tools/run_vt_replay_probe.sh`）。但仍要显式设一次并记返回码，日志里能自证 |
| Android（已实现） | `MediaCodec` | 已经是实时模式（SurfaceProducer），**无需改** | — |

**判断方法（不依赖肉眼）**：看心跳里 `已发布 / 已喂入` 的比例。
**`已发布 ≪ 已喂入` 就是"解码器在憋"**（Windows 上实测：不设开关 8/43、设了 42/43）。
**注意：`已发布 N 帧` ≠ 画面上屏** —— 日志全绿也可能是黑屏；上屏问题必须**自己截图确认**。

**离线验证入口**：`tools\run_mft_replay_probe.cmd [抓包]` 会同时打印"不设 / 设低延迟"两种结果，
谁把这里改坏会立刻暴露（抓包用 `WS_CAPTURE_FRAMES` 或 exe 同目录放 `ws_capture.txt`）。

**macOS 现状（2026-10-02 已完成，细节见 §15）**：`darwin/` 里那份 VideoToolbox 代码两端共用，
macOS 侧**只写了注册那一层**（`macos/Runner/MainFlutterWindow.swift`，见 §15.8）。
本机实跑 + 自己截图确认画面上屏；用户也试过。**注册纹理走的是一条就成**：
`flutterViewController.registrar(forPlugin:).textures`（不像 iOS 那条要兜底，见 §15.3）。

**iOS 现状（2026-10-02 已完成，细节见 §15）**：这一端额外踩到两个和 Windows 不同类的坑：
① **`applicationRegistrar.textures()` 注册纹理返回 0**（隐式引擎 + Scene 生命周期下那个 relay 的
parent 是 weak，还没接上宿主视图）→ 必须退到 `FlutterViewController` 注册，见 §15.3；
② **`NSLog` 进不了 `flutter run` 的控制台** → 必须同时 `print`，见 §15.4。

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


### 3.3 macOS 上做 iOS（本次新增）

Windows 那套 `.cmd` 在这里用不了；macOS 上的对应命令：

```bash
export PATH="/opt/homebrew/bin:$HOME/Dev/flutter/bin:$PATH"   # pod 在 homebrew 里

flutter pub get
dart analyze lib test tools
flutter test

# iOS 编译（不需要签名；真机才需要）
flutter build ios --debug --no-codesign

# 在模拟器上自动投流 + 自己截图（凭据只走命令行，不落仓库文件）
flutter run -d <simulator-udid> \
  --dart-define=WS_BOOTSTRAP_URL=https://<服务端>/ \
  --dart-define=WS_BOOTSTRAP_USER=<用户名> \
  --dart-define=WS_BOOTSTRAP_PASSWORD=<密码> \
  --dart-define=WS_SCRCPY_AUTOSTART=1
xcrun simctl io booted screenshot shot.png     # ← 上屏必须自己截图确认
xcrun simctl spawn booted log show --last 3m \
  --predicate 'eventMessage CONTAINS "ScrcpyVideo"' --style compact   # 原生日志

# VideoToolbox 离线探针（不需要设备/服务端，链接真实解码器）
tools/run_vt_replay_probe.sh
```

**三条 macOS 特有的注意点**：

1. **CocoaPods 必须装**（`brew install cocoapods`）：`flutter_secure_storage` 还不支持
   Swift Package Manager，Flutter 会对它回退到 CocoaPods；没有 pod 时
   `flutter build ios` 直接以 `CocoaPods not installed or not in valid state` 结束。
   其余插件走 Flutter 3.47 默认开启的 SPM（`ios/Flutter/ephemeral/Packages/`）。
2. **`WS_BOOTSTRAP_*` 是本次为"能自动跑"加的**（`lib/core/debug/debug_bootstrap.dart`）：
   `WS_SCRCPY_AUTOSTART` 读的是 `Platform.environment`，而 iOS 应用进程**拿不到宿主环境变量**，
   所以这条必须走 `--dart-define`。模拟器上也没法可靠地手填首次进入的表单，没有它就没法自动化验证。
   **默认关闭**（不传 `WS_BOOTSTRAP_URL` 时什么都不做）。
3. **`--dart-define` 的值会被编进产物**（`kernel_blob.bin` / `app.dill`）。用真实密码跑完记得
   `rm -rf build .dart_tool/flutter_build`，别把带凭据的构建产物留在盘上。


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

**待做**：**Linux** 的原生解码（Windows / Android / iOS / macOS 都已跑通）；
**iOS 只在模拟器上验证过，还没上真机**（真机要过签名，见 §15.6）；
M3 余项（剪贴板同步 `TYPE_GET/SET_CLIPBOARD`、软键盘文本注入 `TYPE_TEXT`、双指缩放等手势）；
`sendFrameMeta=true` 时每帧前 12 字节帧信息未验证（改走 fMP4 重封装才需要）；
应用标识仍是 `flutter create` 默认的 `com.example`（`android/`、`ios/`、`windows/runner/` 三处）。

---

### 9.1 ★ 触摸"点几下就点不回去了"：**黑边上丢掉 UP，把设备端的手指卡住了**（已修）

**用户的两次描述**：
① "似乎现在只能触控主页返回这些，中间屏幕内容点不了"；
② "**滑动几下**，或者点击安卓任务窗口，再点击里面的任务……**一开始可能可以，试几次就点不回去了**"。
③ 补了一条决定性的：**macOS 上没问题，只有 iOS 有问题**。

**②③ 两条合起来基本就把范围锁死了**，因为：

- 设备端（`scrcpy-server` → Android `InputDispatcher`）是**按 `pointerId` 记**"这根手指是否还按着"的。
  只要有一根手指只收到 `DOWN`、没收到 `UP`，设备就**一直认为它按着**；
  之后**复用同一个 pointerId** 的 `DOWN` 会被直接丢弃 —— 而 Flutter 会反复复用同一批 id，
  于是**所有单指操作**都失效，看起来就是"点不动了"。（这就是"一开始可以、几次之后不行"的签名；
  如果是报文/坐标错，会**从第一次就稳定失败**。）
- **只有 iOS 够得着这个 bug**：`_VideoStage` 的 `Listener` 铺满整个控件，而视图层原来对
  "落在黑边上"的事件**一律不转发**（`point == null` 就 `return`）——**UP 也一起被吃掉**。
  - macOS：窗口是宽的 → 画面铺满宽度、上下黑边只有十几像素 → 滑动几乎不会滑出去 → **碰不到**；
  - iOS 竖屏：画面只占控件高度约 **1/3**（1184x672 的画面装进 402x664 的控件里只有 ~228 高）
    → **滑动几乎必然滑出画面** → 必现。
  用户说的"滑动几下"正是最容易触发的动作，而"点任务窗口里的任务"也常常点到画面边缘。

**修法**（两处，都在共享 Dart 层，因此 Android / Windows 同样受益）：

1. 新增 `lib/feature/stream/application/input/touch_pointer_tracker.dart`——
   **DOWN/UP 配对状态机**，规则逐条对照服务端网页端的 `buildTouchOnClient` + `validateMessage`：
   - `DOWN`：该 id 已按下 → 丢弃（重复 DOWN 会让设备多按一根手指）；落黑边 → 丢弃（没成立）；
   - `MOVE`：该 id 没按下 → 丢弃（**不**像网页端那样补一条"模拟 DOWN"，凭空造点击更糟）；
     落黑边 → **补一条 UP 释放**（网页端也是这么做的）；
   - `UP`/`CANCEL`：没按下 → 丢弃；否则**一定发出**，落黑边就用**最后一次有效坐标**兜底，
     **绝不因为落点不合法而吃掉 UP**。
2. `_VideoStage._sendTouch` 不再对 "`point == null`" 直接 `return`，而是把 `null` 交给状态机；
   断线时 `PlayerViewModel` 清空指针状态（重连后设备端是干净会话，本地陈旧状态只会误判）。

**回归测试（两个层次，都验证过"改回老代码就变红"）**：

- `test/feature/stream/touch_pointer_tracker_test.dart`：9 条纯逻辑用例，含
  "按下在画面内、抬起落黑边 → 仍要发 UP"、"MOVE 滑出画面 → 立刻补 UP"、
  "连续 N 次点按之后仍能发 DOWN"；
- `player_page_test.dart`：两条**真手势**端到端用例（`startGesture` + `moveTo` 到画面外），
  断言"消息序列里 DOWN 与 UP 必须一一配对"。**把 `_sendTouch` 改回老的"遇黑边就 return"，
  这两条立刻失败**——这就是它们能当门禁的证据。

**留给真机的验收**（iOS 上我这边没有辅助访问权限，点不了模拟器，所以这条靠你复验）：

1. 在投流页**反复滑动**（故意划过黑边），然后点画面里的内容 —— 应该一直有点；
2. 走一遍原路径：快捷栏"最近" → 出现的任务窗口里点一个任务 —— 应该能切回去；
3. 如果**仍然**点不动，那说明 `buttons` 那条也成立：服务端对**触摸事件**固定发
   `buttons = BUTTON_PRIMARY(1)`（`formatTouchEvent` 里写死的），而我们对非鼠标指针发 `0`。
   这条当时没验证（属于"要用实验判定"而不是"靠读代码判定"），是下一个候选。

**仍然排除掉的（都有依据，别再查一遍）**：

- **报文格式没问题**：把服务端 `bundle.js` 拉下来对比过，它的 `TouchControlMessage.toBuffer()`
  与我们的 `lib/core/control/touch_control_message.dart` **逐字节一致**
  （含 `writeUInt32BE(0)` 那个 pointerId 高位、29 字节里偏移 28 的零填充）；
- **`screenSize` 语义没问题**：服务端 `buildTouchOnClient()` 里 `new ScreenSize(n, o)` 用的就是
  **视频尺寸**，坐标也是按 contain 换算成视频像素——与我们的 `VideoViewport` + `PlayerViewModel.sendTouch`
  （`screenWidth/Height = _videoSize`）完全同构；
- **`Listener` 接线没问题**：`_VideoStage` 用 `HitTestBehavior.opaque` 包住画面，
  且"点画面正中 → 发出 `type=2` 触摸消息、坐标为视频中心"的用例一直是过的；
- 快捷栏能通 ⇒ 连接、控制消息通道、`sendControlMessage` 都正常。

**教训**：这类"**只在某个平台、某个窗口形状下出现**"的问题，第一件该看的是
"**两个平台之间哪个输入条件不一样**"——这里是**黑边占控件的比例**（macOS ~2% vs iOS ~66%）。
用户那句"macOS 没问题、只有 iOS 有问题"是整轮排查里信息量最大的一句。

---

### 9.3 ★★ Web 端（分支 `2-web-client`）：**浏览器不给 WebSocket 加自定义请求头** ★★

**这一条是整个 web 端最硬的平台约束，先看它再看别的**，因为它会直接改变产品形态。

**背景**：用户说服务端自带的网页版 UI 很难看，想自己做一套 web 端。分支 `2-web-client`。
"能用先，UI 后期再说"。

#### 实测到的第一手事实（不是推测）

| 事实 | 证据 |
|---|---|
| `flutter build web --release` **能过**，14.9s | 产物 41MB；`web/` 目录本来就有（`flutter create` 生成的） |
| 但打开是**白屏**，**原因不是我们的代码** | 静态服务器日志里 `main.dart.js`、字体都下了，**`canvaskit.wasm` 一次都没请求**。build config 带 `engineRevision`，Flutter 默认从 **gstatic.com** 拉 CanvasKit；沙箱出网受限→永远白屏。**加 `--no-web-resources-cdn` 后正常** |
| 白屏 → **灰屏** = 引擎起来了但 widget 树没产出 | 灰是 release 下抛异常的样子。定位到 `AppDependencies.create()` **同步**调 `AppDatabase.open()`，而 `app_database.dart` import 了 `dart:io` |

**为什么"编得过"却"跑不起来"**：`dart2js` 对 `dart:io` 提供的是
**能编译、一调用就抛**的桩实现。`dart:io` 只出现在 4 个文件里，全在启动路径上。

#### ★ 核心约束：web 上拿不到 Basic 凭据

原生端握手时带 `Authorization: Basic ...`，**浏览器没有这个能力**（`WebSocket` 构造器不收 headers）。
服务端 bundle 我反查过：它是 `new WebSocket(url)`，**全文没有任何 auth 处理** ——
它靠的是"页面本身就从那个受保护的源站加载"，所以**页面加载时浏览器已经挑战过一次**、
把凭据缓存到了该 realm，之后（含 WS 握手）自动带上。

**我们的页面是从别的源站（如 `127.0.0.1:8765`）提供的**，没有那次页面级挑战，
于是每一次 WS 握手都是一次未认证请求 → 401 → 浏览器弹一次登录框。
用户报的"**每次点击都要 basic auth**"就是这个。

**逐条修法**：

1. **web 上只走服务端代理地址**（`StreamTarget.candidateUris` 用 `isWebPlatform` 分流）：
   设备直连地址（`192.168.x.x:8000`）与服务端入口**不是同一个 origin**，
   浏览器会为它**单独**弹框；而公网入口下那些内网地址本来也不可达 ——
   每试一个就白弹一次，这是"每次点击都要"的放大器。
2. **错误文案改成"告诉你该怎么办"**：`ws_error_translator.dart` 里先做一次
   **平台中立**的判定（两端异常类型完全不同：原生 `WebSocketException`，
   web `WebSocketChannelException` 包 DOMException），web 上给的是
   `browserAuthHint`（提示在弹出的框里输入一次账号密码并勾选"记住密码"）。
3. **★ 真正的解药是部署方式**：把我们 `build/web` 的产物**挂在 ws-scrcpy 服务端同一个源站下**
   （例如 `https://android.dorkytiger.top/app/`）。那样页面加载本身就会触发**一次**
   挑战，浏览器把凭据缓存到该 realm，之后**所有 WS 握手全静默** —— 和它自带网页版一模一样。
   从 `127.0.0.1:8765` 这种跨源地址访问，**至少弹一次是免不了的**。

#### 为了跑起来做的改造（原生侧一行行为没变，241 项测试全过）

- `lib/core/database/database_executor{,_io,_web}.dart`：`app_database.dart` 里彻底去掉
  `dart:io` / `path_provider`，打开方式改成**条件导出**按平台分派。
  **web 上继续用 drift**（WASM 后端），**不写第二套存储** —— 表结构与 DAO 两端共用。
- `lib/core/ws/web_socket_transport{,_io,_web,_connect}.dart`：接口保持纯 Dart，
  io 实现用 `dart:io`（带 `Authorization` 头），web 实现用 `web_socket_channel`（**忽略该头**）。
- `lib/core/platform/platform_capabilities{,_io,_web}.dart`：`core` 不许 import Flutter，
  所以不用 `kIsWeb`，用条件导出定死一个 `const bool isWebPlatform`。
- `device_list_page.dart` 的 `Platform.environment` 用 `!kIsWeb &&` 短路保护
  （`dart:io` 的 `Platform.environment` 在浏览器里会直接抛）。
- `tools/prepare_web_deps.sh`：把 `sqlite3.wasm` + `drift_worker.js` 从**本地 pub 缓存**
  拷进 `web/`（**不进仓库**，`.gitignore` 已加）—— 与 `tools/prepare_windows_deps.cmd`
  是同一个套路。**注意 drift_dev 2.35 已经没有 `make-web-worker` 子命令了**，
  `drift_worker.js` 是 drift 包**自带编译好的**。

#### 第二轮：用户实测"每次点击都要 basic auth + 报错"，查出两件事

**① 服务端没有任何非交互鉴权路径**（curl 实测）：401 是 **openresty（nginx）** 发的
（`www-authenticate: Basic realm="Authentication"`），不是 Node 应用层；
响应里**没有 Set-Cookie**，也没有 query/token 形式的凭据 —— 所以 web 上
只能走"浏览器代管 Basic 凭据"这一条路，没有捷径。

**② "每次都弹"是被自动重连放大的**（这才是我们自己的锅）：
认证失败 → 立刻重连 → 又一次未认证握手 → 再弹一次 → …… 无限循环。
修法见 `isAuthFailure()`（`ws_error_translator.dart`）+ `StreamSessionService._handleFailure`：
**鉴权失败直接进 `failed`，停掉自动重连**，把提示与「重试」交给用户。
回归测试两侧都钉住了（鉴权失败不重连 / 普通失败照常重连），并做过 A/B（去掉修复立刻变红）。

顺带把"误导用户"的两处也改了：

- **web 上不显示密码输入框**（`ProfileSetupPage` 里 `if (!isWebPlatform)`）：
  浏览器不给 WebSocket 加请求头，填了也用不上 —— 让用户白填一次密码，
  正是他问"为什么还要我再登录一次"的来源。原生端保留（有测试守着）。
- `tools/build_web.sh`：一条命令打包（`--no-web-resources-cdn` + 可传 `--base-href`），
  方便按上面的"同源部署"挂到服务端 `/app/` 下。

#### 已知未解决（下次接着做）

- **中文字在浏览器里显示成方块**：Flutter web 的 CJK 回退字体要从 `fonts.gstatic.com` 按需下载
  （沙箱取不到就变豆腐块）。正常有网的浏览器没问题；**内网/离线部署要自带 CJK 字体**。
- ~~**阶段二（解码上屏）还没开始**~~ → **2026-10-07 已实现，见 §17**（WebCodecs + canvas
  平台视图）。服务端 bundle 里的 `WebCodecsPlayer` 之前就证明了**不用做 Annex-B→AVCC**
  （不传 `VideoDecoderConfig.description` 就是 Annex-B 输入），我们照这条走。
- **验证手段受限**：我这边没有辅助访问权限，点不了浏览器也点不了模拟器，
  只能"构建 + 静态服务器 + `screencapture` 看首屏"；**交互验证要靠用户**。

---

### 9.2 ★ 画面适配与横屏布局（2026-10-02，用户看到横屏截图后要求改）

**用户原话**："现在触屏没啥问题了，但是横屏布局要改一下，而且这个设备大小，不能更改是吗，
就是做不到设备屏幕自适应"。

#### 先把"自适应"说清楚：两件事，只有一件真做不到

| | 能不能 | 为什么 |
|---|---|---|
| 改**被控设备**的显示分辨率 | ❌ | 1280x720 是 redroid 容器的显示设置，客户端改不了。而且我们**故意**不向设备要更大的编码尺寸——`clampBoundsToNative` 把 `bounds` 卡在原生以内，让容器里的软编码器放大编码正是 Windows 那轮"卡成幻灯片"的根因（§12.7）。**能要的只有"更小"，那只会更糊。** |
| 改**本地显示**方式 | ✅ | 见下面两种填充模式 |

**黑边是怎么来的**：设备是 **16:9**，iPhone 18 Pro **横屏**去掉顶栏（56）和快捷栏（64）后
画面区只有 **874x282 ≈ 3.1:1**。按比例装进去 → 高度顶满，宽度只用 **501/874**，
左右各 **186** 的黑边 —— **43% 的宽度是浪费的**。这是比例失配的必然结果，不是 bug。

#### 两个改动（用户选的"A + B 都做"）

**A. 横屏布局：把浪费的横向空间换成画面的高度**

原来横屏也是"顶栏 + 底部快捷栏"，402 点里被 UI 吃掉 **120 点（30%）**。现在：

```
横屏：Row[ Expanded(Stack[画面, 顶栏浮层]), 竖排快捷栏 ]   ← 顶栏默认收起
竖屏：Scaffold(appBar) + Column[画面, 横排快捷栏]            ← 原样不动
```

画面从 **501x282** 变成约 **715x402**（高度撑满）——**像素 +104%，而且不裁切、不变形**。
实测断言：`player_page_test.dart` 里"横屏…画面撑满可用高度"要求
`videoRect.height > 屏幕高度 * 0.9`。

**顶栏为什么不是"点画面唤出"**：画面上的点击是**要发给被控设备的**，
同一个手势不能既操作远端又开关本地 UI。所以留了一个**常驻半透明小圆钮**（左上角）唤出，
顶栏本身是浮层（盖在画面上），收起后一点高度都不占。

**B. "铺满"显示模式（`VideoFitMode`：contain / cover）**

- 只影响**本地渲染与坐标换算**，**不改任何编码参数**（设备那边该编多少还是多少）。
- **渲染与触摸必须是同一套变换**：画面改成 `FittedBox(fit: contain/cover)` 画，
  坐标换算用 `VideoViewport(fit:)` 算，两边的比例都来自 `videoSize`——
  以前渲染是手写 `AspectRatio`、换算是另一份公式，**一旦加 cover 就会两边不一致、点哪都偏**。
- cover 的几何：`scale` 取**较大**的比例、`offsetX/Y` 变**负数**（画面比控件大），
  `contains()` 恒真（被裁掉的部分只是"点不到"，不是"点位非法"）。
- 入口两处：横屏顶栏里的图标按钮 + **"更多"面板里的"铺满屏幕"开关**（竖屏时唯一入口）。

#### ★ 溢出：真机截图里那条 `BOTTOM OVERFLOWED BY 3.9 PIXELS`

**横屏下溢出的是两处**，都修了：

1. **"更多"面板**：`showModalBottomSheet` 默认把高度压到屏幕的 **9/16**，
   面板里的固定内容（标题 + 两行开关 + 分割线 + 断开按钮）超了，
   里面那层 `Flexible + SingleChildScrollView` 兜不住。
   → 改成 `isScrollControlled: true` + **整个面板一层滚动**（永远不可能溢出）。
2. **画面占位**（`_VideoPlaceholder`）：AppBar + 快捷栏之后只剩 ~280 点，装不下那堆状态文案
   —— **真机首帧到达前就能看到**。→ 改成"放得下居中、放不下滚动"
   （`LayoutBuilder` + `SingleChildScrollView` + `ConstrainedBox(minHeight)`）。

**★ 默认的 800x600 测试画布测不出这类 bug，必须显式把画布摆成横屏手机**
（`874x402`、DPR 3，并且**要加底部安全区** `FakeViewPadding(bottom: 21*3)`，
否则面板那条复现不出来）。两条回归测试都做过 A/B：**改回老结构 → 红，修复版 → 绿**。
（占位那条老代码溢出 28px；面板那条只有加上安全区才复现。）

#### macOS 上"密码只本次会话有效"（`-34018`）：**已修**，见 §16.1

`flutter run/build` 出来的 macOS debug 包是 **ad-hoc 签名**（`CODE_SIGN_IDENTITY = "-"`，
实测 `TeamIdentifier=not set`），而 `flutter_secure_storage_macos` 9.x 默认走
**data protection keychain**（`kSecUseDataProtectionKeychain = true`）——那个钥匙串要求
进程带 `keychain-access-groups` / `com.apple.application-identifier` 授权，**只有
provisioning profile 能给**，于是每次写入都返回 `-34018 errSecMissingEntitlement`。
按 §7 的设计这不会报错（密码留在内存），于是**下一次启动**看不到密码 →
**设备列表报"握手被拒绝"**，而 `curl -u` 却是 **200**。

**根因、修法与实测证据都在 §16.1**（一句话：`MacOsOptions(useDataProtectionKeyChain: false)`）。
另外那个应用数据目录在**沙箱容器**里，不在 `~/Library/Application Support/`：

```bash
rm -rf "$HOME/Library/Containers/com.example.wsScrcpyClient/Data/Library/Application Support/com.example.wsScrcpyClient"
```

另外**别指望用 `defaults write … "NSWindow Frame MainFlutterWindow"` 来改 macOS 窗口尺寸**
验证横屏布局——实测不生效（那个窗口没有 autosave name）。要肉眼看横屏，最省事的是
在 iPhone 模拟器里横过来（但 Xcode 27 的模拟器 UI 换成了 **DeviceHub**，
它不开可被 AppleScript 驱动的窗口，且 `osascript` 没有辅助访问权限时点不了）。
**结论：横屏布局靠 widget 测试里量几何（画面高度 / 快捷栏位置）来兜，别硬凑截图。**

---

## 10. M3 输入映射实现说明

```
手势/键盘 ──► _VideoStage（Listener/Focus）
                │  坐标用 VideoViewport 换算成视频像素（黑边上的点记作 null）
                ▼
        PlayerViewModel.dispatchTouch（TouchPointerTracker：DOWN/UP 配对）
                ▼
        PlayerViewModel.sendTouch（底层发送）
                ▼
        StreamSessionService.sendTouch / sendScroll / sendControlMessage
                ▼
        core/control 的 TouchControlMessage / ScrollControlMessage / KeyCodeControlMessage
```

- **坐标换算**（`video_viewport.dart`）：画面按 contain 居中，先算 `scale = min(view/video)`、
  再减黑边偏移，最后 `round()` 并 clamp 到 `[0, w-1]`；落在黑边上返回 null。
- **★ 配对状态机**（`touch_pointer_tracker.dart`）：落在黑边上**不等于**"这条事件可以丢"——
  `DOWN` 可以丢（这次按下没成立），但**已经按下的指针的 `UP` 一定要发出去**，
  否则设备端会一直认为那根手指按着，之后复用同一个 `pointerId` 的 DOWN 全被丢弃。
  详见 **§9.1**（这就是"点几下就点不回去了"的根因）。
- **触摸**：`Listener` 的 down/move/up/cancel → `TouchAction`；
  `pointerId` 直接用 Flutter 的 `event.pointer`（连接内唯一即可），因此天然支持多指；
  `ACTION_UP` 强制把压力置 0；鼠标事件额外带 `AndroidMotionEventButtons.primary`。
- **滚轮**：`onPointerSignal` → `ScrollControlMessage`，符号与服务端网页端一致
  （`delta>0` 记 `-1`，`delta<0` 记 `1`）。
- **键盘**：`Focus` + `onKeyEvent` → `KeyboardMapping`（字母 A=29…Z=54、数字 0=7…9=16、
  方向/确认/回车/退格/删除/Tab/空格/Esc/F1..F12），修饰键合成 `metaState`；
  **没覆盖的键返回 null 直接忽略**，绝不猜一个 keycode 发过去。
- 单测：`test/feature/stream/video_viewport_test.dart`（含横屏/竖屏/极端宽高比/黑边）、
  `keyboard_mapping_test.dart`、`touch_pointer_tracker_test.dart`（DOWN/UP 配对，9 条）、
  以及 `player_page_test.dart` 里"点画面正中 → 发出 `type=2` 的触摸消息、坐标为视频中心、
  抬手压力为 0"与两条"真手势滑出画面后 DOWN/UP 仍成对"的端到端断言。

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

- `clampBoundsToNative({viewport, native})`：**三步**——① 先把视口按**设备宽高比**收成框；
  ② `scale = min(1, min(native.w/框宽, native.h/框高))` 收敛到原生范围内；③ 向下对齐 16 宏块。
  `native` 来自初始信息头的 `displayInfo.size`。
  ⚠️ **第 ① 步是 2026-10-02 补的**（iOS 实测"画面糊"的根因）：服务端是"把画面按比例**装进**
  这个框"，框的比例跟设备不一致时紧的那一边会把分辨率压死——竖屏视口 1206x1992 对横屏设备
  1280x720，只做等比缩放得到 432x720 的竖框 → 服务端装进去只剩 **432x240**。
  **详见 §15.7**（含回归测试）。
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

**⚠️ 这一段的最后一句 2026-10-07 被推翻了**（保留原文以便看清楚当时错在哪）：

- 上面那段"默认构造全 0"说的是 bundle 里 **`VideoSettings` 的构造函数**，没错；
- 但**网页端真正发出去的不是构造函数的默认值，而是各播放器的 `preferredVideoSettings`**。
  2026-10-07 把 `bundle.js` 拉下来读到了原文：

  ```js
  // 默认播放器 mse
  MsePlayer.preferredVideoSettings = {lockedVideoOrientation:-1, bitrate:7340032,
                                     maxFps:60, iFrameInterval:10, bounds:Size(720,720), sendFrameMeta:false}
  // 另外两个播放器（tinyh264 / base）
  BasePlayer.preferredVideoSettings = {..., bitrate:524288, maxFps:24, iFrameInterval:5, bounds:Size(480,480)}
  ```

  所以 §6.2 里服务端初始头出现过的 `bitrate 7340032 / maxFps 60 / iFrameInterval 10`
  **就是网页端自己发的**，不是"服务端给的"。我们当年"逐字段回显 0"的结论对
  `maxFps` 那种误判是纠正了，但**把 bitrate 也一起清零是过头了**：
  实测（2026-10-07 手机端日志）我们发 `bitrate 0 / maxFps 0` 时平均只有
  **~0.6 Mbps / ~11fps**，画面又软又块，而网页端要的是 **7 Mbps / 60fps**。

- **现行做法**（`StreamSessionService.withWebPlayerPreferredDefaults`）：
  **服务端给了就回显服务端**（§6.2 的反馈循环教训不变），
  **服务端没给（0 / null）就照抄网页端 MSE 播放器的首选值**。
  测试：`video_bounds_clamp_test.dart` 里"★ 发出去之前用网页端 MSE 播放器的首选值补齐"
  与"★ 服务端给了的字段必须原样回显"。

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


#### 第二轮真机（14:07）：0 帧 —— 根因是**编码边界没对齐 16**（细节见 docs 历史）

`解码器可用输出类型` 只有默认 `1920x1080` + `已发布 0` + `流格式变化 0 次`；对照成功那轮
（`1280x720` / `992x560`，都 16 对齐）⇒ **非 16 对齐尺寸会让容器编码器产出 MF 解不出来的码流**。
修法：`clampBoundsToNative` 收敛后**向下对齐到 16**（`1898x853 → 1280x560`），绝不上抬。
（顺序修正只是 67 vs 64 的**正确性改进**，不是那次 0 帧的根因。）


#### 真机第三次（14:13）：GPU 共享纹理路**全黑** → 默认关闭（细节见 docs 历史）

`已解码 67 / 已发布 67 / 光栅回调 154` 但屏幕全黑。机制（`run_d3d11_adapter_probe.cmd` 实测）：
本机有 NVIDIA + Intel + Basic Render，我们的设备在 NVIDIA、引擎 ANGLE 多半在 Intel，而
**传统 DXGI 共享句柄不能跨适配器打开**（同适配器 3/3 OK、跨适配器 **0/6**）⇒ 引擎拿不到纹理。
**处置**：`WS_SCRCPY_GPU` 默认 **false**，要试显式 `WS_SCRCPY_GPU=1` + `WS_SCRCPY_GPU_ADAPTER=`。
**教训：`已发布 N 帧` ≠ 上屏成功。**



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

## 13. macOS 端（2026-10-02 已完成 —— 这一节保留为"当时怎么规划的"）

> **结论先看**：macOS 原生解码**已经实现并实跑确认**，细节见 **§15.8**。
> 实际做法与下面的规划基本一致，唯一重要的偏差是：
> **共享的是 `darwin/ScrcpyVideo*.swift` 三个文件（含通道与纹理），不是只有解码器**——
> 因为通道逻辑两端只差"从哪拿纹理注册表"，复制一份就违反"不维护第二份业务逻辑"。
> 下面这段是实施前的规划，留着说明思路来源，**以 §15.8 为准**。

**平台无关的部分直接照用，不用改**：协议层、投流会话、输入映射、UI、
以及 `NativeVideoDecoder` 的 MethodChannel 契约（`ws_scrcpy/video` 的
`create / pushFrame / release / getSize` + 每次 `pushFrame` 回执里带 `{width,height}`）——
Dart 侧已经按平台分支，见 `lib/feature/stream/data/remote/native_video_decoder.dart`。

**Dart 侧唯一要改的一处**：`lib/feature/stream/presentation/viewmodel/player_viewmodel.dart`
的 `isNativeDecodingSupported` 加上 `macOS`（已完成）。

**原生侧复用情况**（实际做法见 §15.8）：解码器、纹理、通道都在 `darwin/`，两个 Xcode 工程都引用
`../darwin`；macOS 侧**只写注册那一层**（`macos/Runner/MainFlutterWindow.swift`）。

**签名 / entitlement**：`macos/Runner/*.entitlements` 的 `network.client` 已补（投流要联网）；
VideoToolbox 不需要额外 entitlement，但 **Debug 与 Release 两个 entitlements 文件都要看一眼**。

**验证方法（照 Windows 那套，别信日志）**：macOS 上截图是 `screencapture -x shot.png`；
**先确认画面出来**，再看计数。心跳口径保持一致：
`已发布 / 已喂入` 接近 1:1；`已发布 ≪ 已喂入` 就是"解码器在憋"（回去看 `RealTime` 有没有设上）。

**验收**：① 首帧立刻出（不是 1~3 秒后）；② 画面静止时不黑、不隔几秒跳一下；
③ `screencapture` 截到的图里确实有设备画面。

---

## 14. CI 与应用图标

- **CI（Forgejo Actions）**：`.forgejo/workflows/build.yml` 三个 job ——
  `verify`（analyze + test）/ `windows`（zip）/ `android`（APK）。
  **硬约束：Windows 桌面产物只能在 Windows 上构建**，所以用一台 Windows 自托管 runner
  同时跑两端（`runs-on: windows` ↔ runner 标签 `windows:host`）。注册、工具链、排错见 **`docs/ci.md`**。
  Windows 依赖那一步在 CI 上用 `tools\prepare_windows_deps.ps1 -Online`（干净机器没有本机 NuGet 缓存）。
- **图标**：`python tools/make_icons.py` 一次生成 Windows(.ico)/Android(含自适应)/macOS/iOS/Web，
  母版 `assets/icon/app_icon_1024.png`；换配色只改脚本顶部的 `GRAD_*` 常量。
  **改完必须看图确认**（第一版把"缝隙"写成了实心矩形，整个图形被擦掉，是看图才发现的）。

---

## 15. M2 路线 A（iOS 原生解码）实现说明

```
WS 视频帧 ──► StreamSessionService.videoFrames ──► PlayerViewModel
                                                      │ MethodChannel('ws_scrcpy/video')
                              ios/Runner/ScrcpyVideoChannelHandler.swift
                                                      │
                              ios/Runner/ScrcpyVideoDecoder.swift
                              VideoToolbox VTDecompressionSession
                                Annex-B → AVCC → CMSampleBuffer → CVPixelBuffer(32BGRA)
                                                      │
                              ios/Runner/ScrcpyVideoTexture.swift（FlutterTexture.copyPixelBuffer）
                                                      │
                              Flutter 侧 Texture(textureId) ◄──────┘
```

**状态（2026-10-02）**：已在 **iPhone 18 Pro 模拟器 + 真实服务端**上跑通，并**自己截图确认画面**
（AGENTS §1.2 的铁律）。当次日志锚点：

```
纹理注册返回 0（失败）：来源=引擎 applicationRegistrar      ← 见 §15.3
纹理注册成功：来源=FlutterViewController，textureId=1
低延迟模式：kVTDecompressionPropertyKey_RealTime=true 设置结果=0x00000000
画面尺寸：1184x672
已解出第一帧并交给纹理（1184x672）
心跳：收到 13，已喂入 12，已解出 12，丢弃 0，队列深度 0 …
```

**还没上过真机**（要过签名），模拟器走的是软件解码；真机验收清单见 §15.6。

### 15.1 文件与职责

| 文件 | 职责 |
|---|---|
| `ios/Runner/ScrcpyVideoDecoder.swift`（新） | VideoToolbox 解码：Annex-B→AVCC、SPS/PPS→`CMVideoFormatDescription`、会话重建、队列、心跳与计数。**不 import Flutter**，所以 macOS 能复用、也能编成 macOS 命令行探针 |
| `ios/Runner/ScrcpyVideoTexture.swift`（新） | `FlutterTexture` 实现：latest-frame + 锁 + `copyPixelBuffer` |
| `ios/Runner/ScrcpyVideoChannelHandler.swift`（新） | `ws_scrcpy/video` 通道：注册纹理、派发方法、把解出的帧交给引擎 |
| `ios/Runner/AppDelegate.swift`（改） | 在 `didInitializeImplicitFlutterEngine` 里建 handler 并**持有**它 |
| `ios/Runner.xcodeproj/project.pbxproj`（改） | 三个新 Swift 文件登记进 Runner target（`PBXBuildFile` + `PBXFileReference` + group + Sources phase 四处） |
| `ios/Runner/Info.plist`（改） | `NSAllowsLocalNetworking`、`NSLocalNetworkUsageDescription`、`ITSAppUsesNonExemptEncryption=false` |

**契约与 Android / Windows 一字不差**：`create` → `{textureId}`；`pushFrame`（一帧 Annex-B）→
`{width,height}` 回执；`getSize` → `{width,height}`；`release`。
**没有** `onSizeChanged` 反向推送（那是 Windows 崩溃 `0x58CA5` 的成因，§12.1）——Dart 侧
"回执 + 拉取"两条路够用，`native_video_decoder.dart` 不用改一行。

### 15.2 Annex-B → AVCC：这一端最容易写错的地方

VideoToolbox 的 H.264 输入按 **AVCC（4 字节大端长度前缀）** 解释，**不吃起始码**，
所以每条消息都要先转（`ScrcpyVideoDecoder.annexBToAVCC`）。三个已钉死的点：

1. **切起始码必须先判 4 字节再判 3 字节**。反过来的话 `00 00 00 01 65 …` 会在偏移 1 处
   命中 `00 00 01`，于每个 NAL 都多吃一个前导 0 字节 → **类型全错**。
   `tools/run_vt_replay_probe.sh` 里专门有一条这条的断言（4 字节 → NAL 始于偏移 4）；
2. **`CMBlockBufferCreateWithMemoryBlock(memoryBlock: nil)` 之后必须先 `CMBlockBufferAssureBlockMemory`**
   再 `CMBlockBufferReplaceDataBytes`（块内存是懒分配的）。漏了这步会静默失败、一帧都出不来。
   可行性文档 §3.1.3 的示例没有这一步；
3. **`CMSampleBufferCreateReady` 的 `sampleSizeArray` 给整段 AVCC 长度**（一条消息里多个 NAL
   就是**一个** sample，不需要一个 NAL 一个 sample）。

另外：`nalUnitHeaderLength: 4`；`00 00 03` 这种 emulation prevention byte **原样保留**，
解码器自己去。

### 15.3 ★ 最大的坑：`applicationRegistrar.textures()` 注册纹理返回 0

**现象**：设备列表、投流、收帧全都正常（`状态：推流中 · 分辨率 VideoSize(1280 x 720) · 视频帧 15`），
但投流页红字 `原生解码失败：创建 H.264 解码器失败：注册 Flutter 纹理失败`，画面全黑。

**根因**：本项目的 iOS 是**Scene 生命周期 + 隐式引擎**，通道在
`didInitializeImplicitFlutterEngine(_:)` 里注册。此时 `engineBridge.applicationRegistrar.textures()`
拿到的是 `FlutterTextureRegistryRelay`，而它的 **parent 是 weak 的**、还没接上宿主视图，
`registerTexture:` 直接返回 0。引擎二进制里那几个符号能对上：
`FlutterTextureRegistryRelay`、`T@"NSObject<FlutterTextureRegistry>",W,N,V_parent`。

**修法（`ScrcpyVideoChannelHandler.register`）**：两条路依次试，**都记日志说明是哪条生效**：

1. `engineBridge.applicationRegistrar.textures()`；
2. `FlutterViewController`——**它自己就实现了 `FlutterTextureRegistry`**
   （`FlutterViewController.h:57`），是纹理归属的最终宿主；在当前 Scene 的窗口层级里递归找它
   （兼容被 `UINavigationController` 之类包一层的情况）。

**注销必须用注册时那一个注册表**（handler 里存 `resolvedTextureRegistry`），否则注销不掉。

**教训**：这条不在可行性文档的预判里——文档只把"`textures` 属性名与类型"标成 ⚠️需实测。
**"未实现的平台能力"往往不是编译不过，而是返回 0 静默失败**，所以两个候选来源都要试、
试完要打日志。

### 15.4 原生日志：iOS 上必须走两个出口

`NSLog` **只进系统日志，`flutter run` 的控制台抓不到**（2026-10-02 实测：整轮跑下来
`flutter run` 的输出里一条 `[ScrcpyVideo]` 都没有，而 `xcrun simctl spawn booted log show`
里一条不少）。这是 Windows 那条教训（§12.2：日志只走 `OutputDebugStringA` → `flutter run` 全程静默）
在 iOS 上的翻版，所以 `scrcpyVideoLog` **两个出口都写**：

- `NSLog("[ScrcpyVideo] …")` → 系统日志，用
  `xcrun simctl spawn booted log show --last 3m --predicate 'eventMessage CONTAINS "ScrcpyVideo"' --style compact` 读；
- `print("[ScrcpyVideo] …")` → stdout，`flutter run` 的控制台直接可见。

**顺带一条**：Dart 侧 `AppLogger` 用的是 `developer.log`，它**同样不进 `flutter run` 的控制台**
（要去 DevTools / VM service 看）。排"画面尺寸不对"这类问题时别指望它——真机/模拟器上
要么看 App 内的日志面板（投流页右上角图标），要么临时用 `print`。

### 15.5 离线验证：`tools/run_vt_replay_probe.sh`

把 **`ios/Runner/ScrcpyVideoDecoder.swift` 本身**编到 macOS 上跑（不是副本——
§12.3 的纪律："诊断工具不要维护第二份业务逻辑"）。三类检查，当前 **27 项检查 0 失败**：

1. **Annex-B 工具函数的字节级断言**：4 字节优先、3 字节、混合起始码、AVCC 长度前缀；
   真实抓包夹具 `test/fixtures/stream_first_video_frames.txt` 的 NAL 类型序列必须是 `[7,8]`；
2. **真实抓包的 SPS/PPS 能建出会话**：夹具第一条（真实服务端下发）→ 画面尺寸 `1280x720`；
3. **完整码流逐帧回放 + 低延迟 A/B**：码流由本机 `VTCompressionSession` 现编
   （H.264 baseline、Annex-B、SPS/PPS 先发，结构与 scrcpy 一致），90 帧，
   `RealTime=true / false / 完全不设` 三种设置各跑一遍。

```
真实抓包 SPS/PPS → 画面尺寸 1280x720
生成 90 帧 Annex-B（640x360）
收到 91，已喂入 90，已解出 90，丢弃 0，非全黑 90 帧       ← 三种 RealTime 设置都是这个结果
```

**结论：Apple 侧没有 Windows 那种"默认攒 1.2 秒"的缓冲**（那边是 8/43 vs 42/43）。
`RealTime` 头文件说默认就是 true，探针把这条从"文档说"变成了"实测"。
**但探针仍然保留这个 A/B**：真出现"已解出 ≪ 已喂入"时，它是第一个要跑的入口。

**探针自己踩过的坑（已修，别再犯）**：第一版把 90 帧**瞬间推完**，撞上 8 帧的等待队列上限，
**把 IDR 丢了** → 后面的 P 帧引用不存在的参考帧 → 满屏 `kVTVideoDecoderBadDataErr`（-12909），
看起来像"解码器完全不工作"。真实来源是网络、本来就按 33ms 到，所以探针现在按 10ms 节奏喂，
并**断言 `丢弃 == 0`**——"诊断工具也要有自己的边界校验"（§12.3 那条教训）。

### 15.6 工程、真机与合规（还没做/只做了一半的部分）

- **文件进 Xcode**：三个新 Swift 文件已登记进 `ios/Runner.xcodeproj/project.pbxproj`
  （`plutil -lint` 通过、`xcodebuild -list` 能解析、`flutter build ios` 能编译）。
  以后再加文件照着改那四处（BuildFile / FileReference / group children / Sources phase）。
- **CocoaPods 与 SPM 并存**：Flutter 3.47 默认开 Swift Package Manager，但
  `flutter_secure_storage` 还不支持 SPM，Flutter 会对它**回退到 CocoaPods**。
  所以 `brew install cocoapods` 是**硬前置**（没装时 `flutter build ios` 直接以
  `CocoaPods not installed or not in valid state` 结束，报错信息里那句
  "The following plugins do not support Swift Package Manager" 才是真正原因）。
- **`Info.plist` 已加**（按可行性文档 §4.2 的清单）：
  `NSAppTransportSecurity.NSAllowsLocalNetworking`（局域网明文 `ws://<设备IPv4>:8886` 要它，
  比 `NSAllowsArbitraryLoads` 安全得多）、`NSLocalNetworkUsageDescription`、
  `ITSAppUsesNonExemptEncryption=false`。
  ⚠️ 这两条**都还没在真机上实测**（模拟器上公网 `wss://` 用不到它们）。
- **还没做**：真机签名 / provisioning；App Store 审核那套（远程控制类 §4.2.7，
  可行性文档 §4.2c 有对策）；应用标识仍是 `com.example`。
- **真机验收清单**（照 §1.2 的路子，别信日志）：
  ① 起手先看 `低延迟模式：kVTDecompressionPropertyKey_RealTime=true 设置结果=0x00000000`；
  ② `纹理注册成功：来源=…`（真机上若 `引擎 applicationRegistrar` 这条就能成，说明模拟器那个坑
     是场景相关的，值得回头在 §15.3 补一句）；
  ③ 心跳 `已解出 / 已喂入` 应接近 1:1，`丢弃` 应长期为 0；
  ④ **截图确认画面**（真机 `xcrun devicectl` 或直接看屏幕），并留意色彩是否正常
     （输出格式是 32BGRA，理论上不会红蓝颠倒，但真机必须看一眼）。

### 15.7 ★ 顺带修掉：画面糊 —— 编码边界的**宽高比**必须跟设备一致

**现象**：iOS 上第一次跑通时画面能出，但**糊得明显**（MAA 界面的字勉强可认）。

**数据（不是猜）**：临时在视口上报处打了一行日志，拿到

```
[Viewport] 画面控件 402.0x664.0 逻辑 @3.0x → 上报编码边界 1206x1992
```

设备原生 `1280x720`（横屏），而我们的视口是**竖屏**。老的 `clampBoundsToNative` 只做等比缩放，
算出 **432x720 的竖框**；服务端是"把画面按比例**装进**这个框"（不拉伸），
于是 16:9 的横屏画面装进竖框后只剩 **432x240**——上屏要放大 2.96 倍，肉眼就是糊。

**修法（`StreamSessionService.clampBoundsToNative`）**：多一步"**先把视口按设备宽高比收成框**"，
再收敛到原生范围内、再对齐 16 宏块。同一场景变成 **1200x672**，像素多了 **7.7 倍**，
截图里的字立刻清楚了（服务端实际给到 `1184x672`）。

**这条改的是共享 Dart 逻辑，Windows 也受影响（而且是变好）**：
Windows 上视口 1898x853 对设备 1280x720，老算法给 `1280x560`，新算法给 **`1280x720`**
（多 28% 像素、比例也正确）。`test/feature/stream/video_bounds_clamp_test.dart` 里
"iPhone 竖屏 1206x1992 对横屏设备"就是这条的**回归门禁**（断言像素数 > 432×240×7）。

**教训**：§12.7 只写了"不许超过原生"，漏了"**框的比例必须跟设备一致**"——
"向服务端要一个框"这件事有两个自由度（大小、比例），只钉住一个就会在另一个上吃亏。

### 15.8 macOS：只写了"注册"那一层（2026-10-02 已完成）

**做法**：把三个 Swift 文件从 `ios/Runner/` 搬到 **`darwin/`**（Flutter 生态里 iOS+macOS 共享
源码的惯例目录名），两端 Xcode 工程各自加一个 `path = ../darwin` 的分组引用同一批文件：

```
darwin/
├── ScrcpyVideoDecoder.swift        # 纯 Foundation/CoreMedia/VideoToolbox，与 Flutter 无关
├── ScrcpyVideoTexture.swift        # FlutterTexture（iOS/macOS 同为 `FlutterTexture` 协议）
└── ScrcpyVideoChannelHandler.swift # 通道；两端只差"从哪拿纹理注册表"
```

**两端唯一的差异被做成了参数**，而不是复制一份通道逻辑：

```swift
init(messenger: FlutterBinaryMessenger,
     textureRegistry: FlutterTextureRegistry,
     fallbackTextureRegistry: @escaping () -> FlutterTextureRegistry? = { nil })
```

| 端 | 主注册表 | 兜底 | 实际生效的 |
|---|---|---|---|
| iOS | `engineBridge.applicationRegistrar.textures()` | 当前 Scene 里的 `FlutterViewController` | **兜底那条**（§15.3） |
| macOS | `flutterViewController.registrar(forPlugin:).textures` | `flutterViewController.engine` | **主注册表**（实测日志 `纹理注册成功：来源=主注册表（…macOS registrar）`） |

**macOS 侧要写的全部代码**就是 `macos/Runner/MainFlutterWindow.swift` 里的这几行
（`awakeFromNib` 里、`RegisterGeneratedPlugins` 之后），外加一个属性持住 handler
（不持有会被立刻释放，通道调用全部落空）：

```swift
let registrar = flutterViewController.registrar(forPlugin: "WsScrcpyVideo")
videoChannel = ScrcpyVideoChannelHandler(
  messenger: registrar.messenger,          // ← macOS 是**属性**，iOS 是方法 messenger()
  textureRegistry: registrar.textures,
  fallbackTextureRegistry: { flutterViewController.engine })
```

**踩到的几个小差异（都是"照着 iOS 写会编译不过"那一类）**：

- **Flutter 模块名不同**：iOS `import Flutter`、macOS `import FlutterMacOS` →
  共享文件里用 `#if os(iOS) / #elseif os(macOS)`；
- **`messenger` / `textures` 在 macOS 是属性、在 iOS 是方法**（`registrar.messenger` vs
  `engineBridge.applicationRegistrar.messenger()`）；
- **`registrarForPlugin:` 的 Swift 名是 `registrar(forPlugin:)`**；
- **`ScrcpyVideoChannelHandler` 原来 `import UIKit`**（为了找 `FlutterViewController`）——
  搬到 `darwin/` 时必须把这段挪回 iOS 侧（现在是 `AppDelegate` 里的两个私有静态方法），
  否则 macOS 编不过。

**验证（与 iOS 同一套，照 §15.5 / §15.6）**：

- `flutter build macos --debug` 通过；构建日志里能看到
  `SwiftCompile … /Users/…/darwin/ScrcpyVideoDecoder.swift (in target 'Runner')`
  —— 这就是"macOS 真的在编共享文件"的证据；
- **本机实跑 + 自己截图**（`screencapture -x`，注意需要系统的"屏幕录制"权限）：
  `纹理注册成功：来源=主注册表`、`低延迟模式：…RealTime=true 设置结果=0x00000000`、
  `硬解：是`、`画面尺寸：1280x720`、`已解出第一帧并交给纹理`、
  心跳 `收到 13 / 已喂入 12 / 已解出 12 / 丢弃 0`；截图里设备画面清晰可读。
  用户也自己试过一轮，反馈可用；
- 离线探针不用改（它本来就是拿这份解码器在 macOS 上跑的）——这也正是当初把解码器写成
  "不 import Flutter"的回报。

**两个 macOS 特有的、踩过的坑**：

1. **`flutter run -d macos` 有时会 `Failed to foreground app; open returned 1`**，
   窗口被压在别的窗口后面。想截图确认上屏时，直接 `open build/macos/Build/Products/Debug/ws_scrcpy_client.app`
   把已经构建好的产物拉起来更省事（`--dart-define` 已经编进产物里了）；
   再用 `osascript -e 'tell application "System Events" to tell process "ws_scrcpy_client" to set frontmost to true'`
   把它提到最前。
2. **`screencapture` 需要"屏幕录制"权限**（TCC）。没授权时它报
   `could not create image from display`，且**不会**弹窗提示——别误判成"App 没窗口"。
   （iOS 模拟器那条 `xcrun simctl io booted screenshot` 走的是 simctl，不受这个限制。）

---

## 16. 2026-10-07：macOS 安全存储、拉伸窗口丢输入、清晰度开关

### 16.1 macOS 密码写不进钥匙串（`-34018`）——已修

**现象**（用户贴回来的日志）：

```
[SecretLocalDatasource] 写入安全存储失败，密码仅在本次会话有效
  | cause: PlatformException(Unexpected security result code, Code: -34018,
           Message: A required entitlement is not present., -34018, null)
```

**根因（读代码 + 本机探针，不是猜）**：

1. `flutter_secure_storage_macos` 3.1.3 的 `MacOsOptions` 默认
   `useDataProtectionKeyChain = true`（`lib/options/macos_options.dart`），
   它进到 `FlutterSecureStorage.swift` 的 `baseQuery` 就是
   `kSecUseDataProtectionKeychain = true`；
2. 数据保护钥匙串要求 `keychain-access-groups` / `com.apple.application-identifier`，
   这两样只能由 provisioning profile 提供；而 Runner 是 **ad-hoc 签名**
   （`macos/Runner.xcodeproj/project.pbxproj` 里 `CODE_SIGN_IDENTITY = "-"`，
   `codesign -dv` 实测 `TeamIdentifier=not set`）→ `SecItemAdd` 直接 `-34018`。

**本机探针（`.tmp/`，不属于仓库）**：一个最小 `.app`（同款 `com.apple.security.app-sandbox`
授权 + ad-hoc 签名）分别调两种查询：

| 查询 | 结果 |
|---|---|
| `kSecUseDataProtectionKeychain = true` | `-34018 A required entitlement is not present.` |
| 不带该键（= 文件式 login 钥匙串） | `add / read / delete` 全部 `0`，无弹框 |

**还额外验了"重建之后还能不能读"**（ad-hoc 每次重建 cdhash 都变，是以前的疑点）：
v1 写入 → 改一个字符串常量重新编译+重签名（cdhash 变了）→ v2 读，仍然
`SecItemCopyMatching -> 0 value=acl-probe-value`。**没有授权弹框，没有 ACL 失败。**

**修法**：`lib/app/app_scope.dart` 里把安全存储选项集中成 `appSecureStorage`，
macOS 显式关掉数据保护钥匙串：

```dart
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
  mOptions: MacOsOptions(useDataProtectionKeyChain: false),
);
```

**门禁**：`test/app/app_scope_test.dart` 钉住这两个选项（改回默认就变红）。
**未完成**：用真实服务端跑一次"创建配置 → 重启 → 设备列表能拉到"的端到端复验
（本会话里被打断，代码与机制两层证据已经齐了）。

### 16.2 ★ 拉伸窗口后"没法操控"：每帧一条编码参数把服务端编码器刷爆了

**现象**（用户原话）："当我拉伸应用大小，或者点击铺满屏幕后，就无法操控了"。

**先把它变成数字**：新增的回归测试
`test/feature/stream/player_page_test.dart` → "★ 拖动窗口连续改变尺寸：最多补发 1 条编码参数"，
模拟桌面窗口拖动 20 帧（每帧一个新尺寸，总共约 0.3 秒），数
`CHANGE_STREAM_PARAMETERS` 的条数：

- **修之前：20 条**（旧断言红：`Expected: a value less than or equal to <1> / Actual: <20>`）；
- **修之后：1 条**（最终尺寸），而且拉伸后点画面仍然发得出 down/up。

**根因**：`_VideoStage` 的 `LayoutBuilder` 每次布局都把控件尺寸报给
`PlayerViewModel.applyViewportSize`，而拖窗口时**每帧尺寸都不同**，
`StreamSessionService.applyViewportBounds` 里的"相同尺寸去重"**只挡重复、挡不住变化** →
每帧下发一条 `CHANGE_STREAM_PARAMETERS` → 服务端每收一条就重建一次编码器；
重建后不会立刻出 IDR，画面停住/发黑，用户看到的就是"点不动"
（这个失败模式 §6.2 / §12.5 都记过，只是这次的触发源是"窗口拖动"）。

**修法**（`PlayerViewModel`）：首个尺寸照旧**立刻**上报（首发要一次到位，§12.5），
之后尺寸变化**合并 + 防抖 350ms**（`kViewportSettleDelay`，与网页壳那条 resize 防抖对齐）
再下发一条；尺寸没变时什么都不做。

**"铺满屏幕"那条**：`VideoFitMode` 只改本地渲染与坐标换算，**不发任何协议消息**
（有测试 `★ 横屏 + 铺满：原本的黑边还能点` 守着）。所以如果单独切"铺满"也出现
"点不动"，请看 §16.4 的 `[Input]`/`输入层` 日志——那说明是**另一条**原因，
不要和这条混在一起。

#### 16.2.1 ★★ 同一个坑的第二、第三条入口：**手机转屏**与"去重键选错了"

**用户原话**："手机端，我旋转一下屏幕，就点不了了"、"旋转后，再点击，会卡个几十秒左右，
才有反应，才能重新点击"。

**日志给出的第一手证据**（用户贴回来的 `[Input]`/`[Viewport]` 行）：

- `黑边丢弃 0 条`、每条都是 `结果=已发`，坐标换算自洽（`控件内=(202.0,433.3) → 视频=(643,629)`，
  反解出的 scale/offset 与 `画面诊断` 里的数字完全一致）→ **触摸这条路没问题**；
- `画面诊断：视频 1280x720 … 生效编码边界 1200x672` 之后又出现 `视频 1184x672`
  → 说明**服务端确实重建过编码器**（尺寸变了）。
- `iFrameInterval = 10`（服务端给的参数，§12.7）→ 编码器重建后要等新的 IDR，
  **最坏 10 秒**；重建两三次就是用户说的"几十秒"。这就是 stall 的机制。

**根因（两条，都在共享 Dart 层）**：

1. 转屏时"按设备比例内接于视口"的框从竖屏 `1200x672` 跳到横屏 `1280x720`，
   **每跳一次就是一条 `CHANGE_STREAM_PARAMETERS`**；
2. 更隐蔽的一条：`applyViewportBounds` 的**去重键用的是"UI 报上来的原始尺寸"**，
   而转屏时原始尺寸每次都不同（`1206x2094` ↔ `2622x1206`）——哪怕收敛后**完全一样**
   也照样发消息。

**修法（两条一起才成立）**：

- **吸附到原生**：`clampBoundsForMode` 里 `nativeCap` 模式多一步——视口按设备比例收框后
  宽度达到原生的 `snapToNativeRatio = 0.9`，就直接要**原生**。转屏后两个方向都收敛成
  `1280x720`（iPhone 竖屏 1206x2094 → 94% ≥ 90%），于是**边界根本不变**；
  代价是多要不到 23% 的像素，且只对"已经贴着原生"的视口生效（`999x601 → 992x560`
  这类明显更小的视口仍然不放大，AGENTS §12.7 不变）。
- **去重键改成"收敛后的生效边界"**：`_lastViewportBounds` 现在记的是
  `clampBoundsForMode` 的结果。于是"原始尺寸变了、生效边界没变"→ **一条消息都不发**。

**实测口径（下次复验就看这两行）**：转屏前后
`视口诊断：本秒控件布局 N 次，真正下发编码参数 M 条` 里的 **M 必须是 0**，
`画面诊断：…生效编码边界 …` 必须**一直是 1280x720**。

**回归测试**：
`stream_session_service_test.dart` 的 `★ 转屏不改编码边界：一条消息都不发`（断言
`viewportUpdateSequence == 0` 且报文条数不增）、
`video_bounds_clamp_test.dart` 的 `★ 转屏（竖 1206x2094 ↔ 横 2622x1206）收敛成同一个边界`、
`player_page_test.dart` 的拖动窗口那条测试里**追加了"转屏 16 帧"**一段（断言最多补发 1 条）。

**顺带修掉的**：首发用服务端给的边界时，收敛结果常常就等于 UI 想要的（都是原生），
现在这种"等价补发"会被去重吃掉 —— 少一次编码器重建（测试
`UI 尺寸晚于初始信息头：兜底那条等价时不再补发` 钉住）。

#### 16.2.2 横屏右侧快捷栏"太松散"（用户："右边按钮区域太松散了"）

`_QuickBar` 竖排原来用 `MainAxisAlignment.spaceEvenly`，而横屏时这一列会拿到整屏高度 →
4 个按钮被摊到 ~400 点里，看着散、拇指也够不着。改成**居中一小组**
（`Center` + `Column(mainAxisSize.min, spacing: AppSpacing.xs)`），
按钮在竖排时走 `compact`：内边距 `4/2`、图标 `AppIconSize.md`，
但**最小可点区域仍然 44x44**（无障碍底线）。回归断言：
`player_page_test.dart` 里"4 个按钮的竖向跨度 < 200"。

### 16.3 清晰度：网页端更清楚，是因为它把**视口尺寸**直接当编码边界

**用户原话**："ws 自带的网页端的清晰度完爆桌面端的"。

**把网页端的做法读出来**（`curl -u … https://android.dorkytiger.top/bundle.js`，740 KB，
只读不改）：

```js
getMaxSize = function () {
  var e = document.body,
      t = e.clientWidth - this.controlButtons.clientWidth & -16,   // 对齐 16
      r = -16 & e.clientHeight;
  return new Size(t, r);
};
… a.player.setVideoSettings(i, a.fitToScreen, !1) …
```

也就是说：网页端把 **CSS 像素的视口尺寸**当 `bounds` 发过去，**既不乘 DPR、也不按设备原生封顶**。
我们的旧行为是"一律封顶到设备原生"（§12.7 的取舍），于是在大窗口 / Retina 上
只能拿到 1280x720，再靠本地放大 2 倍以上——同一个流，放大倍数越大越糊。

**新增开关 `VideoBoundsMode`**（`lib/feature/stream/enum/video_bounds_mode.dart`）：

| 模式 | bounds 上限 | 默认 |
|---|---|---|
| `nativeCap`（省设备算力） | 设备原生 + "贴原生就吸原生"（§16.2.1） | 手动切回时用（转屏不改边界的退路） |
| `viewport`（清晰优先） | 原生 ×2（`VideoBoundsMode.maxUpscale`） | **全部平台默认**（2026-10-07 用户要求） |

**为什么默认改成清晰优先（用户实测的原话级证据）**：手机横屏时画面区物理 `2280x1206`，
而 `nativeCap` 封顶在设备原生 `1280x720` → `画面诊断` 里 `**本地放大 1.68x**`（就是糊）；
切到清晰优先后请求 `2144x1200`（≈ 画面区物理像素）→ 放大倍率才能回到 ~1.0。
日志里的两行就是判据：`请求的编码边界 2280x1206 收敛/对齐为 2144x1200（模式=清晰优先…）`
与 `画面诊断…生效编码边界 2144x1200`。

**清晰度的另一半是码率/帧率（2026-10-07 同一天查出）**：日志里
`VideoSettings(bitrate: 0, maxFps: 0, iFrameInterval: 0, …)` 说明服务端那次初始头是 `null`，
我们就发了 0 = "让服务端自己定"；而网页端默认播放器自己带的是
`bitrate 7340032 / maxFps 60 / iFrameInterval 10`（bundle 原文见 §12.7 的更正）。
现在改成"服务端没给就照抄网页端"，测试见 `video_bounds_clamp_test.dart`。
复验判据：`WS 帧吞吐/s` 的平均**字节/帧**应当明显上升（不再是一帧 6~7 KB），
画面在大面积变化（滚动、切页）时不再发块。

**两条模式在"转屏"上的差别（要记住）**：
- `nativeCap`：贴原生会**吸附**，竖/横两向都收敛成原生 → 转屏**一条消息都不发**（§16.2.1）；
- `viewport`：竖屏 `1200x672` ↔ 横屏 `2144x1200` **不一样** → 转屏会补发一条、
  服务端重建一次编码器。想要"转屏完全不动"就切回 `nativeCap`，想要"横屏更清楚"就用默认值。

两种模式都保留"与设备同比例收框"（§15.7）和"16 宏块对齐"（§12.8）——
那两个是硬要求，与"清晰度取舍"无关。切换会**立刻**补发一条参数（否则用户点了看不见变化），
入口在投流页"更多"面板里的「清晰优先（按画面区像素编码）」。

**默认值按平台分**：桌面 `viewport`（用户要的就是网页端那种清楚），
移动端保持 `nativeCap`（§12.7 那次"帧间隔 53–166ms"就是在 iOS 上量的，不替手机用户翻案）。

**还没有的**：`viewport` 模式在真实设备上的帧率数据。日志里
`帧吞吐/s：发起 +N` 与原生心跳的 `帧间隔` 就是判据；如果掉帧明显，把开关关掉即可。

### 16.4 ★ 排查这两个问题先看哪几条日志（都是这次加的）

| 日志 | 在哪 | 说明 |
|---|---|---|
| `视口诊断：本秒控件布局 N 次，真正下发编码参数 M 条…` | `[Viewport]`（每秒一条） | M 接近 N（几十）就是**窗口拖动风暴**；修好后拖动中也只有 1 条 |
| `画面诊断：视频 WxH，fit=…，生效编码边界 WxH，控件 … 逻辑 = … 物理，绘制 …，**本地放大 x.xx 倍**，输入层=接上/断开` | `[Viewport]` | 一条日志回答"为什么糊"（放大倍数 >1 就会糊）与"为什么点不动"（`输入层=断开`） |
| `输入层已接上 / 输入层**未接上**（原因=…）` | `[Input]` | 只在状态翻转时打。**未接上**= 事件根本没到 `Listener`（视图层问题）；接上了却仍没反应，就往下看逐条事件 |
| `原始 down/up id=… 控件内=(x,y) → 视频=(x,y)`、`… → 丢弃（黑边…）`、`忽略 down id=…`、`每秒统计：down/move/up/发出/重复/黑边丢弃` | `[Input]` | 事件到没到、换算成什么、有没有被状态机丢掉 |
| `服务端初始头给的 VideoSettings：…`、`请求的编码边界 … 收敛/对齐为 …（模式=…）`、`首发视频参数…` | service | 设备原生多少、我们请它编多少、服务端给的是什么 |
| **每行日志都以 `HH:mm:ss.SSS` 开头**（2026-10-07 加） | 全部 | "卡了几十秒"只能靠**时间缺口**判定：每秒一条的 `每秒统计`/`帧吞吐/s` 断了几十秒 = 我们自己的 UI/引擎卡住；这些行一直没断、只有画面不动 = 卡在视频管线（服务端没给帧 / 解码器没解出来，看原生 `ScrcpyVideoDecoder` 心跳的 `已喂入 / 已解出`） |

**判据**：
- 拖窗口后**画面停住 + `视口诊断` 里 M 是几十** → §16.2 这条（已修，若再现说明防抖被破坏）；
- 切"铺满"后点不动，且 `[Input]` 里**一条 down 都没有** → 事件没到 `Listener`（看 `输入层` 那行）；
  有 down 但 `→ 丢弃（黑边…）` → 坐标换算与渲染不一致；
- 画面糊 → 看 `本地放大 x.xx 倍`：>1 就是被本地拉大，配合 `生效编码边界` 判断
  是"设备只给这么多像素"还是"我们要得太少"（后者就是 §16.3 的开关）。

---

## 17. web 端阶段二：WebCodecs 解码 + canvas 上屏（2026-10-07）

### 17.1 现状：阶段一时"连上也没有画面"

阶段一（§9.3）能跑通设备列表 / 投流连接 / 鉴权，但 `isVideoDecodingSupported` 在 web 上
是 false，页面上只有一句"原生解码已在 … 实现；其它平台可用设备卡片的网页入口观看"。
这一节补的就是那一层。

### 17.2 数据流（与原生三端只差"谁在解码"）

```
WS 视频帧（裸 Annex-B，一条消息一帧）
   │  StreamSessionService.videoFrames
   ▼
PlayerViewModel（编排完全没改：何时建解码器 / 喂帧 / 尺寸变化 / 失败重试）
   │  VideoDecoder 接口（本次新抽出来的平台边界）
   ▼
WebCodecsVideoDecoder（lib/feature/stream/data/remote/webcodecs_video_decoder.dart）
   ├─ H264AnnexB（lib/core/stream/h264_annex_b.dart，纯 Dart、有夹具单测）
   │    ├─ 有没有 IDR（type 5）→ EncodedVideoChunk 的 key / delta
   │    └─ SPS 头三个字节 → codec 串 avc1.PPCCLL
   ├─ 浏览器 VideoDecoder（configure(codec, optimizeForLatency:true) / decode(chunk)）
   └─ 输出 VideoFrame → 画进 <canvas>（平台视图），画完 frame.close()
```

**三个关键决定（都写进代码注释了）**：

1. **不传 `description`** → 浏览器按 Annex-B（起始码）解释，省掉 Annex-B→AVCC 重封装
   （服务端自己的 `WebCodecsPlayer` 就是这么干的）。
2. **`optimizeForLatency: true`** —— 这是 Apple 端 `kVTDecompressionPropertyKey_RealTime`
   在 web 上的对应物（§1.2 那张表的第三个平台）。
3. **画面是 DOM canvas，不参与 Flutter 绘制** → `FittedBox` 那套 contain/cover 管不到它。
   所以 `VideoDecoder` 接口上留了一个默认空实现 `applyDisplayGeometry(viewport)`，
   web 实现拿**与触摸换算同一份** `VideoViewport` 去写 canvas 的 CSS（left/top/width/height）。
   **这是"渲染与换算必须同源"这条纪律在 web 上的落地方式**——两边一旦分家就又是"点哪都偏"。
   容器的 `overflow:hidden` 负责把 cover 多出来的部分裁掉（对应原生的 `ClipRect`）。

**两个容易踩的 web 特有的坑（代码里已处理，别改坏）**：

- **DOM 必须 `pointer-events: none`**：否则 canvas 会把指针事件截走，
  Flutter 的 `Listener` 收不到，整条输入链路（以及我们那套坐标换算）就白做了。
- **平台视图只注册一次、DOM 复用**：`platformViewRegistry.registerViewFactory` 注册第二次会抛；
  而"关掉投流再开一条"（`release()` → `create()`）时视图层还得拿到**同一个** DOM 元素。
  所以 DOM 是 static 的，只有 `VideoDecoder` 对象是每实例的。`release()` 只关解码器 + 清画布。

**WebCodecs 的错误是异步回调**，没有地方直接返回给调用方：实现里先记进 `_pendingError`，
由**下一次 `pushFrame`** 带回给 viewmodel → UI 显示可读错误 + 重试入口
（帧率 10~60fps，所以最多晚一帧）。

### 17.3 本次改动的文件

| 文件 | 作用 |
|---|---|
| `lib/core/stream/h264_annex_b.dart` | 纯 Dart：切 NAL / 判 IDR / 取 SPS / 造 codec 串 |
| `lib/feature/stream/data/remote/video_decoder.dart` | 解码器平台边界（抽象类 + `applyDisplayGeometry` 默认空实现） |
| `lib/feature/stream/data/remote/video_decoder_factory{,_io,_web}.dart` | 条件导出分派（原生 / web），套路与 `web_socket_transport_connect.dart` 一致 |
| `lib/feature/stream/data/remote/webcodecs_video_decoder.dart` | WebCodecs 实现 + canvas 平台视图 + 几何 |
| `lib/feature/stream/presentation/view/web_video_surface{,_stub,_web}.dart` | 视图层的平台分派：web 出 `HtmlElementView`，原生是空实现 |
| `pubspec.yaml` | 新增直接依赖 `web: ^1.1.1`（WebCodecs 类型化绑定） |
| `tools/build_web.sh` | 顺手修掉末尾 `$BASE_HREF（` 被当成变量名导致的 `unbound variable` |

### 17.4 验证状态（★ 分清"验过的"和"没验的"）

**已验**：
- `dart analyze lib test tools` 干净（web 那份互操作代码也在静态检查范围内）；
- **`tools/build_web.sh` 通过**（dart2js 真编译 + 链接，18.8s）——这是 web 互操作 API 的
  主要门禁；产物里能 grep 到 `ws_scrcpy/web-video`（3 处）与 `optimizeForLatency`，
  说明这段代码**没被 tree-shake 掉**；
- `H264AnnexB` 用**真实抓包夹具**单测（`test/core/stream/h264_annex_b_test.dart`）：
  首帧 = SPS(7)+PPS(8)、第二条 = IDR(5)、`avcCodecString` = **`avc1.42c029`**（Baseline 4.1，
  就是这台 redroid 的软编码器给的）；
- VM 全量测试 **263 通过 / 1 skip**（原生那批 mock `ws_scrcpy/video` 的测试一行没改，
  因为 VM 里 `dart.library.js_interop` 是 false → 条件导出走原生那份）。

**没验（必须靠浏览器）**：浏览器**真的能解**这条流、画面真的上屏、触摸在平台视图上还有效。
我这边没有浏览器自动化权限（`screencapture`/AppleScript 都被拒，见 §9.2 末尾），
所以这三条只能由人在浏览器里复验。本地跑法：

```bash
tools/build_web.sh                 # 或 tools/build_web.sh /app/
cd build/web && python3 -m http.server 8765
# 浏览器打开 http://127.0.0.1:8765/ —— 跨源访问第一次会弹一次 Basic Auth（§9.3 已论证免不了）
```

**如果控制台报 codec / 描述符类错误**，备用方案是"构造 `avcC`（把 SPS+PPS 塞进
`VideoDecoderConfig.description`）+ 把每条帧重写成 4 字节长度前缀的 AVCC"——
`H264AnnexB` 已经把 NAL 边界切好了，改起来只是多一层封装，别推翻整条链路。

### 17.5 ★ "全黑且没有任何错误"：投递早于订阅，头几帧被广播流吃掉了（2026-10-07 用户实测）

**现象**：web 上连上投流页后画面**全黑、日志面板里一条 `WS 帧吞吐/s` 都没有**（有帧流动时
它每秒一条），而设备列表/鉴权/初始信息头都正常 —— 说明**服务层一帧视频都没收到**。

**根因（时序，不是猜）**：服务端的 `header` 与**头几帧**经常在同一个事件循环里投递完，
而 `videoFrames` 是**广播流**：viewmodel 的订阅要等 `_onSnapshot`（microtask）
→ `_startDecoder` → `create()` 之后才建立。在那之前到达的帧**没有监听者，直接丢**。
原生三端同样会丢，但它们"丢了也能活"（下一帧画面变化时重来）；
web 上更致命的是：**参数集（SPS+PPS）只发那一条**（实测夹具：第 1 条是纯参数集，
第 2 条 IDR 里**不含**参数集），丢了就永远算不出 `codec` 串 → 永远 `configure` 不了；
而 scrcpy **只在画面变化时发帧**，设备画面静止时不会再有帧 → **永久全黑**
（用户不点它，它就不动；点了也没画面回去看）。

**修法（`StreamSessionService`）**：留一个**补喂缓冲**——
- `_lastParameterSets`：最近一条纯参数集消息；
- `_framesSinceIdr`：**从最近一个 IDR 开始**的帧（上限 120 条；IDR 之前的 P 帧不记，
  没有参考帧补了也解不出来）；
- `replayFramesForNewDecoder()`：建好解码器后由 viewmodel 补喂（`参数集 + IDR + 后续`），
  **只在 web 上做**（`PlayerViewModel(isWeb:)`，原生保持原行为不动）。

**回归测试**：
- `stream_session_service_test.dart` → `★ 后建解码器的补喂缓冲…`（参数集在最前、IDR 之前的
  P 帧不补、新 IDR 只保留最近一个 GOP）；
- `player_page_test.dart` → `★ web：把"订阅之前到达"的参数集 + IDR 补喂给后建的解码器`
  （**一口气**推 header + 参数集 + IDR，中间不给微任务机会，复刻真机时序）。

**另外两条同时补的可观测性（针对"黑屏但没提示"）**：
- 解码器的**异步错误**现在走 `VideoDecoder.asyncErrors` 立刻上报（原来是"等下一帧再带回"，
  而画面静止时没有下一帧 → 一块无解释的黑屏）；UI 也改成**出错就先说错误**
  （`_buildStage` 里 `decoderError != null` 时即使旧纹理还在也显示占位 + 重试）；
- web 解码器的日志接进**应用内日志面板**（`createVideoDecoder(onLog:)`），
  不必开 F12 就能把原文发出来。

### 17.6 还没做的（下次接着做）

- **不跟随设备分辨率变化重建解码器**：web 这边 `configure` 一旦定下 codec 就不重配；
  设备旋转导致 SPS 变化（例如 1200x672 → 672x1200）时，Chrome 多数情况下能靠帧内
  参数集自适应，但**没有验证过**。要稳妥就按"参数集变了 → `reset()` + 重新 `configure`"。
- **中文字体方块**（§9.3 的老问题）与**同源部署**仍然没变。
- **横屏没有 AppBar 时的返回入口**：已在 `_ChromeBar` 左侧加了"返回设备列表"
  （浏览器没有系统返回键，原生靠系统手势/返回键；用户实测"左上角没有返回键"）。
- **web 上的清晰度/码率**：本次那些"清晰优先 / 网页端码率"的改动是共享 Dart 层，
  web 自动受益；但 web 的 `applyViewportSize` 走的是浏览器 CSS 尺寸，
  物理像素要靠浏览器 DPR —— 在 Retina 上 `devicePixelRatio=2` 会照常乘上去。
