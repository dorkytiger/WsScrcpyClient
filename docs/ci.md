# CI：用 GitHub Actions 打包五端

工作流：[`.github/workflows/build.yml`](../.github/workflows/build.yml)；
本机打包（不走 CI）：`tools\build_release.cmd`（Windows / Android）、`tools/build_web.sh`（web）。

> **为什么从自托管 Forgejo 换到 GitHub**：`windows-latest` 与 `macos-latest` 都是 GitHub 自带的，
> 于是"**Flutter 的 Windows 桌面产物只能在 Windows 上构建**"这条硬约束不再需要自己注册 runner；
> 另外 `secrets.GITHUB_TOKEN` 自带，发 Release 也不用另配 token。

## 0. 先看清两条硬约束

| 约束 | 后果 |
|---|---|
| **Windows 桌面产物只能在 Windows 上构建**（官方不支持交叉编译） | `windows` job 必须 `runs-on: windows-latest`；别把 Windows 包塞进 Linux job |
| **macOS / iOS 只能在 macOS 上构建**，而且 macOS runner **按 10 倍计费** | 所以 iOS 与 macOS 合在**一个** `apple` job 里先后构建，只占一次 macOS 机器时间 |

Android 与 web 在 Linux 上完全没问题。

## 1. 工作流做了什么

| job | runner | 作用 | 产物 |
|---|---|---|---|
| `verify` | `ubuntu-latest` | `flutter pub get` → `dart analyze lib test tools` → `flutter test` | 无（门禁） |
| `android` | `ubuntu-latest` | JDK17 + Flutter → `flutter build apk --release` | `android-apk`：`ws_scrcpy_client-<版本>[-<abi>].apk` |
| `web` | `ubuntu-latest` | `tools/build_web.sh`（自带 `--no-web-resources-cdn` 与运行时资源准备） | `web-dist`：`…-web.zip` |
| `windows` | `windows-latest` | 取原生依赖 → `flutter build windows --release` → `Compress-Archive` | `windows-x64`：`…-windows-x64.zip` |
| `apple` | `macos-latest` | `flutter build ios --no-codesign` + `flutter build macos` | `apple-builds`：`…-ios.ipa`（未签名）+ `…-macos.zip` |
| `release` | `ubuntu-latest` | 只在推 **`v*` tag** 时跑：取回全部产物 → 建 Release | GitHub Release（带宽度的自动更新日志） |

- **依赖关系**：四个构建 job 都 `needs: verify` —— 静态检查或单测挂了就不浪费构建时间。
- **触发**：推 `master` / `main`、推 `v*` tag、PR（`opened/synchronize/reopened/ready_for_review`）、
  手动 `workflow_dispatch`（可勾 `split_abi` 出三份按 ABI 拆分的 APK）。
- **并发**：同一 ref 上新构建会取消旧构建（`concurrency.cancel-in-progress`）。
- **版本注入**：ref 形如 `v1.2.3` 时自动 `--build-name=1.2.3 --build-number=<run number>`；
  分支推送沿用 `pubspec.yaml` 的版本。

## 2. 需要配的 Secrets

**现在一个都不需要**（`GITHUB_TOKEN` 是自带的）。想换成正式签名时见 §5。

## 3. 本机打包（推荐先跑这个，能排除一大半 CI 环境问题）

```powershell
tools\build_release.cmd                        # Windows + Android 都出，产物在 dist\
tools\build_release.cmd -Platform windows      # 只出 Windows
tools\build_release.cmd -Platform android      # 只出 Android
tools\build_release.cmd -Version 1.2.3 -BuildNumber 7
tools\build_release.cmd -SkipTests             # 跳过 analyze/test，赶紧出包
```

```bash
tools/build_web.sh            # web 产物在 build/web（挂子路径：tools/build_web.sh /app/）
tools/run_vt_replay_probe.sh  # Apple 解码器离线自测（不需要设备/服务端）
tools/run_yuv_test.cmd        # Windows 的 YUV→RGBA 边界自测（含 ASan 一遍）
```

## 4. 为什么 Windows 依赖那一步这么特殊

