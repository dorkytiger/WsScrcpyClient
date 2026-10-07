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
# 平台要装多个：**每个插件有自己的 compileSdk**（实测 flutter_secure_storage=34、
# sqlite3_flutter_libs/jni=35，app 自己=36），少一个就报
# "Failed to find Platform SDK with path: platforms;android-34"。
# build-tools 同理按 AGP 默认版本给（插件用的 AGP 8.5.1 默认要 34.0.0）。
RUN set -eux; \
    SDK=/opt/dev/android-sdk; \
    base=https://mirrors.cloud.tencent.com/AndroidSDK; \
    mkdir -p "$SDK/platforms" "$SDK/build-tools" "$SDK/licenses"; \
    fetch() { curl -fSL --retry 3 --retry-delay 2 -o /tmp/pkg.zip "$base/$1"; }; \
    unpack_to() { rm -rf /tmp/unpack; mkdir -p /tmp/unpack; unzip -q /tmp/pkg.zip -d /tmp/unpack; mv "$(find /tmp/unpack -mindepth 1 -maxdepth 1 | head -1)" "$1"; }; \
    install_pkg() { if [ -d "$2" ]; then echo "已有 $2"; else fetch "$1" && unpack_to "$2"; fi; }; \
    install_pkg platform-36_r02.zip          "$SDK/platforms/android-36"; \
    install_pkg platform-35_r02.zip          "$SDK/platforms/android-35"; \
    install_pkg platform-34-ext7_r03.zip     "$SDK/platforms/android-34"; \
    install_pkg build-tools_r36_linux.zip    "$SDK/build-tools/36.0.0"; \
    install_pkg build-tools_r35_linux.zip    "$SDK/build-tools/35.0.0"; \
    install_pkg build-tools_r34-linux.zip    "$SDK/build-tools/34.0.0"; \
    install_pkg platform-tools_r37.0.1-linux.zip "$SDK/platform-tools"; \
    printf '%s\n' \
      8933bad161af4178b1185d1a37fbf41ea5269c55 \
      d56f5187479451eabf01fb78af6dfcb131a6481e \
      24333f8a63b6825ea9c5514f83c2829b004d1fee > "$SDK/licenses/android-sdk-license"; \
    printf '%s\n' 84831b9409646a918e30573bab4c9c91346d8abd > "$SDK/licenses/android-sdk-preview-license"; \
    rm -f /tmp/pkg.zip; \
    ls "$SDK/platforms" "$SDK/build-tools"

# 真 NDK（腾讯镜像里有：`android-ndk-r28c-linux.zip` == NDK 28.2.13676358，正是 Flutter 默认要的版本）
#
# **为什么必须装真的**：AGP 的 `stripReleaseDebugSymbols` 固定调用 NDK 里的
# `ndk/<版本>/toolchains/llvm/prebuilt/<host>/bin/llvm-strip` 去剥 .so 的调试符号；
#   · 只放"标记文件"→ AGP 以为 NDK 在 → 启动 llvm-strip 时 "A problem occurred starting process" 失败；
#   · 绕开 strip（`keepDebugSymbols`）→ 实测 universal APK **517MB**（引擎库带符号进包）；
# 装了真 NDK 两个问题都没有，也不用再依赖标记文件。
ARG NDK_VERSION=28.2.13676358
RUN set -eux; \
    curl -fSL --retry 3 --retry-delay 2 -o /tmp/ndk.zip \
      "https://mirrors.cloud.tencent.com/AndroidSDK/android-ndk-r28c-linux.zip"; \
    rm -rf /tmp/ndkx; mkdir -p /tmp/ndkx; \
    unzip -q /tmp/ndk.zip -d /tmp/ndkx; \
    rm -rf "/opt/dev/android-sdk/ndk/${NDK_VERSION}"; \
    mkdir -p /opt/dev/android-sdk/ndk; \
    mv "$(find /tmp/ndkx -mindepth 1 -maxdepth 1 | head -1)" "/opt/dev/android-sdk/ndk/${NDK_VERSION}"; \
    rm -rf /tmp/ndk.zip /tmp/ndkx; \
    cat "/opt/dev/android-sdk/ndk/${NDK_VERSION}/source.properties"; \
    ls "/opt/dev/android-sdk/ndk/${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"

