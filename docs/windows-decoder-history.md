# Windows 原生解码：已解决的历史排查记录（§12.1 / §12.4 / §12.5 / §12.6 全文）

> 这些内容原本在 `AGENTS.md` 的 §12.1 / §12.4 / §12.5 / §12.6，**已经全部修完并验证**。
> 搬出来的原因：`AGENTS.md` 受 **64KB 工作区指令预算**限制，超了会被从中间截断（结果就是把
> §12.8 的验收判据切掉）。所以 AGENTS.md 只保留**结论、操作规则与判据**，完整证据链（日志原文、
> 反汇编、minidump 调用链、性能数据）留在本文件。
>
> 编号沿用 AGENTS.md 的 §12.x，正文里的交叉引用（如"见 §12.5"）指的就是本文件的对应小节。

---
### 12.1 `0xC0000005` 崩溃（偏移 0x58CA5 / 0x57255 / 0x5AAE5）：根因与修法

**结论（指令级 + 栈级双重证据，不是推测）**

1. 三次崩溃的偏移都随构建漂移（`0x57255` → `0x58CA5` → `0x5AAE5`），
   所以**跨构建比地址没有意义**；正确做法是用"当次构建的 exe + disasm"做符号化。
2. 用 `dumpbin /disasm` 反汇编当次 exe（image base `0x140000000`）：`0x58CA5` / `0x5AAE5`
   落在 `std::_Func_class<void>::operator()` 内部（即调用一个已失效的 `std::function<void()>`：
   `mov rax,[rsp+20h]` → `mov rax,[rax]` 读调用目标的 vtable）；`0x57255` 落在
   `BinaryMessengerImpl::SetMessageHandler::ForwardToHandler`（通道派发路径），属同族问题。
3. 最硬的一条证据来自 **minidump 栈**（`%LOCALAPPDATA%\CrashDumps\ws_scrcpy_client.exe.*.dmp`，
   本机装了 WER 会留 dump）：用栈上返回地址还原出的调用链
   （`std::_Func_class<void>::operator()` → 接管 `unique_ptr<std::function<void()>>` → 调用任务 → delete）
   **逐条对应 SDK 里 `FlutterEngine::PostPlatformThreadTask` 传下去的 C 回调**，而全工程唯一调用
   它的地方就是 `flutter_window.cpp` 里"解码线程 → platform thread → `onSizeChanged`"那条尺寸反向推送。
   结论：**投递出去的尺寸回调任务活过了它捕获的状态**。
4. **为什么"日志文件从来没被创建过"不能作为证据**：事后用 `dumpbin /disasm` 逐条核对，
   10:10 与 10:35 两版 exe 的 `HandleVideoMethodCall` / `Impl::Start` 里
   **一条 `LogOnce` / `DebugLog` 调用都没有**（两次 dump 的调用列表里完全不存在）。
   那两个二进制是**加日志之前**的版本，所以"没有日志"只说明"那版没写日志"，
   不能推断崩溃点靠前。

**修法：把"推送"换成"回执 / 拉取"，整条投递路径删掉**

- 解码器不再持有 `std::function<void(uint32_t,uint32_t)>` 回调；尺寸写进内部加锁的
  `SizeState`，对外只暴露 `ScrcpyVideoDecoder::CurrentSize()`（任何线程可调）。
- 通道层在 `create` 与每次 `pushFrame` 的**回执**里带 `{width,height}`，
  并新增 `getSize` 供 Dart 主动拉。`flutter_window.cpp` 里的
  `PostSizeChanged` / `VideoChannelState` / `alive` 标记**整体删除**。
