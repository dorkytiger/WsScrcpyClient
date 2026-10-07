# CI：用 Forgejo Actions 打包 Android / web / Windows

工作流：[`.forgejo/workflows/build.yml`](../.forgejo/workflows/build.yml)；
本机打包（不走 CI）：`tools\build_release.cmd`（Windows / Android）、`tools/build_web.sh`（web）。
本文讲"怎么跑起来"和"出错了看哪里"。

> **★ 这是当前在用的 CI（自托管 runner，不花额度）。**
> 另有一份 GitHub Actions 工作流 `.github/workflows/build.yml`，但它**默认只手动触发** ——
> GitHub 私有仓库的 Actions 分钟数要吃每月免费额度。想切回去看 **§9**。
>
> Forgejo 也兼容读 `.gitea/workflows/`；本仓库统一用 `.forgejo/workflows/`。
> 工作流里的上下文用 `forgejo.*`（`github.*` 作为兼容别名同样可用）。

## 0. 先看清一件硬约束

**Flutter 的 Windows 桌面产物只能在 Windows 上构建**（官方不支持交叉编译），
而 **Android APK 与 web 在 Linux 上完全没问题**。所以本项目把 CI 分成两类 runner：

| job | 需要的 runner | 能不能用你现有的 `lingke`（`docker` / `ubuntu-latest`） |
|---|---|---|
| `verify`（analyze + test） | Linux 即可 | ✅ 能 |
| `android`（APK） | Linux 即可 | ✅ 能 |
| `web`（静态站点 zip） | Linux 即可 | ✅ 能 |
| `windows`（zip） | **Windows** | ❌ 不能，必须另注册一台 Windows runner |

**Apple 两端（iOS / macOS）不在 CI 里**：需要 macOS runner，自托管一台 Mac 只为构建不划算
（iOS 还要过签名）。Apple 包本机出：`flutter build ios --release --no-codesign` / `flutter build macos --release`。

`windows` 这个 job **默认是关的**（仓库变量 `WINDOWS_RUNNER=true` 才跑），
免得还没注册 Windows runner 时任务一直挂在队列里。
不想折腾 runner 的话，Windows 包直接本机出：

```powershell
tools\build_release.cmd -Platform windows     # 产物在 dist\
```

## 1. runner 需要什么

### Linux runner（现有那台，跑 `verify` + `android` + `web`）

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

## 1.1 方案 B：**不常在线的机器**（Mac / Windows）怎么接

**当前范围（2026-10-07 定的）**：CI 只跑 **`verify` + `android` + `web`**（都在 24/7 的 Linux
runner 上）。Mac / Windows 那两台不保证在线，**先不接**；接的时候按下面这条纪律来。

**硬纪律：任何"依赖某台机器在线"的 job 默认必须是关的** ——
job 一旦被派发就会**一直等** runner 出现（就是那条"等待带有以下标签的运行器"），
每次 tag 都会留下一条永远不开始的红记录，还得手动取消/重跑。

所以用**仓库变量开关**（方案 B）：

| 平台 | job 写法 | 默认 |
|---|---|---|
| Windows（已就绪） | `windows` job + `if: ${{ vars.WINDOWS_RUNNER == 'true' }}` | **关**（不设变量即不派发） |
| macOS / iOS（待加） | 照抄一个 `macos` job + `if: ${{ vars.MACOS_RUNNER == 'true' }}`；runner 必须是 **host 模式**（Apple 的构建进不了 Linux 容器） | 关 |

**人在线时的操作**：仓库 **Settings → Actions → Variables** 打开对应变量 →
在 Actions 里对该次运行点 **Re-run**（或手动 `workflow_dispatch`）→ 跑完再把变量关掉。

**为什么不改成"离线补齐脚本"**：那是我提的方案 A（机器上线后查 Release 缺哪个附件、自动构建上传），
不排队、能自动补，但要多维护一个脚本 + 一个写权限 token。**用户 2026-10-07 选了 B**；
如果哪天真嫌"每次要手动开变量"麻烦，再按 A 换（脚本形状：查 Forgejo API 的最近 N 个 tag →
比对 Release 附件名 → 缺哪个构建哪个 → 上传 → 已存在跳过，幂等）。

