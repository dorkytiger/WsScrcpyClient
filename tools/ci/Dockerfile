# CI 用的 job 镜像：node + Flutter + Android SDK + JDK 全烤进去
#
# ── 为什么是镜像，而不是"挂载宿主机目录" ─────────────────────────────────
# runner v13.2.0 **会忽略 `container.options` 里的 `--volume`**：
#   · 症状：job 容器里 `/opt` 只有 `yarn-v1.22.22`，`/opt/dev`、`/opt/dev2` 两个挂载点
#     连空目录都没被创建（= 卷根本没传给 docker create）；
#   · 上游同症状的 issue：forgejo/runner#425「config container options are ignored
#     (v6.0.0 regression)」，报告者说 `valid_volumes: ['**']`、`--mount`、`--volume` 都不行；
#   · 我们逐项排除过：dind 里有 /host-dev、runner 用的就是 dind
#     （DOCKER_HOST=tcp://docker-in-docker:2375）、`container.options`/`valid_volumes` 都写对、
#     `container:` 段只有 1 个、runner 读的就是 /data/runner-config.yml（pwd=/data）、
#     runner 也在改配置之后重启过 —— 卷依然没进 job 容器。
# 而**镜像这条路是这台机器上唯一被证明可用的**（node 镜像本来就是这么跑起来的），
# 所以把资源烤进镜像：路径与工作流的探测逻辑对齐（/opt/dev/...），工作流一行都不用改。
#
# ── 怎么用 ────────────────────────────────────────────────────────────────
#   tools/ci/build_ci_image.sh          # 在宿主机上把镜像烤进 dind（见该脚本）
# 然后把 runner 的 `--label docker:docker://…` 指向它：
#   --label docker:docker://ws-scrcpy-ci:latest
#   sudo docker compose up -d           # 改的是 compose 的 command → 必须 up -d（不能只 restart）
#
# ── 注意 ──────────────────────────────────────────────────────────────────
# · 这台机器连不上 dl.google.com，所以 Android SDK 从腾讯镜像取 zip，
#   并且**故意不装 cmdline-tools**（装了 Flutter 就会调 sdkmanager 去装 NDK → 撞 dl.google.com，
#   详见 docs/ci.md §2.1 第五个坑）；
# · 文件名要用 Google 官方索引 repository2-3.xml 里的真名：build-tools 从 35 起
#   把 `-` 换成了 `_`（`build-tools_r36_linux.zip`，而 34 是 `build-tools_r34-linux.zip`）；
# · 版本对应 compileSdk 36（Flutter 3.47 的默认值）→ platform 36 + build-tools 36.0.0；
# · Flutter 升级：改下面的 FLUTTER_VERSION（以及工作流顶层同名 env）后重建镜像。

FROM data.forgejo.org/oci/node:20-bookworm

ARG FLUTTER_VERSION=3.47.1
ENV DEBIAN_FRONTEND=noninteractive

# 基础工具：xz 解 Flutter 的 tar.xz，unzip 解 SDK 的 zip，zip 给 web 打包
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      xz-utils zip unzip curl ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

# JDK 17（Gradle/AGP 要一个 JVM；用 Adoptium 的 "latest" 重定向，直接拿 tar.gz，不用解析 JSON）
RUN mkdir -p /opt/dev/jdk \
 && curl -fSL --retry 3 --retry-delay 2 -o /tmp/jdk.tar.gz \
      "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" \
 && tar -xzf /tmp/jdk.tar.gz -C /opt/dev/jdk --strip-components=1 \
 && rm -f /tmp/jdk.tar.gz

# Flutter：官方 tar.xz + precache（把 linux / web / android 的引擎产物一起下好）
RUN mkdir -p /opt/dev \
 && curl -fSL --retry 3 --retry-delay 2 -o /tmp/flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
 && tar -xJf /tmp/flutter.tar.xz -C /opt/dev \
 && rm -f /tmp/flutter.tar.xz \
 && git config --global --add safe.directory /opt/dev/flutter \
 && /opt/dev/flutter/bin/flutter --version \
 && /opt/dev/flutter/bin/flutter precache --linux --web --android

