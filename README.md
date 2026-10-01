# ws_scrcpy_client

ws-scrcpy 的多端客户端（Flutter）：把 ws-scrcpy 的安卓投流装进一个真正的 App ——
全屏、常亮、免重复输凭据，并在此之上实现原生协议层（复用层 / 控制消息 / 投流会话）。

- 需求与里程碑：[FLUTTER_AGENT.md](FLUTTER_AGENT.md)
- 协议实测记录（M0 产出，改协议前必读）：[docs/ws-scrcpy-protocol.md](docs/ws-scrcpy-protocol.md)
- 工程约定与目录映射：[AGENTS.md](AGENTS.md)

## 当前能力

| 能力 | 状态 |
|---|---|
| 设备列表（复用层 `GTRC` 通道） | ✅ |
| 凭据安全存储（Basic Auth，系统安全存储） | ✅ |
| M1 WebView 壳：全屏 / 常亮 / 带鉴权头加载 / 返回键映射 | ✅（`webview_all`：Android · iOS · macOS · Windows · Linux）|
| 投流会话：代理地址优先、初始信息头解析、视频参数下发、指数退避重连 | ✅ |
| 快捷栏：返回 / 主页 / 最近 / 更多（音量、电源、旋转、面板、断开在"更多"面板里） | ✅ |
| 真实服务端联调：拿到裸 H.264（SPS+PPS → IDR → P 帧） | ✅ 已实测 |
| **画面解码与渲染（M2 路线 A：Android `MediaCodec` → Texture）** | ✅ 已实测可用（用户设备上确认过画面） |
| **画面解码与渲染（M2 路线 A：Windows Media Foundation 解码器 MFT → NV12→RGBA → Texture）** | ✅ 已实机确认能出画面（2026-10-01）；黑屏/卡顿的根因与修法见 AGENTS §12.5 |
| **视频参数下发对齐服务端网页端**：首发一条、带 UI 最终尺寸、逐字段回显服务端 `VideoSettings` | ✅（修掉了"连发两条 → 编码器重建两次 → 黑屏"） |
| **M3 输入：触摸（多指）/ 滚轮 / 物理键盘（含 metaState）** | ✅ 已实现（坐标按视频像素换算，黑边上的触摸不转发；Windows 一旦有画面即可用） |
| 可选：连接后自动唤醒被控设备（`KEYCODE_WAKEUP`） | ✅ 默认**关**；它是给"设备屏幕休眠不出帧"留的开关，**不是**黑屏的修复 |
| 运行期诊断：原生日志（毫秒时间戳 + pid）、每秒心跳、`帧间隔` vs `平均处理`、帧计数 | ✅ 见 AGENTS §12.2 |
| M3 余项：剪贴板同步、软键盘文本注入、双指缩放 | ⏳ |

## 快速开始

```powershell
# 依赖
dart pub get

# 静态检查 + 单元测试（206 项，1 项按平台跳过）
dart analyze lib test tools
flutter test

# 运行
flutter run -d <android-device-id>   # 手机
flutter run -d windows               # Windows 桌面
```

首次启动会先进入**连接配置表单**：填写 ws-scrcpy 服务入口（服务端开了 Basic Auth 时再填账号密码），
保存后进入设备列表。配置存在本机 drift(SQLite) 数据库里，密码写入系统安全存储，
并支持多套配置（设置页可新增/切换/删除）。

每个**设备卡片上有两个入口**：

| 按钮 | 行为 |
|---|---|
| **网页** | 用 WebView 打开该设备的网页版投流页（深链直达画面：`#!action=stream&udid=…&player=mse&ws=…`），带 Basic Auth 质询应答 |
| **投流** | 走原生协议通道：连接/初始头/视频参数/重连 + **原生解码渲染画面**（Android `MediaCodec`、Windows Media Foundation → Flutter `Texture`），触摸/滚轮/键盘直接可用 |

### Windows 构建/运行注意

- `webview_all_windows` 的依赖已改成**离线**：构建期不再调用 nuget（见 [AGENTS.md](AGENTS.md) §3.1）。
  首次或换机器时跑一次 `tools\prepare_windows_deps.cmd` 准备离线包即可，之后
  `flutter clean` + `flutter build windows` 无需任何手工步骤。
- 若在受限环境（沙箱/受限令牌）里**运行** App，进程会写不了 `%TEMP%` 与 `%APPDATA%`：
  症状是 `flutter run` 报 `_createDevFS: ... Temp (errno = 5)`，或界面提示
  `读取本地设置失败：PathAccessException ... com.example\ws_scrcpy_client`。
  **请从普通终端或 IDE 直接运行**（`flutter run -d windows` / 直接双击
  `build\windows\x64\runner\Debug\ws_scrcpy_client.exe`）；
  仅 DevFS 那一条也可以在会话里把 `TEMP` 指到工作区绕过（见 AGENTS §3.2）。

## M0 协议探测

```powershell
$env:WS_PROBE_USER='<用户名>'
$env:WS_PROBE_PASSWORD='<密码>'
$env:WS_PROBE_SECONDS='8'
dart run tools/probe.dart            # 打印每一帧的类型/长度/前 64 字节与投流首帧结构

$env:WS_PROBE_WRITE_FIXTURES='1'
dart run tools/probe.dart            # 顺带把真实报文写成 test/fixtures/ 夹具
```

探测脚本与 App 共用 `lib/core/**` 的协议实现，因此脚本能跑通 = App 侧协议实现可用。

## 目录结构

```
lib/
├── app/         依赖装配（AppDependencies/AppScope）与跨模块导航（HomePage）
├── common/      设计 token、主题、三态通用组件（AsyncStateView / ErrorRetryView / EmptyView）
├── core/        无业务语义的能力：异常、Result、日志、三态状态、复用层、控制消息、投流协议模型
└── feature/
    ├── settings/  服务地址与凭据
    ├── device/    设备列表（复用层 GTRC）
    ├── stream/    投流会话与投流页
    └── shell/     M1 WebView 壳
docs/            协议实测记录
tools/probe.dart M0 协议探测脚本
```

## 下一步

- **Windows 原生解码的实机复验**：链路与代码已就绪（见 [AGENTS.md](AGENTS.md) §12），
  但本机没有设备与真实服务端，画面/色彩/性能都还没在真机上跑过；首跑重点看
  是否有画面、红蓝是否颠倒、旋转后分辨率是否跟着变、CPU 占用。
- **Linux 原生解码**：桌面端暂时只能走设备卡片的"网页"入口。
- M3 余项：剪贴板同步、软键盘文本注入、双指缩放等手势增强。
- 若选 fMP4 重封装路线，需要先抓一次 `sendFrameMeta=true` 的报文（每帧前 12 字节帧信息），
  目前只验证了 `false`。
- 发布前把应用标识从 `flutter create` 默认的 `com.example` 改成自己的域名。