## 2. 注册 runner

### 2.1 Linux runner：标签 = "**标签名 : 用哪个镜像跑**"

这台 runner 跑在 Docker 里（docker-compose：`forgejo-runner` + `docker-in-docker`），
标签是**写在 compose 的 `command` 里的 `--label`**：

```yaml
command: >
  forgejo-runner daemon --config runner-config.yml
  --label docker:docker://data.forgejo.org/oci/node:20-bookworm        # ← 可拉（实测 200）
  --label ubuntu-latest:docker://data.forgejo.org/oci/ubuntu:24.04    # ← ★ 坏的
```

#### ★ 已经踩到的坑（2026-10-07）：`oci/ubuntu` 这个仓库**不存在**

症状：job 在 **Set up job** 阶段就结束，后面每步都是 0s：

```
Start image=data.forgejo.org/oci/ubuntu:24.04
Error response from daemon: failed to resolve reference "data.forgejo.org/oci/ubuntu:24.04":
  data.forgejo.org/oci/ubuntu:24.04: not found
```

**看起来像工作流报错，其实是 runner 的标签映射问题**（工作流里只有 `runs-on: ubuntu-latest`）。
直接问那个 registry 就能确认（实测，不是推测）：

```console
$ curl -s https://data.forgejo.org/v2/oci/ubuntu/tags/list
{"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry",
  "detail":{"name":"oci/ubuntu"}}]}                                    # ← 整个仓库都不存在

$ curl -s https://data.forgejo.org/v2/oci/node/tags/list | head -c 120
{"name":"oci/node","tags":["16-bullseye","16-buster","20","20-bookworm",…  # ← 有
```

也就是说 `oci/ubuntu:24.04` **不是 tag 写错，是那个路径从来没有过**，
而 `oci/node`、`oci/python`、`oci/golang`、`oci/alpine`、`oci/debian` 都有。

#### ★ 另一个镜像坑（2026-10-07 实测）：镜像里**只有 `actions/*`**，第三方 action 一律 404

现象（job 已经能起来，但取 action 时挂）：

```
☁️  git clone 'https://data.forgejo.org/subosito/flutter-action' # ref=v2
⚙️ [runner]: unable to probe object format ... remote: Not found.
   fatal: repository 'https://data.forgejo.org/subosito/flutter-action/' not found
```