# Android SDK：腾讯镜像（dl.google.com 不通）+ 手写许可文件；不装 cmdline-tools
RUN set -eux; \
    SDK=/opt/dev/android-sdk; \
    base=https://mirrors.cloud.tencent.com/AndroidSDK; \
    mkdir -p "$SDK/platforms" "$SDK/build-tools" "$SDK/licenses"; \
    fetch() { curl -fSL --retry 3 --retry-delay 2 -o /tmp/pkg.zip "$base/$1"; }; \
    unpack_to() { rm -rf /tmp/unpack; mkdir -p /tmp/unpack; unzip -q /tmp/pkg.zip -d /tmp/unpack; mv "$(find /tmp/unpack -mindepth 1 -maxdepth 1 | head -1)" "$1"; }; \
    fetch platform-36_r02.zip && unpack_to "$SDK/platforms/android-36"; \
    fetch build-tools_r36_linux.zip && unpack_to "$SDK/build-tools/36.0.0"; \
    fetch platform-tools_r37.0.1-linux.zip && unpack_to "$SDK/platform-tools"; \
    printf '%s\n' \
      8933bad161af4178b1185d1a37fbf41ea5269c55 \
      d56f5187479451eabf01fb78af6dfcb131a6481e \
      24333f8a63b6825ea9c5514f83c2829b004d1fee > "$SDK/licenses/android-sdk-license"; \
    printf '%s\n' 84831b9409646a918e30573bab4c9c91346d8abd > "$SDK/licenses/android-sdk-preview-license"; \
    rm -f /tmp/pkg.zip; \
    ls "$SDK/platforms" "$SDK/build-tools"

# NDK 标记（**不是**真 NDK，1 个字节的文件）
#
# 为什么需要：Flutter 的 gradle 插件 `FlutterPluginUtils.forceNdkDownload()` 会强制 AGP 拿 NDK；
# 它判断"NDK 已装"的条件是 —— `$SDK/ndk/<版本>/source.properties` 存在
#（见 flutter_tools/lib/src/android/gradle.dart 的 _getInstalledNdkVersionsForGradle：
#  它只 list 目录 + 检查 source.properties 是否存在，内容都不读）。
#   · 有这个标记 → 该版本被认为已装 → 整个 NDK 流程跳过（不调 sdkmanager、不配合成 externalNativeBuild）；
#   · 没有标记、又没有真 NDK → AGP 报 `NDK not configured. Download it with SDK manager.`（实测）。
# 本项目没有任何原生代码（Flutter 引擎的 .so 是预编译 AAR 里的），所以真 NDK 用不上。
# ⚠️ 以后若加了带原生代码的插件，就得换成真 NDK（同版本下载后解到 `ndk/<版本>/`）。
ARG NDK_VERSION=28.2.13676358
RUN mkdir -p "/opt/dev/android-sdk/ndk/${NDK_VERSION}" \
 && printf 'Pkg.Desc = Android NDK\nPkg.Revision = %s\n' "${NDK_VERSION}" \
      > "/opt/dev/android-sdk/ndk/${NDK_VERSION}/source.properties" \
 && cat "/opt/dev/android-sdk/ndk/${NDK_VERSION}/source.properties"

# 路径与缓存目录：工作流会优先探测这些（/opt/dev/flutter 等），探测到就不下载
ENV JAVA_HOME=/opt/dev/jdk \
    ANDROID_SDK_ROOT=/opt/dev/android-sdk \
    ANDROID_HOME=/opt/dev/android-sdk \
    PUB_CACHE=/opt/dev/pub-cache \
    GRADLE_USER_HOME=/opt/dev/gradle-home \
    PATH=/opt/dev/flutter/bin:/opt/dev/jdk/bin:/opt/dev/android-sdk/platform-tools:$PATH

RUN mkdir -p /opt/dev/pub-cache /opt/dev/gradle-home \
 && java -version \
 && flutter --version