- 为什么这样就没有这个竞态：**跨线程投递这件事本身不存在了**。
  尺寸最多是"解码线程写、platform thread 在下次调用时读"，用一个 mutex 保护的
  值语义传递，没有函数对象、没有堆上任务、没有"投递出去之后谁还活着"的问题。
  顺带把 0x57255 那处通道派发风险也压下去：`OnDestroy` 里显式
  `SetMethodCallHandler(nullptr)` 摘掉捕获 `this` 的 handler（SDK 文档要求调用方自己摘），
  并用第一个成员 `destroying_` 做短路，保证窗口析构期间进来的调用不碰已销毁的对象。

### 12.4 "点投流立刻提示窗口正在销毁"（`destroying_` 未复位）——根因与修法

**现象**：窗口活得好好的、UI 可交互，但一点"投流"就弹
`PlatformException(window_destroyed, 窗口正在销毁)`，解码器永远建不起来。

**决定性日志**（真实运行）：
```
ScrcpyLog:    [2026-10-01 11:04:28.054 | +0ms] OnDestroy：开始收尾（…）
ScrcpyLog:    [2026-10-01 11:04:28.054 | +0ms] OnDestroy：解码器已释放、纹理已请求注销
ScrcpyLog:    [2026-10-01 11:04:28.054 | +0ms] OnDestroy：引擎已销毁（收尾完成）
FlutterWindow:[2026-10-01 11:04:28.056 | +2ms] 日志启动，文件=…
FlutterWindow:[2026-10-01 11:04:28.056 | +2ms] 模块已加载（FlutterWindow::OnCreate 入口）
FlutterWindow:[2026-10-01 11:04:29.189 | +1134ms] 阶段：ws_scrcpy/video 已注册（…）
FlutterWindow:[2026-10-01 11:04:38.117 | +10063ms] 窗口销毁后仍收到通道调用（已安全忽略）
```

**根因（不是"上一个实例的日志"）**：`OnDestroy` 的三条日志用**默认模块名**
`ScrcpyLog`，而 `FlutterWindow` 这个模块名是在 `OnCreate` 里才设的——所以这三条
**必然发生在同一次运行的 `OnCreate` 之前**。机制是：

1. `Win32Window::Create()` 的**第一句就是 `Destroy()`**
   （`windows/runner/win32_window.cpp:126`，Flutter 模板自带："确保窗口尚未创建"）；
2. `Destroy()` → 虚函数 `OnDestroy()`，命中我们的重写；
3. 我们的 `OnDestroy()` **无条件** `destroying_.store(true)`（旧实现第一句），
   而那次调用时窗口/引擎/通道**全都还不存在**（所以它打印的
   "引擎已销毁"是假的，这也是为什么它误导了一轮排查）；
4. 之后 `CreateWindow` → `OnCreate()`（`win32_window.cpp:149`）**没有任何地方复位该标记**；
5. 于是窗口活到 10 秒后，`HandleVideoMethodCall` 第一句 `if (destroying_)` 永远为真
   → 每个 `create` 都被拒绝成 `window_destroyed`。

**修法（治本，不回退上一轮成果）**：

- `FlutterWindow::OnCreate()` 第一句改成 `if (destroying_.exchange(false)) { 记日志 }`：
  修掉"一直为真"，同时给"同一进程内销毁后重建窗口"留安全网；
  真命中时会打 `OnCreate：已清除 Create 前置清理遗留的 destroying_ 标记`。
- `FlutterWindow::OnDestroy()` **先判断有没有东西可收尾**
  （`flutter_controller_` / `video_decoder_` / `video_channel_` 全为 null 就是
  "Create 的前置清理"）：这种情况**只打一条**
  `OnDestroy：窗口尚未完成创建（Create 的前置清理），无收尾动作`
  就返回，**不动 `destroying_`、也不谎称引擎已销毁**。
- **错误信息可区分**：`destroying_` 为真 → `window_destroyed`（窗口正在销毁）；
  `flutter_controller_ == nullptr` → **`window_not_ready`**（窗口尚未就绪，引擎未创建），
  两者不再共用"窗口正在销毁"这句话。