`webview_all_windows` 的 CMake **每次构建**都会执行
`nuget.exe install Microsoft.Web.WebView2 / Microsoft.Windows.ImplementationLibrary`。
本项目把这条链改成了"离线 + 只写工作区"（细节见 `AGENTS.md` §3.1）：

- `windows/CMakeLists.txt` 把 CMake 的 `NUGET` 变量预置成 `tools\nuget_shim.cmd`；
- shim 优先复用 `build\windows\x64\packages`，缺失时从 **`.tmp\nuget-source\*.nupkg`** 自己解包
  （用系统自带 `tar.exe`），**构建期完全不需要 nuget.exe，也不需要联网**；
- `.tmp\` 不进版本库，所以干净 checkout 必须先把两个 `.nupkg` 放进去 —— 这就是 CI 里那一步
  `tools\prepare_windows_deps.ps1 -Online` 干的事（从 nuget.org 的 flat 端点下载）。

**`-Online` 只给 CI 与干净机器用**：作者机默认"完全离线、缺包就报错并给出补包办法"。

## 5. Android 签名（现在是 debug key，上架前必须换）

`android/app/build.gradle.kts` 里 release 目前用 **debug 签名**，所以
`flutter build apk --release` 能出包能装，但**不能上架**、也不能与正式包共存升级。
CI **没有**替你接这一步（接一半会让"有 secret / 没 secret"两种状态行为不一致）。

换正式签名（**keystore 绝不进仓库**）：

1. 生成：`keytool -genkeypair -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias ws_scrcpy`
2. 本地：把口令与路径写进 `android/key.properties`（加进 `.gitignore`），Gradle 读它；
   CI：在 **Settings → Secrets and variables → Actions** 加 `KEYSTORE_BASE64` /
   `KEYSTORE_PASSWORD` / `KEY_ALIAS` / `KEY_PASSWORD`，工作流里 base64 解码成文件再构建。
   那一步建议写成 `if: env.KEYSTORE_BASE64 != ''`（secret 不存在就跳过，
   而不是写一个空 jks 让签名炸掉）。
3. `build.gradle.kts` 加 `signingConfigs.create("release"){...}`，并在
   `key.properties` 存在时用它、否则回落到 debug（这样本地与 CI 都不会因缺密钥直接失败）。

## 6. 常见故障对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| `verify` 里 widget 测试偶发失败 | 有些测试对画布尺寸敏感（AGENTS §9.2 有过一次教训） | 本地复跑确认；测试里已显式设定画布尺寸，别依赖默认 800x600 |
| Android：`Unable to locate Android SDK` / 缺 platform | GitHub runner 自带 SDK，但缺的组件要 Gradle 自己补装 | 一般不用管；真拦住了就加一步 `android-actions/setup-android@v3` 指定 `packages:` |
| Gradle 报 Java 版本不符 | JDK 不是 17 | 工作流用 `actions/setup-java@v4`（temurin 17）；**别为了图快删掉这一步** |
| `windows` job 报 `[nuget_shim] ERROR: WebView2 / WIL packages are missing` | 干净 checkout 没跑取包那步 | 确认 `prepare_windows_deps.ps1 -Online` 那一步通过（失败通常是 nuget.org 被网络拦） |
| Windows 步骤里的中文变问号/乱码 | PowerShell 5.1 读无 BOM UTF-8 的已知行为 | 工作流里 `run:` 的提示文字**一律写英文**（这是刻意的，别"修"成中文） |
| `apple` job 报 CocoaPods 相关错误 | `flutter_secure_storage` 不支持 SPM，Flutter 会对它回退到 CocoaPods | macos-latest 自带 CocoaPods；本地没装时 `brew install cocoapods` |
| macOS 分钟数不够用 | macOS runner 按 10 倍计费 | `apple` job 已合并 iOS + macOS；再紧张就给它加 `if:` 只在 tag 时跑 |
| tag 推了但版本号没变 | ref 不是 `v*` 形式 | tag 用 `v1.2.3`；工作流据 `github.ref_name` 判断 |
| Release 里没有产物 | `release` 只在 tag 上跑，且要四个构建 job 都成功 | 看那次 run 里哪个 job 红了；产物本身也能从 Actions 页面的 Artifacts 下载 |
