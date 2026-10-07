#!/usr/bin/env bash
# VideoToolbox 离线探针（macOS 本机跑，不需要 iOS 设备、不需要 ws-scrcpy 服务端）。
#
# 链接的是 **darwin/ScrcpyVideoDecoder.swift 本身**，不是副本——
# 这是 AGENTS.md §12.3 的纪律："诊断工具不要维护第二份业务逻辑"，
# 否则量到的不是真东西（Windows 的 run_nv12_bench.cmd 就踩过这个坑）。
#
# 注意路径：2026-10-02 把解码器从 ios/Runner/ 搬到了 darwin/（iOS / macOS 两端共用），
# 这个脚本跟着改过一次——搬文件时**记得一起改**，否则探针会以
# "error opening input file" 退出（这正是它该有的表现：红了就说明没链上真东西）。
#
# 用法：
#   tools/run_vt_replay_probe.sh
#
# 退出码 0 = 全部检查项通过。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/.tmp/vt_replay_probe"
BIN="$OUT_DIR/vt_replay_probe"

mkdir -p "$OUT_DIR"

echo "编译探针（把 darwin/ScrcpyVideoDecoder.swift 编到 macOS 上）…"
xcrun --sdk macosx swiftc \
  -O \
  -o "$BIN" \
  "$ROOT/tools/vt_replay_probe.swift" \
  "$ROOT/darwin/ScrcpyVideoDecoder.swift" \
  -framework Foundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework VideoToolbox

echo "运行探针…"
"$BIN" "$ROOT"
