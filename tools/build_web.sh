#!/usr/bin/env bash
# 打包 web 端（一条命令，自包含、可挂到服务端子路径下）。
#
# 用法：
#   tools/build_web.sh                 # 默认 base-href=/，产物在 build/web
#   tools/build_web.sh /app/           # 挂到 https://<服务端>/app/ 下时用这个
#
# ## 为什么建议挂到**服务端同一个源站**下（重要）
#
# 服务端的 Basic Auth 是 nginx/openresty 层的（`WWW-Authenticate: Basic realm="Authentication"`），
# 而**浏览器不允许给 WebSocket 加自定义请求头** —— 我们没法像原生端那样自己带凭据。
# 浏览器的凭据缓存是按 **host:port + realm** 记的，所以：
#
# - 页面**从受保护的那个源站加载**（如 `https://android.dorkytiger.top/app/`）：
#   加载页面时浏览器挑战**一次**，用户答对后凭据进缓存，之后**所有 WS 握手全静默**；
# - 页面从**别的源站**加载（如 `http://127.0.0.1:8765/`）再连服务端：
#   WS 握手仍然走同一个 protection space，所以**第一次**还是要弹一次框
#   （除非这个浏览器之前已经认证过该 host）。我们的代码已经把会造成"弹很多次"
#   的因素去掉了：鉴权失败不再自动重连、也不再去试设备直连地址。
#
# ## 两个构建开关
#
# - `--no-web-resources-cdn`：把 CanvasKit **打进产物**，不从 gstatic 拉。
#   否则离线/内网环境下页面永远白屏（实测：`canvaskit.wasm` 一次都不请求）。
# - `--base-href`：挂在子路径下时必须设，否则资源会从根路径解析而 404。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_HREF="${1:-/}"

cd "$ROOT"

# 运行时资源（sqlite3.wasm + drift_worker.js）不进仓库，构建前先备齐。
"$ROOT/tools/prepare_web_deps.sh"

flutter build web \
  --release \
  --no-web-resources-cdn \
  --base-href "$BASE_HREF"

echo
echo "✓ web 产物：$ROOT/build/web（base-href=$BASE_HREF）"
echo "  挂到服务端同一个源站下（推荐）：把 build/web 的内容放到例如 /app/ 目录。"
echo "  本地验证：cd build/web && python3 -m http.server 8765"