- 日志前缀加 **pid**：`[YYYY-MM-DD HH:MM:SS.mmm | +Nms | pid=NNN]`。日志文件是**追加**
  写的，IDE 反复运行时多实例记录会混在一起；没有 pid 就很容易把"上一实例的收尾"
  误读成"本实例先销毁后创建"（这次就是这么绕进去的）。
  日志模块还提前到 `FlutterWindow` **构造函数**里初始化，这样连"Create 前置清理"
  那条日志也带正确的模块名。

**教训（写进流程）**：跨进程/跨实例的日志混在一个文件里时，**先按 pid 分组再读**；
以及"日志里的顺序 ≠ 代码里的顺序"这件事，要用**模块名/前缀**这类结构性证据来判，
而不是凭时间戳先后下结论。

### 12.5 实机现象"进去黑屏 / 点一下才有反应 / 非常卡"——根因、修法、性能数据

**现象（用户原话）**：① 进去肯定黑屏；② 点一下按钮才有反应；③ 非常卡，完全用不了。

**黑屏根因（来自真实 `bundle.js` 的对照 + 实测，不是猜的）**

拿服务端网页端的实现逐条对照后，真正的差异是**我们发视频参数的方式**：

1. **我们连发了两条 `CHANGE_STREAM_PARAMETERS`**：初始信息头一到先发一条 `bounds: null`，
   紧接着 UI 布局好又发一条真实尺寸（例如 `1898x853`）。服务端会因此**重建两次编码器**，
   而重建后**不会立刻产出 IDR** → 客户端拿不到可解码的帧 → 黑屏，直到画面变化才来帧
   （用户感受到的"点一下才有反应"）。网页端是**布局尺寸已知后一次到位、只发一条**。
2. **我们没有回显服务端给的值**：初始信息头里服务端已经给了完整的 `VideoSettings`，
   实测夹具里是 `bitrate: 7340032, maxFps: 60, iFrameInterval: 10, bounds: 1856x960`；
   而我们用本地默认值覆盖成了 `bitrate: 8000000, maxFps: 0, iFrameInterval: 10, bounds: null`
   ——字段全不一样。网页端是**逐字段回显**服务端那份。

**修法（Dart 侧，`StreamSessionService`）**

- **首发只发一次、且一次到位**：`applyViewportBounds` 在"首发之前"只**记录**尺寸
  （`_reportedViewportBounds`），拿到 display 时带着它发**唯一一条**首发
  （`_scheduleFirstVideoSettings` → `_sendVideoSettings(display, bounds: …)`）。
  UI 未布局时等 `AppDefaults.settingsFallbackDelay`（300ms）后退化为"不带 bounds"发一条，
  之后 UI 报了尺寸再补一条（**退化路径**，正常不会走到）。
  `PlayerViewModel.applyViewportSize` **不再**做"已连接"判断——必须在连接前就把尺寸记下来。
- **回显服务端值**：以 `display.videoSettings` 为基准逐字段回显，
  只覆盖 `bounds`（我们的视口尺寸）与 `sendFrameMeta`（必须 false：我们解裸 Annex-B）。
  日志同时打"服务端初始头给的 VideoSettings"与"首发视频参数"，便于逐字段对照。
- **验证**：`test/feature/stream/stream_session_service_test.dart` 新增
  ①"首发只发一条且带 UI 最终尺寸，服务端重发初始头也不补发第二条"、
  ②"回显服务端值（bitrate 7340032 / maxFps 60 / iFrameInterval 10 / bounds 1856x960，
  不是本地默认 8000000/0）"、③"UI 尺寸晚到时兜底一条、随后补一条更新"、
  ④"未连接时上报尺寸不算失败（只记录，连接后首发带上它）"。

**关于自动唤醒（可选功能，不是黑屏的正解）**

