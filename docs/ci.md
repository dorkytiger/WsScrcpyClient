# CI：用 Forgejo Actions 打包 Windows / Android

工作流：[`.forgejo/workflows/build.yml`](../.forgejo/workflows/build.yml)；
本机打包（不走 CI）：`tools\build_release.cmd`。
本文讲"怎么跑起来"和"出错了看哪里"。

> Forgejo 也兼容读 `.gitea/workflows/`；本仓库统一用 `.forgejo/workflows/`。
> 工作流里的上下文用 `forgejo.*`（`github.*` 作为兼容别名同样可用）。

## 0. 先看清一件硬约束

**Flutter 的 Windows 桌面产物只能在 Windows 上构建**（官方不支持交叉编译），
而 **Android APK 在 Linux 上完全没问题**。所以本项目把 CI 分成两类 runner：

| job | 需要的 runner | 能不能用你现有的 `lingke`（`docker` / `ubuntu-latest`） |
|---|---|---|
| `verify`（analyze + test） | Linux 即可 | ✅ 能 |
| `android`（APK） | Linux 即可 | ✅ 能 |
| `windows`（zip） | **Windows** | ❌ 不能，必须另注册一台 Windows runner |

`windows` 这个 job **默认是关的**（仓库变量 `WINDOWS_RUNNER=true` 才跑），
免得还没注册 Windows runner 时任务一直挂在队列里。
不想折腾 runner 的话，Windows 包直接本机出：

```powershell
tools\build_release.cmd -Platform windows     # 产物在 dist\
```

## 1. runner 需要什么

### Linux runner（现有那台，跑 `verify` + `android`）

工具链**不用预装**——工作流里现装（`subosito/flutter-action` + `actions/setup-java` +
`android-actions/setup-android`），因此只要：

- Docker（你已经在用）、能联网（拉 Flutter / Android SDK / pub 依赖 / Gradle 依赖）；
- 磁盘留足：Flutter SDK ~1.5GB + Android SDK ~2GB + Gradle 缓存，建议 ≥ 15GB 可用。

> **想快一点**（可选）：在 runner 的 `config.yml` 的 labels 里挂一个自带 Flutter+Android SDK 的镜像，
> 例如 `flutter:docker://ghcr.io/cirruslabs/flutter:3.47.1`，然后把工作流里 android 的
> `runs-on` 改成 `flutter`、并删掉"装 JDK/Flutter/Android SDK"三步。
> 代价是每次构建不受 Flutter 版本升级控制（镜像里是啥就是啥），所以默认没这么写。

### Windows runner（跑 `windows` job，可选）

| 依赖 | 说明 |
|---|---|
| Flutter SDK | 3.47.1 stable（与 `AGENTS.md` §2 一致），且 `flutter` 在 PATH 里 |
| Visual Studio | 2022/2026 + **使用 C++ 的桌面开发**（含 Windows 10/11 SDK） |
| Git | `actions/checkout` 需要 |
| 网络 | 首次要拉 pub 依赖与两个 NuGet 包（WebView2 / WIL） |

不需要 Android SDK（Windows job 只出桌面包）。自检：`flutter doctor -v` 里 Windows 那一项全绿。

## 2. 注册 runner

### 2.1 你已有的（Linux）

`lingke` 已在线（标签 `docker`、`ubuntu-latest`，状态空闲），工作流里
`runs-on: ubuntu-latest` 就是找它，**不需要动**。

### 2.2 新加一台 Windows runner（可选，为了 CI 也能出 Windows 包）

