#!/usr/bin/env bash
# 准备 web 端需要的两个运行时资源（**离线、幂等、只从本地 pub 缓存取**）。
#
# 为什么要有这个脚本：这两个文件分别是 ~1.5MB 和 ~1MB 的构建产物，
# **不应该进仓库**；但它们必须躺在 `web/` 里，`flutter build web` 才会打进产物。
# 这与 `tools/prepare_windows_deps.cmd`（从本机 NuGet 缓存解包，不联网）是同一个套路。
#
# 用法：
#   tools/prepare_web_deps.sh          # 准备好 web/ 下的两个资源
#
# 需要在 `flutter pub get` 之后运行（依赖 pub 缓存里已下载的 drift / sqlite3）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$ROOT/web"
PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"

mkdir -p "$WEB"

# 1) drift 的 web worker：drift 包**自带编译好的** drift_worker.js。
#    注意：drift_dev 2.35 已经没有 make-web-worker 子命令了（只剩 analyze /
#    identify-databases / make-migrations / schema），别再去找那个命令。
worker="$(find "$PUB_CACHE/hosted/pub.dev" -maxdepth 2 -path "*drift-*/drift_worker.js" 2>/dev/null | sort -V | tail -1 || true)"
if [[ -z "$worker" ]]; then
  echo "找不到 drift_worker.js；先跑 flutter pub get（PUB_CACHE=$PUB_CACHE）" >&2
  exit 1
fi
cp -f "$worker" "$WEB/drift_worker.js"

# 2) SQLite 的 WASM 构建：优先取 sqlite3 包里的，其次退回 drift 自带的开发工具构建。
wasm="$(find "$PUB_CACHE/hosted/pub.dev" -maxdepth 4 -path "*sqlite3-*/lib/src/wasm/sqlite3.wasm" 2>/dev/null | sort -V | tail -1 || true)"
if [[ -z "$wasm" ]]; then
  wasm="$(find "$PUB_CACHE/hosted/pub.dev" -maxdepth 6 -path "*drift-*/extension/devtools/build/sqlite3.wasm" 2>/dev/null | sort -V | tail -1 || true)"
fi
if [[ -z "$wasm" ]]; then
  echo "找不到 sqlite3.wasm；先跑 flutter pub get（PUB_CACHE=$PUB_CACHE）" >&2
  exit 1
fi
cp -f "$wasm" "$WEB/sqlite3.wasm"

printf '已准备：\n  %s  (来自 %s)\n  %s  (来自 %s)\n' \
  "$WEB/drift_worker.js" "$worker" "$WEB/sqlite3.wasm" "$wasm"