# NDK 标记（**兜底用**：只有在真 NDK 缺失时才写，1 个字节的文件）
#
# 为什么需要：Flutter 的 gradle 插件 `FlutterPluginUtils.forceNdkDownload()` 会强制 AGP 拿 NDK；
# 它判断"NDK 已装"的条件是 —— `$SDK/ndk/<版本>/source.properties` 存在
#（见 flutter_tools/lib/src/android/gradle.dart 的 _getInstalledNdkVersionsForGradle：
#  它只 list 目录 + 检查 source.properties 是否存在，内容都不读）。
#   · 有这个标记 → 该版本被认为已装 → 整个 NDK 流程跳过（不调 sdkmanager、不配合成 externalNativeBuild）；
#   · 没有标记、又没有真 NDK → AGP 报 `NDK not configured. Download it with SDK manager.`（实测）。
# 本项目没有任何原生代码（Flutter 引擎的 .so 是预编译 AAR 里的），所以真 NDK 用不上。
# ⚠️ 以后若加了带原生代码的插件，就得换成真 NDK（同版本下载后解到 `ndk/<版本>/`）。
RUN d="/opt/dev/android-sdk/ndk/${NDK_VERSION}"; \
    if [ -x "$d/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" ]; then \
      echo "真 NDK 已就位：$d"; \
    else \
      echo "⚠️ 没有真 NDK，只放标记（此时 stripReleaseDebugSymbols 会失败）"; \
      mkdir -p "$d" && printf 'Pkg.Desc = Android NDK\nPkg.Revision = %s\n' "${NDK_VERSION}" > "$d/source.properties"; \
    fi

