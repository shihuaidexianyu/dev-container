#!/usr/bin/env bash
# 容器入口：生成 host key 与用户 SSH 密钥，然后前台运行 sshd。
# 以 root 启动是必须的——sshd 要 bind 22 端口并在认证后切换到普通用户。
set -euo pipefail

DEV_USER="${DEV_USER:-dev}"
USER_HOME="/home/${DEV_USER}"

# ---- SSH host key --------------------------------------------------------
# 存在命名卷里，重建容器不会变，客户端不会报 host key 已更改
KEYDIR=/etc/ssh/host_keys
mkdir -p "${KEYDIR}" /run/sshd
for type in rsa ecdsa ed25519; do
  key="${KEYDIR}/ssh_host_${type}_key"
  [ -s "${key}" ] || ssh-keygen -q -t "${type}" -N '' -f "${key}"
done
chmod 600 "${KEYDIR}"/ssh_host_*_key

# ---- 用户 git 密钥 -------------------------------------------------------
# 在容器内生成一把独立密钥，不挂载宿主机的 ~/.ssh：容器拿到的是这把，
# 宿主机私钥不进入容器。家目录是挂载的，所以重建容器后这把密钥仍在。
install -d -m 700 -o "${DEV_USER}" "${USER_HOME}/.ssh"
if [ ! -s "${USER_HOME}/.ssh/id_ed25519" ]; then
  su -s /bin/sh "${DEV_USER}" -c \
    "ssh-keygen -q -t ed25519 -N '' -C '${DEV_USER}@dev-container' \
       -f '${USER_HOME}/.ssh/id_ed25519'"
  echo "已生成容器内 SSH 密钥：${USER_HOME}/.ssh/id_ed25519"
  echo "把下面这行公钥加到 GitHub（Settings → SSH keys）："
  echo
  cat "${USER_HOME}/.ssh/id_ed25519.pub"
  echo
fi

exec /usr/sbin/sshd -D -e