曾经把"设备屏幕休眠 → 服务端不发帧 → 黑屏"当作根因并据此加了自动唤醒，**这个归因是错的**：
真实 `bundle.js` 里网页端根本不发唤醒键（`WAKEUP` 只命中常量表），说明服务端本来就会在需要时给帧。
因此自动唤醒**默认关**（`AppDefaults.wakeDeviceOnConnect = false`），可在投流页「更多」面板手动打开；
**不要再把它当黑屏的修复**去宣传或依赖——打开反而多两条 keycode 消息，增加与服务端网页端的差异。

**"非常卡"的归因（已被 §12.7★修正 与 §12.8 推翻，此处只留结论）**

- 不是 YUV→RGBA 换算（Debug 720p 4.14ms/帧），也不是那次整帧 memcpy（0.09–0.25ms）；
  这是当初"经数据判定不做 D3D11"的依据——**那个判断是错的**，因为它只量了 CPU 换算，
  漏掉了**每帧整帧 RGBA 上传（光栅线程 `glTexImage2D`）与锁竞争**。正解见 §12.8。
- 判据仍然是心跳里的 `帧间隔` vs `平均处理`、以及新增的 `光栅回调` 与 `队列等待`。

**教训**：①先测量后优化——数据说那条路只值 2–5%，于是不做，省下的是刚修完的那类风险；
②**对照参考实现**（服务端 `bundle.js`）比对着现象猜快得多：连发两条参数、不回显服务端值，
这两条都是"看一眼参考实现就能发现"的差异。

### 12.6 `ProcessOutput 0x80004005` 洪水 + "270 帧只解出 1~2 帧"——根因与修法

**现象（真机日志）**：
```
输出类型就绪：1920x1080 stride=1920（configure 阶段完成）   ← 真实码流是 1280x720
ProcessOutput 失败：0x80004005                       × 上千行（把 2MB 日志写满）
心跳：… 已解码 1 / 已发布 1 …                          ← 推了 270 帧，只成功 1~2 帧
WARNING 单帧解码过慢：37427ms
尺寸变化：1280x720 → 1920x1080 → 992x560 → 1280x720 → 992x560   ← 尺寸乱跳
```
用户感受：**几分钟才出一张图，完全不能用**。

**根因（两个独立缺陷，都在这一个文件里，必须一起修）**

1. **在喂样本之前协商输出类型 → 选到"默认类型"**。
   `DecodeThreadMain` 原来在 `FeedFrame` **之前**就调 `TrySelectOutputType()`。那一刻解码器
   还没看到 SPS，`GetOutputAvailableType` 给出的是**默认类型**（实测 `1920x1080`，正是探针量到的
   `cbSize = 4147200` 那个尺寸）。我们把它 `SetOutputType` 之后与真实码流（1280x720）不符，
   于是 `ProcessOutput` 一直失败。日志签名很清楚：`已解出第一帧` 出现在**第二次**协商之后。
2. **复用输出样本时没有把它清干净 → 每次都 E_FAIL**。
   旧 `ResetOutputSample()` 只做 `RemoveAllBuffers()` + `AddBuffer(同一个 buffer)`，
   而那个 `IMFMediaBuffer` 上还留着上一帧的 `CurrentLength`（我们只读、从不复位），
   等于把一个"已经装满数据的样本"再交给解码器。后果同样是 `0x80004005`。

这两条叠加，正好解释"**只有协商那一刻创建的新样本能成功一次**"：
270 帧进来的过程中，只有每次 `TrySelectOutputType()` 新造样本的那一刻能解出一帧。

**修法（都在 `windows/runner/scrcpy_video_decoder.cpp`）**

- **输出样本每轮现造**：删掉 `ResetOutputSample()` 与 `output_sample_` / `output_buffer_`
  两个可复用字段，只保留协商出来的容量 `output_buffer_bytes_`；新增
  `MakeOutputSample(bytes)`，`DrainOutput()` 每次 `ProcessOutput` 前新造一个干净样本
  （与首次协商成功时那条路径完全一致）。代价是每帧一次样本/缓冲分配，**正确性优先**；
  若以后 profiling 显示它有意义，也必须先证明"复位后复用"能被这个 MFT 接受再改回去。
