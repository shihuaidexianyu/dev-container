#!/usr/bin/env bash
# 构建并启动个人开发容器。
#
#   ./run.sh            首次创建，或启动已停止的容器
#   ./run.sh --rebuild  改完 Dockerfile 后重建（host key 与数据都在卷里，不受影响）
#   ./run.sh --logs     查看 sshd 日志
#   ./run.sh --rm       删除容器（数据在挂载目录里，不受影响）
#
# 全部参数都可用同名环境变量覆盖：
#   NAME IMAGE SSH_PORT BIND_ADDR MEM CPUS SHM PIDS
#   LOG_MAX_SIZE LOG_MAX_FILE HOME_MOUNT DATA_MOUNT
#
# 例：MEM=16g CPUS=4 ./run.sh
set -euo pipefail

NAME=${NAME:-dev}
IMAGE=${IMAGE:-dev-env:latest}
SSH_PORT=${SSH_PORT:-2222}
# 监听地址。默认只绑本机回环，外部访问靠 SSH 端口转发；改成 0.0.0.0 才会直接暴露到网络。
BIND_ADDR=${BIND_ADDR:-127.0.0.1}
MEM=${MEM:-32g}       # 硬上限：容器内用满即 OOM-kill，不影响整机
CPUS=${CPUS:-8}
SHM=${SHM:-2g}        # 默认 64M 会让 cargo 并行编译和 ML 数据加载炸掉
PIDS=${PIDS:-1024}    # 多进程 Python 与并行编译需要比 512 更多的线程
LOG_MAX_SIZE=${LOG_MAX_SIZE:-10m}
LOG_MAX_FILE=${LOG_MAX_FILE:-3}

HERE="$(cd "$(dirname "$0")" && pwd)"
UNAME="$(id -un)"
UHOME="$(cd "$HOME" && pwd)"

# 数据目录：默认 /data/<username>（若存在），否则用 $HOME/work
if [ -n "${DATA_MOUNT:-}" ]; then
  UDATA="${DATA_MOUNT}"
elif [ -d "/data/${UNAME}" ]; then
  UDATA="/data/${UNAME}"
else
  UDATA="${UHOME}/work"
  mkdir -p "${UDATA}"
fi

# 容器内 home：与宿主机同路径，dotfiles 与 ~/.vscode-server 才能对上
HOME_MOUNT=${HOME_MOUNT:-${UHOME}}

case "${1:-}" in
  --logs)    exec docker logs -f "${NAME}" ;;
  --rebuild) docker rm -f "${NAME}" >/dev/null 2>&1 || true ;;
  --rm)      docker rm -f "${NAME}" >/dev/null 2>&1 || true; echo "已删除 ${NAME}"; exit 0 ;;
  "")        ;;
  *)         echo "用法: $0 [--rebuild|--logs|--rm]" >&2; exit 2 ;;
esac

docker build \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  --build-arg USERNAME="${UNAME}" \
  -t "${IMAGE}" \
  "${HERE}"

if docker container inspect "${NAME}" >/dev/null 2>&1; then
  docker start "${NAME}" >/dev/null
else
  docker run -d \
    --name "${NAME}" \
    --restart unless-stopped \
    --init \
    --hostname dev \
    --log-opt "max-size=${LOG_MAX_SIZE}" --log-opt "max-file=${LOG_MAX_FILE}" \
    --memory="${MEM}" --memory-swap="${MEM}" \
    --cpus="${CPUS}" --pids-limit="${PIDS}" --shm-size="${SHM}" \
    -p "${BIND_ADDR}:${SSH_PORT}:22" \
    -v "${HOME_MOUNT}:/home/${UNAME}" \
    -v "${UDATA}:${UDATA}" \
    -v dev-ssh-hostkeys:/etc/ssh/host_keys \
    -e http_proxy -e https_proxy -e no_proxy \
    "${IMAGE}" >/dev/null
fi

docker ps --filter "name=^${NAME}$" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

if [ "${BIND_ADDR}" = "127.0.0.1" ]; then
  cat <<EOF

容器只监听本机回环，从外面连要经 SSH 跳板。本机 ~/.ssh/config 加一段：

  Host ${NAME}
      HostName 127.0.0.1
      Port ${SSH_PORT}
      User ${UNAME}
      ProxyJump <服务器别名>
      IdentityFile ~/.ssh/id_ed25519
      IdentitiesOnly yes

然后：ssh ${NAME}        或 VS Code 里选 ${NAME}

（不想用跳板就把 BIND_ADDR=0.0.0.0 传进来，同时确认防火墙放行了该端口。）
EOF
else
  cat <<EOF

本机 ~/.ssh/config 加一段：

  Host ${NAME}
      HostName <服务器地址>
      Port ${SSH_PORT}
      User ${UNAME}
      IdentityFile ~/.ssh/id_ed25519
      IdentitiesOnly yes

然后：ssh ${NAME}        或 VS Code 里选 ${NAME}
EOF
fi