1. Forgejo 仓库 → **Settings → Actions → Runners → Create new Runner**，复制注册令牌。
2. 在 Windows 机器上装 `forgejo-runner`（[下载](https://code.forgejo.org/forgejo/runner/releases)），
   例如放到 `C:\forgejo-runner\`，然后注册：

```powershell
cd C:\forgejo-runner
.\forgejo-runner.exe register --no-interactive `
  --instance https://<你的 forgejo 地址> `
  --token <注册令牌> `
  --name win-builder `
  --labels "windows:host"
```

`windows:host` = 标签名 `windows`、**直接在宿主机上执行**（host 模式，不进容器）。
工作流里 `runs-on: windows` 找的就是它。Windows 上建议一律 host 模式。

3. `config.yml` 关键字段：

```yaml
runner:
  file: .runner
  labels:
    - "windows:host"
  capacity: 1        # 一台机器同时只跑一个 job，别让两端抢 CPU/磁盘
cache:
  enabled: true
```

4. **常驻方式：用"以当前用户身份运行的计划任务"，不要用 Windows 服务**：

```powershell
schtasks /Create /TN "forgejo-runner" /SC ONLOGON /RL LIMITED ^
  /TR "C:\forgejo-runner\forgejo-runner.exe daemon --config C:\forgejo-runner\config.yml" /F
schtasks /Run /TN "forgejo-runner"
```

> **为什么不用服务**：Windows 服务的账户环境与你登录账户不同，`flutter` 往往不在它的 `PATH` 里，
> 这类"你手动跑得好好的、CI 里 `flutter: command not found`"的坑基本都出在这里。

5. 最后在仓库 **Settings → Actions → Variables** 里加变量 `WINDOWS_RUNNER=true`，`windows` job 才会被派发。

> **★ 现状缺口：`web` 还没有 CI job。**
> 五端里 web 是唯一"编译不过不会有人提醒你"的目标。本机命令是
> `tools/build_web.sh`（带 `--no-web-resources-cdn`），加一个 job 只需要
> `flutter build web --release` 那一行 —— 但它还没加，**别以为 CI 绿了就说明 web 没坏**。

## 3. 工作流做了什么

| job | runner | 作用 | 产物 |
|---|---|---|---|
| `verify` | `ubuntu-latest` | `pub get` → `dart analyze lib test tools` → `flutter test` | 无（门禁） |
| ~~`web`~~ | — | **还没加**（见本节开头的缺口说明） | — |
| `android` | `ubuntu-latest` | 装 JDK17 + Flutter + Android SDK → `flutter build apk --release` | `android-apk`：`ws_scrcpy_client-<版本>.apk` |
| `windows` | `windows`（需变量开启） | 取原生依赖 → `flutter build windows --release` → zip | `windows-x64`：`ws_scrcpy_client-<版本>-windows-x64.zip` |

- **触发**：推 `main`/`master`、打 `v*` tag、PR、手动 `workflow_dispatch`。
- **版本注入**：tag 形如 `v1.2.3` 时自动 `--build-name=1.2.3 --build-number=<run number>`；
  分支推送沿用 `pubspec.yaml` 的 `1.0.0+1`。
- **按 ABI 拆分**：手动触发时勾 `split_abi`，额外产出 `-armeabi-v7a` / `-arm64-v8a` / `-x86_64` 三份
  （含 redroid 用的 x86_64）；默认打 universal 一份。
- **并发**：同一 ref 上新构建会取消旧构建，避免排队堆积。

## 4. 本机打包（推荐先跑这个，能排除一大半 CI 环境问题）

```powershell
tools\build_release.cmd                        # Windows + Android 都出，产物在 dist\
tools\build_release.cmd -Platform windows       # 只出 Windows
tools\build_release.cmd -Platform android       # 只出 Android
tools\build_release.cmd -Version 1.2.3 -BuildNumber 7
tools\build_release.cmd -SkipTests              # 跳过 analyze/test，赶紧出包
```

它和 CI 走同一套步骤（同样先 prepare 依赖、同样的产物命名），所以
"本机能过、CI 不过"基本只剩环境差异（Flutter 版本、SDK、JDK）。

## 5. 为什么 Windows 依赖那一步这么特殊

`webview_all_windows` 的 CMake **每次构建**都会执行
`nuget.exe install Microsoft.Web.WebView2 / Microsoft.Windows.ImplementationLibrary`。
本项目把这条链改成了"离线 + 只写工作区"（细节见 `AGENTS.md` §3.1）：

- `windows/CMakeLists.txt` 把 CMake 的 `NUGET` 变量预置成 `tools\nuget_shim.cmd`；
- shim 优先复用 `build\windows\x64\packages`，缺失时从 **`.tmp\nuget-source\*.nupkg`** 自己解包
  （用系统自带 `tar.exe`），**构建期完全不需要 nuget.exe，也不需要联网**；
- `.tmp\` 不进版本库，所以新克隆/CI 必须先把两个 `.nupkg` 放进去 —— 这就是
  `tools\prepare_windows_deps.ps1 -Online` 干的事（从 nuget.org 的 flat 端点下载）。

**`-Online` 只给 CI 与干净机器用**：作者机默认"完全离线、缺包就报错并给出补包办法"。

## 6. Android 签名（现在是 debug key，上架前必须换）

`android/app/build.gradle.kts` 里 release 目前用 **debug 签名**，所以
`flutter build apk --release` 能出包能装，但**不能上架**、也不能与正式包共存升级。

换正式签名（**keystore 绝不进仓库**）：

1. 生成：`keytool -genkeypair -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias ws_scrcpy`
2. 本地：把口令与路径写进 `android/key.properties`（加进 `.gitignore`），Gradle 读它；
   CI：用 **Settings → Actions → Secrets** 注入 `KEYSTORE_BASE64` / `KEYSTORE_PASSWORD` /
   `KEY_ALIAS` / `KEY_PASSWORD`，工作流里 base64 解码成文件再构建。
3. `build.gradle.kts` 加 `signingConfigs.create("release"){...}`，并在
   `key.properties` 存在时用它、否则回落到 debug（这样本地与 CI 都不会因缺密钥直接失败）。

> 这一步没替你做：它会改变你现有本地构建的签名行为，需要你先定 keystore 口径。
> 要的话我按"有 key.properties 用正式签名、没有就 debug"接上。

## 7. 常见故障对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| `windows` job 一直"等待中" | 没有标签为 `windows` 的 runner（现有 `lingke` 是 Linux/Docker） | 注册 Windows runner（§2.2），或先关掉它（别设 `WINDOWS_RUNNER` 变量），Windows 包用 `tools\build_release.cmd -Platform windows` |
| 下载 action 失败 / `uses:` 解析不了 | runner 的 `DEFAULT_ACTIONS_URL` 指不到 GitHub 或代理不通 | 在 runner 的 `config.yml` 里设 `[actions] DEFAULT_ACTIONS_URL = https://github.com`（或把 action 从内网镜像取） |
| `[nuget_shim] ERROR: WebView2 / WIL packages are missing` | 干净 checkout 没跑取包那步 | 工作流已含 `prepare_windows_deps.ps1 -Online`；若仍报错，看它上面一条下载是否被网络拦了 |
| `flutter: command not found`（Windows runner） | runner 以服务账户运行，PATH 不含 Flutter | 改用"以本人身份的计划任务"（§2.2 第 4 步） |
| Android：`Unable to locate Android SDK` | `ANDROID_SDK_ROOT` 没设 | 工作流用 `android-actions/setup-android` 设置；若换成自带 SDK 的镜像则不需要它 |
| Gradle 报 Java 版本不符 | JDK 不是 17 | 用工作流里的 `actions/setup-java@v4`（temurin 17） |
| Android 构建特别慢（每次重下 SDK/Gradle） | Docker runner 是临时容器，缓存不留 | 给 runner 挂 volume，或用 `actions/cache` 缓存 `~/.pub-cache`、`~/.gradle`、`/root/.android` |
| `upload-artifact@v4` 报 token/后端错误 | 部分 Forgejo 版本 v4 还需额外配置 | 用 **v3**（本工作流就是 v3） |
| tag 推了但版本号没变 | ref 不是 `v*` 形式 | tag 用 `v1.2.3`；工作流据 `forgejo.ref_name` 判断 |
| runner 磁盘越来越大 | Flutter/Android/Gradle 缓存累积 | 定期清 `~/.gradle`、`build/`；pub 缓存可留 |

## 8. 自动发 Release（可选）

Forgejo **不会**像 GitHub 那样自带 `secrets.GITHUB_TOKEN`，需要在
仓库 **Settings → Actions → Secrets** 里加一个具名 token（写权限），
然后取消 `build.yml` 末尾 `release` job 的注释并把 `token:` 指向该 secret
（用官方 `actions/forgejo-release@v2`）。不配也行 —— 产物从 Actions 页面的
Artifacts 下载，日常够用。