# Gradle 仓库镜像（init script）：对所有 project 生效，**包括 pub-cache 里的插件** ——
# flutter_secure_storage 的 android/build.gradle 自己声明了 google() + AGP 8.5.1，
# 项目里的 .gradle.kts 覆盖不到它（实测报 dl.google.com 握手失败）。
# 内容与仓库里 tools/ci/gradle-mirrors.init.gradle 一致（那边是权威副本，改的话两边一起改）。
# 上面那份 init script 用 base64 内联（避免 Dockerfile heredoc/引号转义问题）：
# 解码后的内容 == 仓库里的 tools/ci/gradle-mirrors.init.gradle（那边是权威副本，改时两边一起改）。
RUN mkdir -p /opt/dev/gradle-home/init.d \
 && printf '%s' \
  'Ly8g5oqK5omA5pyJIui/nuS4jeS4ii/ooqvlopki55qE5LuT5bqT5o2i5oiQ5pys5Zyw6ZWc5YOP' \
  '77yI6Zi/6YeM5LqR77yJ44CCKirlr7nmiYDmnIkgcHJvamVjdCAvIOaJgOaciSBidWlsZCDnlJ/m' \
  'lYgqKuOAggovLwovLyDilIDilIAg5Li65LuA5LmI5b+F6aG755SoIGluaXQgc2NyaXB077yM6ICM' \
  '5LiN5piv5pS56aG555uu6YeM55qEIC5ncmFkbGUua3RzIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU' \
  'gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAovLyDmj5Lku7bnmoQgYnVpbGRzY3JpcHQg5LuT5bqT' \
  '5YaZ5ZyoICoqcHViLWNhY2hlIOmHjOeahOaPkuS7tua6kOeggSoq5Lit44CC5L6L77yaCi8vICAg' \
  'Zmx1dHRlcl9zZWN1cmVfc3RvcmFnZS9hbmRyb2lkL2J1aWxkLmdyYWRsZQovLyAgICAgYnVpbGRz' \
  'Y3JpcHQgeyByZXBvc2l0b3JpZXMgeyBnb29nbGUoKSB9Ci8vICAgICAgIGRlcGVuZGVuY2llcyB7' \
  'IGNsYXNzcGF0aCAnY29tLmFuZHJvaWQudG9vbHMuYnVpbGQ6Z3JhZGxlOjguNS4xJyB9IH0KLy8g' \
  '6aG555uu6Ieq5bex55qEIDQg5LiqIC5ncmFkbGUua3RzIOimhuebluS4jeWIsOWug++8jOWunua1' \
  'i+aKpe+8mgovLyAgIEEgcHJvYmxlbSBvY2N1cnJlZCBjb25maWd1cmluZyBwcm9qZWN0ICc6Zmx1' \
  'dHRlcl9zZWN1cmVfc3RvcmFnZScuCi8vICAgICA+IENvdWxkIG5vdCByZXNvbHZlIGNvbS5hbmRy' \
  'b2lkLnRvb2xzLmJ1aWxkOmdyYWRsZTo4LjUuMS4KLy8gICAgICAgID4gQ291bGQgbm90IEdFVCAn' \
  'aHR0cHM6Ly9kbC5nb29nbGUuY29tL2RsL2FuZHJvaWQvbWF2ZW4yLy4uLi9ncmFkbGUtOC41LjEu' \
  'cG9tJwovLwovLyDilIDilIAg4piFIOWdke+8muS4jeiDveaXoOiEkeW+gCBwcm9qZWN0IOe6pyBy' \
  'ZXBvc2l0b3JpZXMg6YeM5YqgIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU' \
  'gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAovLyBGbHV0dGVyIOiHquW3seea' \
  'hCBncmFkbGUg5o+S5Lu25p6E5bu677yIaW5jbHVkZUJ1aWxkKCIkZmx1dHRlclNka1BhdGgvcGFj' \
  'a2FnZXMvZmx1dHRlcl90b29scy9ncmFkbGUiKe+8iQovLyDlnKjlroPnmoQgc2V0dGluZ3MuZ3Jh' \
  'ZGxlLmt0cyDph4zorr7kuobvvJoKLy8gICAgIHJlcG9zaXRvcmllc01vZGUuc2V0KFJlcG9zaXRv' \
  'cmllc01vZGUuRkFJTF9PTl9QUk9KRUNUX1JFUE9TKQovLyDlvoDpgqPnp40gYnVpbGQg55qEIHBy' \
  'b2plY3QucmVwb3NpdG9yaWVzIOmHjOWKoOS7k+W6k+S8muWcqCoq6Kej5p6Q6Zi25q61Kirnm7Tm' \
  'jqXlpLHotKXvvJoKLy8gICAgIEJ1aWxkIHdhcyBjb25maWd1cmVkIHRvIHByZWZlciBzZXR0aW5n' \
  'cyByZXBvc2l0b3JpZXMgb3ZlciBwcm9qZWN0IHJlcG9zaXRvcmllcwovLyAgICAgYnV0IHJlcG9z' \
  'aXRvcnkgJ21hdmVuJyB3YXMgYWRkZWQgYnkgc2V0dGluZ3MgZmlsZSAnc2V0dGluZ3MuZ3JhZGxl' \
  'Lmt0cycKLy8g5omA5Lul6L+Z6YeM5oyJ5q+P5LiqIGJ1aWxkIOeahCByZXBvc2l0b3JpZXNNb2Rl' \
  'IOWGs+Wumu+8mgovLyAgIMK3IHNldHRpbmdzIOe6p++8iHBsdWdpbk1hbmFnZW1lbnQgLyBkZXBl' \
  'bmRlbmN5UmVzb2x1dGlvbk1hbmFnZW1lbnQgLyDoh6rlt7HnmoQgYnVpbGRzY3JpcHTvvInmsLjo' \
  'v5zmlLnvvJsKLy8gICDCtyBwcm9qZWN0IOe6p+WPquWcqOivpSBidWlsZCAqKuayoeaciSoqIEZB' \
  'SUxfT05fUFJPSkVDVF9SRVBPUyDml7bmlLnvvIjmiJHku6znmoQgYXBwIGJ1aWxkIOaYr+m7mOiu' \
  'pOeahAovLyAgICAgUFJFRkVSX1BST0pFQ1TvvIxGbHV0dGVyIOeahCByZXNvbHZlX2RlcGVuZGVu' \
  'Y2llcy5ncmFkbGUua3RzIOWwseaYr+WcqCBwcm9qZWN0IOe6p+WKoCBnb29nbGUoKSDnmoTvvInj' \
  'gIIKLy8KLy8g4pSA4pSAIOeUqOazlSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi' \
  'lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi' \
  'lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi' \
  'lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKLy8gICDCtyBDSSDp' \
  'h4znlLHlt6XkvZzmtYHmi7fov5sgJEdSQURMRV9VU0VSX0hPTUUvaW5pdC5kLzEwLWNoaW5hLW1p' \
  'cnJvcnMuZ3JhZGxl77ybCi8vICAgwrcg6ZWc5YOP6YeM54Ok5LqG5LiA5Lu95ZCM5qC355qE77yI' \
  'YmFzZTY0IOWGheiBlOWcqCB0b29scy9jaS9Eb2NrZXJmaWxl77yM5pS56L+Z6YeM6KaB5ZCM5q2l' \
  '6YKj6L6577yJ77ybCi8vICAgwrcg5pys5Zyw5omL5Yqo6LeR77yaZ3JhZGxlIC0taW5pdC1zY3Jp' \
  'cHQgdG9vbHMvY2kvZ3JhZGxlLW1pcnJvcnMuaW5pdC5ncmFkbGUgPHRhc2s+CmRlZiBtaXJyb3Jz' \
  'ID0gWwogICdodHRwczovL21hdmVuLmFsaXl1bi5jb20vcmVwb3NpdG9yeS9nb29nbGUnLCAgICAg' \
  'ICAgLy8gR29vZ2xlIE1hdmVu77yaQUdQIC8gQW5kcm9pZFgKICAnaHR0cHM6Ly9tYXZlbi5hbGl5' \
  'dW4uY29tL3JlcG9zaXRvcnkvcHVibGljJywgICAgICAgIC8vIE1hdmVuIENlbnRyYWzvvIgrIGpj' \
  'ZW50ZXIg5YWc5bqV77yJCiAgJ2h0dHBzOi8vbWF2ZW4uYWxpeXVuLmNvbS9yZXBvc2l0b3J5L2dy' \
  'YWRsZS1wbHVnaW4nLCAvLyBHcmFkbGUgUGx1Z2luIFBvcnRhbApdCgpkZWYgYmxvY2tlZEhvc3Rz' \
  'ID0gWwogICdkbC5nb29nbGUuY29tJywgJ21hdmVuLmdvb2dsZS5jb20nLAogICdyZXBvLm1hdmVu' \
  'LmFwYWNoZS5vcmcnLCAncmVwbzEubWF2ZW4ub3JnJywKICAncGx1Z2lucy5ncmFkbGUub3JnJywg' \
  'J2pjZW50ZXIuYmludHJheS5jb20nLCAncmVwby5ncmFkbGUub3JnJywKXQoKZGVmIGlzTWF2ZW4g' \
  'PSB7IHJlcG8gLT4KICByZXBvIGluc3RhbmNlb2Ygb3JnLmdyYWRsZS5hcGkuYXJ0aWZhY3RzLnJl' \
  'cG9zaXRvcmllcy5NYXZlbkFydGlmYWN0UmVwb3NpdG9yeQp9CmRlZiBpc0Jsb2NrZWQgPSB7IHJl' \
  'cG8gLT4KICBpc01hdmVuKHJlcG8pICYmIGJsb2NrZWRIb3N0cy5jb250YWlucygocmVwby51cmw/' \
  'Lmhvc3QgPzogJycpKQp9CmRlZiBoYXNNaXJyb3IgPSB7IGhhbmRsZXIgLT4KICBoYW5kbGVyLmFu' \
  'eSB7IHJlcG8gLT4gaXNNYXZlbihyZXBvKSAmJiAocmVwby51cmw/Lmhvc3QgPzogJycpID09ICdt' \
  'YXZlbi5hbGl5dW4uY29tJyB9Cn0KCmRlZiByZXdyaXRlID0geyBoYW5kbGVyIC0+CiAgaGFuZGxl' \
  'ci5yZW1vdmVBbGwgeyBpc0Jsb2NrZWQoaXQpIH0KICBpZiAoIWhhc01pcnJvcihoYW5kbGVyKSkg' \
  'ewogICAgbWlycm9ycy5lYWNoIHsgbSAtPiBoYW5kbGVyLm1hdmVuIHsgdXJsID0gbSB9IH0KICB9' \
  'Cn0KCi8vIOWTquS6myBidWlsZCDnpoHmraIgcHJvamVjdCDnuqfku5PlupPvvIjplK4gPSBHcmFk' \
  'bGUg5a6e5L6L77yM5Lmf5bCx5pivIuavj+S4qiBidWlsZCDkuIDku70i77yJCmRlZiBmYWlsT25Q' \
  'cm9qZWN0UmVwb3MgPSBbOl0ud2l0aERlZmF1bHQgeyBmYWxzZSB9CgpzZXR0aW5nc0V2YWx1YXRl' \
  'ZCB7IHNldHRpbmdzIC0+CiAgZGVmIG1vZGUgPSAnUFJFRkVSX1BST0pFQ1QnCiAgdHJ5IHsKICAg' \
  'IG1vZGUgPSBzZXR0aW5ncy5kZXBlbmRlbmN5UmVzb2x1dGlvbk1hbmFnZW1lbnQucmVwb3NpdG9y' \
  'aWVzTW9kZS5nZXQoKS50b1N0cmluZygpCiAgfSBjYXRjaCAoVGhyb3dhYmxlIGlnbm9yZWQpIHsK' \
  'ICAgIC8vIOiAgSBHcmFkbGUg5oiW5rKh5pyJ6L+Z5LiqIEFQSe+8muaMiem7mOiupCBQUkVGRVJf' \
  'UFJPSkVDVCDlpITnkIYKICB9CiAgZmFpbE9uUHJvamVjdFJlcG9zW3NldHRpbmdzLmdyYWRsZV0g' \
  'PSAobW9kZSA9PSAnRkFJTF9PTl9QUk9KRUNUX1JFUE9TJykKCiAgcmV3cml0ZShzZXR0aW5ncy5w' \
  'bHVnaW5NYW5hZ2VtZW50LnJlcG9zaXRvcmllcykKICByZXdyaXRlKHNldHRpbmdzLmJ1aWxkc2Ny' \
  'aXB0LnJlcG9zaXRvcmllcykKICB0cnkgewogICAgcmV3cml0ZShzZXR0aW5ncy5kZXBlbmRlbmN5' \
  'UmVzb2x1dGlvbk1hbmFnZW1lbnQucmVwb3NpdG9yaWVzKQogIH0gY2F0Y2ggKFRocm93YWJsZSBp' \
  'Z25vcmVkKSB7CiAgICAvLyDmsqHlo7DmmI7ov4cgZGVwZW5kZW5jeVJlc29sdXRpb25NYW5hZ2Vt' \
  'ZW50IOWwseWIq+ehrOeisAogIH0KfQoKZ3JhZGxlLnByb2plY3RzTG9hZGVkIHsgZyAtPgogIGRl' \
  'ZiBza2lwUHJvamVjdFJlcG9zID0gZmFpbE9uUHJvamVjdFJlcG9zW2ddID09IHRydWUKICBnLnJv' \
  'b3RQcm9qZWN0LmFsbHByb2plY3RzIHsgcHJvamVjdCAtPgogICAgcmV3cml0ZShwcm9qZWN0LmJ1' \
  'aWxkc2NyaXB0LnJlcG9zaXRvcmllcykKICAgIGlmICghc2tpcFByb2plY3RSZXBvcykgewogICAg' \
  'ICB0cnkgewogICAgICAgIHJld3JpdGUocHJvamVjdC5yZXBvc2l0b3JpZXMpCiAgICAgIH0gY2F0' \
  'Y2ggKFRocm93YWJsZSBpZ25vcmVkKSB7CiAgICAgICAgLy8g6K+lIGJ1aWxkIOemgeatoiBwcm9q' \
  'ZWN0IOe6p+S7k+W6k++8muWPqueVmSBzZXR0aW5ncy9idWlsZHNjcmlwdCDpgqPkuKTlpIQKICAg' \
  'ICAgfQogICAgfQogIH0KfQoKLy8g5o+S5Lu2L+mhueebruiEmuacrOS8muWcqOWIm+W7uuS5i+WQ' \
  'juWGjeWjsOaYjuS4gOasoSBnb29nbGUoKe+8jOivhOS8sOWujOWGjeaJq+S4gOmBjQpncmFkbGUu' \
  'YWZ0ZXJQcm9qZWN0IHsgcHJvamVjdCAtPgogIHJld3JpdGUocHJvamVjdC5idWlsZHNjcmlwdC5y' \
  'ZXBvc2l0b3JpZXMpCiAgaWYgKGZhaWxPblByb2plY3RSZXBvc1twcm9qZWN0LmdyYWRsZV0gIT0g' \
  'dHJ1ZSkgewogICAgdHJ5IHsKICAgICAgcmV3cml0ZShwcm9qZWN0LnJlcG9zaXRvcmllcykKICAg' \
  'IH0gY2F0Y2ggKFRocm93YWJsZSBpZ25vcmVkKSB7CiAgICB9CiAgfQp9Cg==' \
  | base64 -d > /opt/dev/gradle-home/init.d/10-china-mirrors.gradle \
 && head -3 /opt/dev/gradle-home/init.d/10-china-mirrors.gradle

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