runner 的 `DEFAULT_ACTIONS_URL` 默认指向 **Forgejo 自己的 action 镜像 `data.forgejo.org`**，
而那个镜像只镜像官方的 `actions/*`。探法（200 = 有、302 = 没有）：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  'https://data.forgejo.org/subosito/flutter-action/info/refs?service=git-upload-pack'
```

实测：`actions/checkout` / `actions/setup-java` / `actions/upload-artifact` / `actions/cache` = **200**；
`subosito/flutter-action` / `android-actions/setup-android` / `softprops/action-gh-release` = **302（没有）**。

**修法（工作流侧，不动服务器）**：第三方 action 写**全 URL**，官方 `actions/*` 继续走镜像。

```yaml
      - uses: actions/checkout@v4                              # 镜像里有 ✓
      - uses: https://github.com/subosito/flutter-action@v2     # 必须全 URL
      - uses: https://github.com/android-actions/setup-android@v3
```

> 如果那台 runner **连 github.com 也不通**，两条退路：
> ① 在 runner 的 `config.yml` 里把 `[actions] DEFAULT_ACTIONS_URL` 指到一个可达的镜像；
> ② 干脆不用第三方 action —— Flutter 用 `curl` 下 tar.xz + `tar -xJf` 自己装
> （还能顺手换国内镜像绕开 `storage.googleapis.com`），Android SDK 同理下 cmdline-tools。

#### ★★ 第三个坑（2026-10-07 实测）：这台 runner **连不上 `dl.google.com`**

在 `lingke` 上实测的连通性（用户跑的 curl）：

| 主机 | 结果 | 影响 |
|---|---|---|
| `github.com` | 200 | 第三方 action（全 URL）能取 ✓ |
| `storage.googleapis.com` | **400**（= 可达，Google 只是拒了根路径 HEAD） | Flutter SDK 能下 ✓ |
| `api.adoptium.net` | 200 | JDK 能下 ✓ |
| `repo.maven.apache.org` | 200 | Maven Central 能下 ✓ |
| **`dl.google.com`** | **000 / FAIL** | ❌ 既是 Android SDK 下载站，也是 Google Maven 的站（AGP/AndroidX 在上面） |

**两条修法（都已实施，纯工作流侧、不动服务器）**：

1. **Android SDK 组件改从腾讯镜像取 zip**（不用 `sdkmanager` —— 它只会去 `dl.google.com`）：

   ```
   https://mirrors.cloud.tencent.com/AndroidSDK/
     platform-36_r02.zip                    → platforms/android-36   （compileSdk 36）
     build-tools_r36_linux.zip              → build-tools/36.0.0    ★ 注意下划线
     platform-tools_r37.0.1-linux.zip       → platform-tools
     commandlinetools-linux-16111833_latest.zip → cmdline-tools/latest
   ```

   ★ **文件名陷阱**：Google 从 build-tools **35** 起把 `-` 换成了 `_`
   （`build-tools_r36_linux.zip`，而 34 是 `build-tools_r34-linux.zip`）。
   权威清单是 Google 的 `https://dl.google.com/android/repository/repository2-3.xml`
   （从能访问的机器上拉下来 grep 即可）。
   另外**必须手写许可文件**（`$SDK/licenses/android-sdk-license` 等），否则 AGP 直接拒绝构建。

2. **Gradle 仓库换阿里云镜像**：项目里写死 `google()` 的只有 4 个 `.gradle.kts`
   （`android/build.gradle.kts`、`android/settings.gradle.kts`，以及 Flutter SDK 的
   `packages/flutter_tools/gradle/{resolve_dependencies,settings}.gradle.kts`）。
   CI 里对**这次检出**做 `sed` 替换（不改仓库文件），并在末尾加一道**门禁**：
   只要还剩一处 `google()` 就报错退出 —— 否则它会去连不通的站、拖慢甚至挂掉构建。

   ```
   google()             → maven("https://maven.aliyun.com/repository/google")
   mavenCentral()       → maven("https://maven.aliyun.com/repository/public")
   gradlePluginPortal() → maven("https://maven.aliyun.com/repository/gradle-plugin")
   ```

> **还没验证的一个点**：`pub.dev` 那台机器通不通（`flutter pub get` 要用）。
> 如果不通，就在 workflow 里加 `PUB_HOSTED_URL=https://pub.flutter-io.cn`（Flutter 中国镜像）。

#### ★ 第四个坑（2026-10-07 实测）：`subosito/flutter-action` 需要容器里有 `jq`

```
装 Flutter（版本与 AGENTS.md §2 对齐）  1s
jq not found. Install it from https://stedolan.github.io/jq
⚙️ [runner]: exitcode '1': failure
```

`oci/node:20-bookworm` 里没有 `jq`，而那个 action 依赖它。**修法：干脆不用第三方 action** ——
自己下官方 tar.xz（版本从 `FLUTTER_VERSION` 环境变量来，与 AGENTS §2 对齐）：

```yaml
- name: 装 Flutter（自己下官方 tar.xz，不用第三方 action）
  run: |
    set -e
    FLUTTER_HOME="$HOME/flutter"
    if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
      URL="https://storage.googleapis.com/flutter_infra_release/flutter_infra_release/…"
      # 实际地址：https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz
      curl -fSL --retry 3 -o /tmp/flutter.tar.xz "$URL"
      tar -xJf /tmp/flutter.tar.xz -C "$(dirname "$FLUTTER_HOME")"
    fi
    echo "$FLUTTER_HOME/bin" >> "$GITHUB_PATH"
    git config --global --add safe.directory "$FLUTTER_HOME"   # 容器里 root 跑，否则 git 报 dubious ownership
    flutter --version
```

顺带三个纪律：

1. **「基础工具」步骤必须排在最前面**（`xz` 解 Flutter 的 tar.xz、`unzip` 解 SDK 的 zip、
   `zip` 给 web 打包），否则后面的解压步骤会以 `command not found` 挂；
2. **官方 `actions/*` 用短名即可**（镜像里有：实测 `checkout`/`setup-java`/`upload-artifact`/`cache` 都 200），
   只有第三方 action 才需要写全 URL（或者干脆像这里一样不用它）；
3. 确认 tarball 地址的最稳方式：拉
   `https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json`，
   找 `version == $FLUTTER_VERSION` 的 `archive` 字段（实测 3.47.1 → `stable/linux/flutter_linux_3.47.1-stable.tar.xz`）。

#### ★ 第五个坑（2026-10-07 实测）：`sdkmanager` 会去下 "Android CLI"，Flutter 又会因此去装 NDK

`assembleRelease` 阶段挂：

```
WARNING: The SDK Manager CLI tool (sdkmanager) is deprecated. Android CLI will be used instead.
Downloading Android CLI...
Error: Failed to download from https://dl.google.com/android/cli/latest/linux_x86_64/android-cli
  io: Connection reset by peer (os error 104)
> Process 'command '/root/android-sdk/cmdline-tools/latest/bin/sdkmanager'' finished with non-zero exit value 1
```

**链条**（都有代码证据）：

1. 新版 `cmdline-tools` 里的 `sdkmanager` 只是个**壳**，第一次用就去 `dl.google.com` 下
   "Android CLI" → 这台机器不通 ✗；
2. 而 Flutter 的工具侧 `flutter_tools/lib/src/android/gradle.dart`（约 1070 行）
   **只在 SDK 里有"可用的 sdkmanager"时才传** `-Pflutter.sdkManagerPath=…`；
3. Flutter 的 gradle 插件 `FlutterPluginUtils.forceNdkDownload()` 一看到这个属性，
   就认为"NDK 可以自动装"，于是**真的调 sdkmanager 去装 NDK** ✗ → 上一条的壳 → 挂。

**修法：CI 的 SDK 里干脆不装 `cmdline-tools`**（没有 `sdkmanager`）：

- 我们的包本来就是**自己解压装的**、许可文件**自己写的**，根本不需要 sdkmanager；
- 没有它 → `flutter.sdkManagerPath` 不传 → Flutter 走
  **synthetic external native build** 兜底（不需要 NDK，`flutter build apk` 正常）；
- 副作用（预期）：`flutter doctor -v` 会报一行 `cmdline-tools component is missing` ❌ ——
  那一步是 `continue-on-error`，不影响构建。

> 相关：如果哪天真的需要 NDK，得把 NDK 的 zip 也从镜像下好放进 SDK（同理绕开 dl.google.com）。

#### 修法（二选一）

**① 改 runner 的标签（推荐，一处改完所有仓库都受益）**

```yaml
# docker-compose.yml 里 runner 的 command
--label ubuntu-latest:docker://data.forgejo.org/oci/node:20-bookworm
```

```bash
docker compose up -d forgejo-runner     # 让新标签生效
```

**② 不改服务器，改工作流**：把 `verify` / `android` / `web` 三个 job 的
`runs-on: ubuntu-latest` 换成 `runs-on: docker` —— 那个标签本来就指向可拉的
`oci/node:20-bookworm`。代价是标签名不好读（"docker"其实指的是执行方式）。

#### 这两个镜像里有什么、没什么（别假设）

| | 说明 |
|---|---|
| `node` ✓ | **JS action 必需**（`actions/checkout`、`upload-artifact` 都是 JS，要容器里有 node）—— 这也是**不能**把标签指向纯 `ubuntu`/`alpine` 镜像的原因 |
| `flutter` ✗ | 由工作流的 `subosito/flutter-action` 自己下载（需要 `curl`/`tar`/`xz`，buildpack-deps 基础镜像都有） |
| `java` ✗ | Android 那步由 `actions/setup-java` 装 JDK 17 |
| `Android SDK` ✗ | 由 `android-actions/setup-android@v3` 装（**GitHub 的 ubuntu-latest 自带 SDK，容器里没有**，所以这一步不能省） |
| `zip` / `unzip` ? | 不一定有 → 工作流里加了"基础工具"一步按需 `apt-get install` |

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

## 2.4 ★ 让 CI 不再每次重下：宿主机准备一份、挂进容器

**问题**：job 容器是临时的，每次跑都要重下 Flutter（~1GB）+ Android SDK（几个 zip）+
Gradle/pub 依赖 —— 一个 android job 有好几分钟纯粹花在下载上。

**做法**（用户 2026-10-07 定的）：宿主机装一份，runner 把它挂进 job 容器，
工作流**优先用挂进来的、找不到才回退去下载**（所以在别的 runner / 本地跑也不会坏）。

### ① 宿主机一次性准备（在 lingke 上，用你自己的账号，不要 sudo）

```bash
tools/prepare_ci_host.sh                  # 默认装到 ~/dev
DEV_DIR=/srv/ci tools/prepare_ci_host.sh  # 或者换个目录
```

它做的事（幂等，只往 `$DEV_DIR` 写）：下 Flutter tar.xz → `flutter precache --linux --web --android`；
从腾讯镜像取 4 个 SDK zip 解到规范目录；写好 AGP 需要的**许可文件**；
建好 `gradle-home/` 与 `pub-cache/`。装完会打印各目录大小与下一步的挂载片段。

### ② runner 侧挂进容器

> ⚠️ 你们这套是 **dind**（docker-in-docker）：job 容器是 dind 里的 docker 创建的，
> 所以**宿主目录必须先挂给 dind 容器**，job 容器再引用 dind 内的那个路径
> （下面的 `/host-dev`）。

```yaml
# docker-compose.yml
services:
  docker-in-docker:
    volumes:
      - dind-storage:/var/lib/docker
      - /home/warren/dev:/host-dev          # ← 新增：让 dind 看见它
```

```yaml
# runner-config.yml（runner 的配置文件，daemon --config 指的那个）
container:
  valid_volumes:
    - /host-dev/**                          # 允许 job 挂载的宿主目录白名单
  options: "--volume /host-dev:/opt/dev"    # 给每个 job 容器都挂上
```

```bash
docker compose up -d        # 让配置生效
```

### ③ 工作流里怎么用（已实现）

- 顶层 env：`CI_HOST_DIR: /opt/dev`；
- 「装 Flutter」步骤：`$CI_HOST_DIR/flutter` 有就直接用，否则回退下 tar.xz；
- 「装 Android SDK」步骤：`$CI_HOST_DIR/android-sdk/platforms/android-36` 存在就直接用，
  否则才从腾讯镜像下（而且**缺哪个补哪个**）；
- 「缓存目录」步骤：能写 `$CI_HOST_DIR/{gradle-home,pub-cache}` 就把
  `GRADLE_USER_HOME` / `PUB_CACHE` 指过去（Gradle 依赖与 pub 包也不再每次重下），
  挂了只读或没挂就退回容器内缓存。

### ④ JDK 也放进挂载目录（别用 `actions/setup-java`）

`oci/node:20-bookworm` 里**没有 JDK**，而 Gradle/AGP 自己要一个 JVM —— 不装的话
`flutter build apk` 第一步就报 `Unable to locate a Java Runtime`。
原来用 `actions/setup-java@v4`：它每次从 `api.adoptium.net` → github releases 下
**~190MB** Temurin（实测 **1m28s**，而且工具缓存落在临时容器里，下个 job 还得再下）。

现在：工作流的 JDK 步骤**优先用 `$CI_HOST_DIR/jdk`**（`prepare_ci_host.sh` 会装好），
没有才回退下载 —— 回退时用 Adoptium 的 **"latest" 重定向地址**，一次 `curl -fSL` 直接拿到
tar.gz，不需要 `jq`/`python` 解析版本 JSON：

```
https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse
```

### ⑤ 两个注意点

1. **挂载要可写**（不要加 `:ro`）：Flutter 运行时会写 `bin/cache`，Gradle/pub 缓存也要写。
   代价是容器以 root 跑，**写进去的新文件属主是 root**；宿主机上想继续用这些目录时
   `sudo chown -R "$USER" ~/dev` 一下即可。
2. **Flutter 版本升级**：改工作流顶层 `FLUTTER_VERSION` 后，宿主机上删掉 `$DEV_DIR/flutter`
   再跑一次 `prepare_ci_host.sh`（或直接在宿主机上 `git -C $DEV_DIR/flutter checkout <tag>`）。

## 3. 工作流做了什么

| job | runner | 作用 | 产物 |
|---|---|---|---|
| `verify` | `ubuntu-latest` | `pub get` → `dart analyze lib test tools` → `flutter test` | 无（门禁） |
| ~~`web`~~ | — | **还没加**（见本节开头的缺口说明） | — |
| `android` | `ubuntu-latest` | 装 JDK17 + Flutter + Android SDK → `flutter build apk --release` | `android-apk`：`ws_scrcpy_client-<版本>.apk` |
| `web` | `ubuntu-latest` | `tools/build_web.sh`（自带 `--no-web-resources-cdn` 与运行时资源准备）→ zip | `web-dist`：`…-web.zip` |
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
| job 在 **Set up job** 阶段就失败，报 `failed to resolve reference "data.forgejo.org/oci/ubuntu:24.04": not found` | runner 的 `--label` 把 `ubuntu-latest` 映射到了**不存在的仓库** `oci/ubuntu`（那个 registry 只有 node/python/golang/alpine/debian） | 把那一行换成 `oci/node:20-bookworm` 后 `docker compose up -d`（见 §2.1）；或把工作流改成 `runs-on: docker` |
| `verify`/`android`/`web` 报 `Cache Service Url not found`（或 cache 相关错误） | runner 没开缓存服务，而 `subosito/flutter-action` 的 `cache: true` 会调用 `@actions/cache` | 工作流里已设 `cache: false`（跑通优先）；想提速就在 compose 的 runner 配置里开 `cache.enabled: true` 再打开 |
| `android` job 卡在装 SDK 或报下载失败 | `android-actions/setup-android` 要从 `dl.google.com` 取 cmdline-tools，`setup-java` 要访问 Adoptium | 在 runner 那台机器上 `curl -I https://dl.google.com` / `https://api.adoptium.net` 验通；不通就配代理或换自带 SDK 的镜像 |
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

## 9. 以后想切到 GitHub Actions？（工作流已经写好，默认关着）

`.github/workflows/build.yml` 是一份**完整但默认不自动跑**的工作流（只留 `workflow_dispatch`）：
它比 Forgejo 这份多了**iOS + macOS**（GitHub 自带 `macos-latest`）和**tag 自动发 Release**。

**为什么默认关着**：GitHub **私有仓库**的 Actions 要吃每月免费额度（自托管 Forgejo runner 不吃）。
如果这个仓库可以**公开**，GitHub 对公开仓库的 Actions 分钟数是免费的 —— 那种情况下直接启用最省事
（以 GitHub 当前计费页为准）。

**启用步骤**：
1. 打开 `.github/workflows/build.yml`，把 `on:` 里注释掉的 `push` / `pull_request` 恢复，
   并删掉开头那段"默认不自动跑"的说明；
2. 按需在 **Settings → Secrets and variables → Actions** 配 Android 签名（见 §6）；
3. 把代码推到 GitHub（`gh repo create` 或网页建仓后 `git remote add github …`）；
4. 打 tag（`git tag v1.0.0 && git push --tags`）就会自动出 Release。

**两份工作流可以并存**：Forgejo 只读 `.forgejo/workflows/`，**不读** `.github/workflows/`，
所以不会重复跑。
