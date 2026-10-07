#!/usr/bin/env bash
# 在 **CI 宿主机** 上把 job 镜像烤进 dind（见同目录 Dockerfile 顶部的"为什么是镜像"）。
#
#   tools/ci/build_ci_image.sh              # 默认镜像名 ws-scrcpy-ci:latest、dind 容器名 forgejo-dind
#   IMAGE=ws-scrcpy-ci:v2 DIND=forgejo-dind tools/ci/build_ci_image.sh
#
# 为什么要 `docker exec -i <dind> docker build`：
#   runner 的 DOCKER_HOST=tcp://docker-in-docker:2375（dind），job 容器由 **dind 里的 docker** 创建，
#   所以镜像必须建在 dind 里；而 dind 的 /var/lib/docker 是持久卷 → 建一次就留住了。
#   直接在宿主机 `docker build` 只会建到宿主 daemon 上，runner 看不到。
#
# 幂等：Docker 会复用未变化的层；Flutter/SDK 版本变了才需要重跑（并给镜像换个 tag）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="${DOCKERFILE:-$HERE/Dockerfile}"
DIND="${DIND:-forgejo-dind}"
IMAGE="${IMAGE:-ws-scrcpy-ci:latest}"

[ -f "$DOCKERFILE" ] || { echo "找不到 Dockerfile：$DOCKERFILE"; exit 1; }
sudo docker inspect "$DIND" >/dev/null 2>&1 || {
  echo "找不到 dind 容器 '$DIND'（用 docker ps 看看真实名字，或设 DIND=...）"; exit 1; }

# dind 里怎么连到自己的 docker daemon：
#   · 有些 dind 只监听 TCP（我们的 runner 就是 DOCKER_HOST=tcp://docker-in-docker:2375），
#     这时容器内 **没有** /var/run/docker.sock，`docker` 默认会报
#     "failed to connect to the docker API at unix:///var/run/docker.sock"；
#   · 所以先探测：有 socket 就用 socket，否则用容器内的 127.0.0.1:2375。
DIND_HOST=""
if sudo docker exec "$DIND" sh -c '[ -S /var/run/docker.sock ]' 2>/dev/null; then
  echo "dind 里有 /var/run/docker.sock，用它"
else
  DIND_HOST="tcp://127.0.0.1:2375"
  echo "dind 里没有 unix socket → 用 $DIND_HOST（runner 也是走 TCP 连它的）"
  sudo docker exec "$DIND" sh -c 'command -v docker >/dev/null && echo "dind 内有 docker CLI ✓" || echo "警告：dind 内没有 docker CLI"'
fi
dind_docker() { if [ -n "$DIND_HOST" ]; then sudo docker exec -e DOCKER_HOST="$DIND_HOST" "$@"; else sudo docker exec "$@"; fi; }

echo
echo "== 在 $DIND 里构建 $IMAGE（不用构建上下文，全部内容靠 Dockerfile 里的 RUN 下载）=="
if [ -n "$DIND_HOST" ]; then
  sudo docker exec -i -e DOCKER_HOST="$DIND_HOST" "$DIND" docker build --progress=plain -t "$IMAGE" - < "$DOCKERFILE"
else
  sudo docker exec -i "$DIND" docker build --progress=plain -t "$IMAGE" - < "$DOCKERFILE"
fi

echo
echo "== 建好的镜像 =="
dind_docker "$DIND" docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -F 'ws-scrcpy-ci' || true

echo
echo "== 自检：拿这个镜像跑一下，确认 Flutter / JDK / Android SDK 都在（免得白跑一次 CI）=="
dind_docker "$DIND" docker run --rm "$IMAGE" sh -c '
  set -e
  echo "--- flutter ---"; flutter --version
  echo "--- java ---";    java -version
  echo "--- sdk ---";     ls /opt/dev/android-sdk/platforms /opt/dev/android-sdk/build-tools
  echo "--- 关键路径 ---"; ls -d /opt/dev/flutter /opt/dev/jdk /opt/dev/android-sdk
'

cat <<TIP

下一步（把 runner 的 docker 标签指到这个镜像）：
  1) 改 compose 里 runner 的启动参数：
       --label docker:docker://ws-scrcpy-ci:latest
     （就是原来指向 data.forgejo.org/oci/node:20-bookworm 的那一行）
  2) 改的是 compose 的 command → 必须重建容器（不是 restart）：
       cd ~/forgejo-runner && sudo docker compose up -d
  3) 重跑 CI：日志里「定位宿主机资源目录」应打 ✓ 命中宿主机目录：/opt/dev，
     「装 Flutter / 装 JDK 17 / 装 Android SDK」都应该是 0~1s 且不下载。
TIP