- **协商顺序修正**：不再在喂入前协商。改为**先把 SPS/PPS 写进输入类型**
  （`MF_MT_MPEG_SEQUENCE_HEADER`，复用既有的 `ReinitializeInputType`），让解码器一开始就知道
  真实分辨率；协商由三条既有路径触发：`ProcessInput` 的 `MF_E_TRANSFORM_TYPE_NOT_SET`、
  `ProcessOutput` 的 `MF_E_TRANSFORM_STREAM_CHANGE`/`TYPE_NOT_SET`、
  以及"喂够 `kOutputTypeNegotiationFrames` 帧还没协商出来"的兜底。
- **自愈**：新增 `ForceRenegotiate()`。连续
  `kConsecutiveOutputFailuresBeforeRenegotiate`（5）次 `ProcessOutput` 失败就判定
  "当前输出类型与码流不符"，FLUSH → 重写参数集到输入类型 → 重选输出类型。
  这样即使第一次协商选错，也能恢复，而不会一辈子喂帧却一帧都解不出来。
- **缓冲容量算法统一**：删掉这里手写的 `stride * height * 3 / 2`（**奇数高度会少算半行**，
  853 就是奇数），改用换算侧的纯函数 `ValidateYuv420Source(..., SIZE_MAX).required_bytes`，
  再与 MFT 的 `cbSize` 取大者（`WsRequiredOutputBytes`）。这就是 §12.3 那条教训的落实：
  **不要维护第二份业务逻辑**。
- **日志限流**：`ProcessOutput 失败` / `ProcessInput 失败` / `丢弃一帧` 全部走
  `LogFailureThrottled`（同类前 3 次逐条打，之后每 100 次一条并带累计次数）。
  这次现场日志就是被几千行同类失败写满、把有用信息挤掉的——**失败日志本身成了排查障碍**。
- **心跳补计数**：`ProcessOutput 失败 N（最近 <HRESULT>）`、`ProcessInput 失败 N`、
  `流格式变化 N 次`、`强制重新协商 N 次`。心跳每秒一条，所以这些计数不会刷屏，
  但"解不出来"一眼可见。
- **措辞**：`输出类型就绪：…（configure 阶段完成）` → `…（首次协商 / 中途重新协商）`，
  并带上缓冲字节数与格式；`MF_E_TRANSFORM_STREAM_CHANGE` 单独打一条含"上一次输出 WxH"的简明日志。
  原来那句"configure 阶段完成"在中途重新协商时也在打，属于误导性措辞。

**本机可跑的验证**（`tools\run_yuv_test.cmd`，普通 + ASan 各一遍）：

- 新增"输出缓冲容量"一节的断言（共 **9653 项检查 0 失败**）：NV12/平面布局的容量公式、
  **奇数高度 853 的真实需求严格大于 `stride*h*3/2`**（证明旧公式确实少算）、宽高互换必须重算、
  1x1/3x3 的边界、容量"刚好够"接受而"少 1 字节"拒绝、非法输入（pitch=0 / width=0 /
  平面布局奇数 pitch / NV12 pitch 装不下一行交错色度）返回 0 从而跳过该候选类型。
- 复刻旧逻辑的 ASan 复跑仍然如期抓到 `heap-buffer-overflow`（根因证明没有失效）。

**真机验收看这几行**：`输出类型就绪：…（首次协商）` 里的宽高应等于服务端初始头报的分辨率
（例如 1280x720，**不该**再是 1920x1080）；心跳里 `ProcessOutput 失败` 应该很小甚至为 0、
`已解码/已发布` 持续增长；万一出现 `连续 5 次 ProcessOutput 失败（第 N 次强制重新协商）`，
说明自愈路径被触发了——那时把前后 10 行发回来即可定位。

