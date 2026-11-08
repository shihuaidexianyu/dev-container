#!/usr/bin/env bash
# 容器入口：生成缺失的 host key，然后前台运行 sshd。
# 以 root 启动是必须的——sshd 要 bind 22 端口并在认证后切换到普通用户。
set -euo pipefail

KEYDIR=/etc/ssh/host_keys
mkdir -p "${KEYDIR}" /run/sshd

# host key 存在命名卷里，重建容器不会变，客户端不会报 host key 已更改
for type in rsa ecdsa ed25519; do
  key="${KEYDIR}/ssh_host_${type}_key"
  [ -s "${key}" ] || ssh-keygen -q -t "${type}" -N '' -f "${key}"
done
chmod 600 "${KEYDIR}"/ssh_host_*_key

exec /usr/sbin/sshd -D -e
