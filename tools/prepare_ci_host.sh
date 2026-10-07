#!/usr/bin/env bash
# 在 **CI 宿主机**（lingke）上一次性准备 Flutter / Android SDK / 各种缓存目录，
# 之后由 runner 把它们挂进 job 容器，CI 里就**一个字节都不用再下**（见 docs/ci.md §2.4）。
#
# 用法（在 lingke 上，用你自己的账号，**不要 sudo**）：
#   tools/prepare_ci_host.sh              # 默认装到 ~/dev
#   DEV_DIR=/srv/ci tools/prepare_ci_host.sh
#
# 幂等：已经就绪的东西会跳过；只往 $DEV_DIR 里写。
#
# ── 为什么自己下、不用 sdkmanager ────────────────────────────────────────
# 这台机器连不上 dl.google.com（实测 curl 返回 000），而 sdkmanager 只会去那儿。
# 所以 SDK 组件从腾讯镜像取 zip（文件名取自 Google 官方索引 repository2-3.xml，
# 注意 build-tools 从 35 起把 `-` 换成了 `_`）。
set -euo pipefail

DEV_DIR="${DEV_DIR:-$HOME/dev}"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.1}"
SDK_DIR="$DEV_DIR/android-sdk"
FLUTTER_DIR="$DEV_DIR/flutter"
BASE_SDK="https://mirrors.cloud.tencent.com/AndroidSDK"
BASE_FLUTTER="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux"

# 版本要跟项目对齐：compileSdk 36（Flutter 3.47 的默认值）→ platform 36 + build-tools 36.0.0
PLATFORM_ZIP="platform-36_r02.zip"
BUILD_TOOLS_ZIP="build-tools_r36_linux.zip"
PLATFORM_TOOLS_ZIP="platform-tools_r37.0.1-linux.zip"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

unpack_one() { # $1=zip 名  $2=目标目录
  local tmp
  tmp="$(mktemp -d)"
  curl -fSL --retry 3 --retry-delay 2 -o "$tmp/pkg.zip" "$BASE_SDK/$1"
  unzip -q "$tmp/pkg.zip" -d "$tmp/x"
  rm -rf "$2"
  mkdir -p "$(dirname "$2")"
  mv "$(find "$tmp/x" -mindepth 1 -maxdepth 1 | head -1)" "$2"
  rm -rf "$tmp"
  echo "    ✓ $1 → $2"
}

mkdir -p "$DEV_DIR" "$DEV_DIR/gradle-home" "$DEV_DIR/pub-cache"

# ── 1. Flutter SDK ───────────────────────────────────────────────────────
if [ -x "$FLUTTER_DIR/bin/flutter" ]; then
  echo "Flutter 已存在：$FLUTTER_DIR（跳过下载）"
else
  say "下载 Flutter $FLUTTER_VERSION 到 $FLUTTER_DIR"
  tmp="$(mktemp -d)"
  curl -fSL --retry 3 --retry-delay 2 -o "$tmp/flutter.tar.xz" \
    "$BASE_FLUTTER/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  tar -xJf "$tmp/flutter.tar.xz" -C "$DEV_DIR"
  rm -rf "$tmp"
  echo "    ✓ 解压到 $FLUTTER_DIR"
fi

say "预热 Flutter（首次会下 Dart SDK / 各平台引擎产物）"
export PATH="$FLUTTER_DIR/bin:$PATH"
export PUB_CACHE="$DEV_DIR/pub-cache"
git config --global --add safe.directory "$FLUTTER_DIR" 2>/dev/null || true
flutter --version
# linux(宿主) + web + android 三种产物都下好，容器里就不用再下
flutter precache --linux --web --android || flutter precache || true

# ── 1.5 JDK 17（Gradle/AGP 要一个 JVM；容器里没有，装上就不用每次下 190MB）───
JDK_DIR="$DEV_DIR/jdk"
if [ -x "$JDK_DIR/bin/java" ]; then
  echo "JDK 已存在：$JDK_DIR（跳过下载）"
else
  say "下载 Temurin 17 到 $JDK_DIR"
  tmp="$(mktemp -d)"
  # Adoptium 的 "latest" 重定向地址：直接跟着 302 拿到 GitHub 上的 tar.gz，不用解析 JSON
  curl -fSL --retry 3 --retry-delay 2 -o "$tmp/jdk.tar.gz" \
    "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"
  mkdir -p "$JDK_DIR"
  tar -xzf "$tmp/jdk.tar.gz" -C "$JDK_DIR" --strip-components=1
  rm -rf "$tmp"
fi
"$JDK_DIR/bin/java" -version 2>&1 | head -2

# ── 2. Android SDK ───────────────────────────────────────────────────────
say "准备 Android SDK 到 $SDK_DIR"
mkdir -p "$SDK_DIR/platforms" "$SDK_DIR/build-tools" "$SDK_DIR/licenses"

[ -d "$SDK_DIR/platforms/android-36" ] \
  && echo "    platform 36 已在（跳过）" \
  || unpack_one "$PLATFORM_ZIP" "$SDK_DIR/platforms/android-36"

[ -d "$SDK_DIR/build-tools/36.0.0" ] \
  && echo "    build-tools 36.0.0 已在（跳过）" \
  || unpack_one "$BUILD_TOOLS_ZIP" "$SDK_DIR/build-tools/36.0.0"

[ -d "$SDK_DIR/platform-tools" ] \
  && echo "    platform-tools 已在（跳过）" \
  || unpack_one "$PLATFORM_TOOLS_ZIP" "$SDK_DIR/platform-tools"

# ★ 故意**不装 cmdline-tools**：只要 SDK 里有可用的 sdkmanager，Flutter 就会传
#   `-Pflutter.sdkManagerPath=…`，其 gradle 插件看到后就会调 sdkmanager 去装 NDK；
#   而新版 cmdline-tools 的 sdkmanager 是个壳，会先去 dl.google.com 下 Android CLI → 挂。
#   我们不需要 NDK 也不需要 sdkmanager（包解压装、许可自己写），留空即可。

# 许可文件：不写的话 AGP 认为许可没接受，直接拒绝构建
printf '%s\n' \
  8933bad161af4178b1185d1a37fbf41ea5269c55 \
  d56f5187479451eabf01fb78af6dfcb131a6481e \
  24333f8a63b6825ea9c5514f83c2829b004d1fee > "$SDK_DIR/licenses/android-sdk-license"
printf '%s\n' 84831b9409646a918e30573bab4c9c91346d8abd > "$SDK_DIR/licenses/android-sdk-preview-license"
echo "    ✓ 许可文件已写"

# ── 3. 汇总 ─────────────────────────────────────────────────────────────
say "准备好啦 —— 各目录大小"
du -sh "$FLUTTER_DIR" "$JDK_DIR" "$SDK_DIR" "$DEV_DIR/gradle-home" "$DEV_DIR/pub-cache"
cat <<'TIP'

下一步（在 Forgejo runner 的 compose / runner-config.yml 里挂进容器）：

  # docker-compose.yml：让 dind 也能看到这个目录（dind 里路径是 /host-dev）
  services:
    docker-in-docker:
      volumes:
        - dind-storage:/var/lib/docker
        - /home/warren/dev:/host-dev

  # runner-config.yml：
  container:
    valid_volumes:
      - /host-dev/**
    options: "--volume /host-dev:/opt/dev"

然后重启 runner：docker compose up -d
（工作流里会自动用 /opt/dev 下的东西，找不到才回退到下载，见 docs/ci.md §2.4）
TIP
