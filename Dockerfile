# syntax=docker/dockerfile:1
#
# 一台用 SSH / VS Code Remote-SSH 接入的个人开发容器。
#
# 设计要点：
#   1. 容器里常驻 sshd，宿主机的某个端口映射到容器 22 端口；
#   2. 容器内 uid/gid/用户名与宿主机一致，挂载目录的文件归属才不会变成数字；
#   3. 镜像只装“环境”，$HOME 与数据目录在运行时挂载，重建镜像不丢状态；
#   4. 镜像内不装 Python 解释器，交给 uv 按项目下载；不写任何代理地址和密钥。
#
# 构建（run.sh 会自动传参）：
#   docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
#                --build-arg USERNAME=$(id -un) -t dev-env:latest .

FROM ubuntu:22.04

ARG UID=1000
ARG GID=1000
ARG USERNAME=dev

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    UV_LINK_MODE=copy

# 供 entrypoint 使用：首次启动时以该用户身份生成 git 用的 SSH 密钥
ENV DEV_USER=${USERNAME} \
    DEV_UID=${UID}

# ---- 基础工具链 ----------------------------------------------------------
# build-essential + pkg-config + libssl-dev：绝大多数 crate 的编译前置
# clang + mold：比默认 ld 快数倍的链接器组合
# graphviz：提供 dot 二进制，Python 的 graphviz 包不会自己排版
# fonts-noto-cjk：缺了它 matplotlib 的中文标签会变成豆腐块，数值检查也查不出来
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-server \
      tmux zsh less vim-tiny procps tzdata \
      build-essential pkg-config libssl-dev clang mold \
      graphviz fonts-noto-cjk \
    && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
    && echo "${TZ}" > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# ---- uv ------------------------------------------------------------------
# 单个静态二进制，直接取官方镜像，无需安装 Python
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# ---- Rust ----------------------------------------------------------------
# 装到 /opt 而非 $HOME：$HOME 是运行时挂载的，镜像里写进去会被覆盖；
# a+rwX 保证容器内用户能 cargo install，换 uid 重建也不用重装。
ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --no-modify-path \
    && chmod -R a+rwX /opt/rustup /opt/cargo
ENV PATH=/opt/cargo/bin:${PATH}

# ---- 用户 ----------------------------------------------------------------
# ubuntu:22.04 自带 uid/gid 1000 的 ubuntu 用户，先删掉再按宿主机 uid 建号。
# 宿主机 GID 可能已被镜像内的系统组占用（如 dialout=20），此时直接沿用该组。
RUN set -eux; \
    userdel -r ubuntu 2>/dev/null || true; \
    groupdel ubuntu 2>/dev/null || true; \
    if getent group "${GID}" >/dev/null; then \
      GNAME="$(getent group "${GID}" | cut -d: -f1)"; \
    else \
      groupadd -g "${GID}" "${USERNAME}"; \
      GNAME="${USERNAME}"; \
    fi; \
    useradd -m -u "${UID}" -g "${GNAME}" -s /bin/zsh "${USERNAME}"

# ---- sshd ----------------------------------------------------------------
# Ubuntu 的 sshd_config 顶部有 Include sshd_config.d/*.conf，先匹配先生效，
# 所以这里的设置优先于主配置。
#
# StrictModes no：$HOME 是宿主机挂载进来的，权限位不受镜像控制；
# 容器只开放公钥认证，且公钥属于你自己的账户，权衡后取可用性。
#
# HostKey 指向 /etc/ssh/host_keys（运行时挂命名卷），这样重建容器后
# 客户端不会因为 host key 变化而报警。默认的 HostKey 行先注释掉。
RUN mkdir -p /run/sshd /etc/ssh/sshd_config.d /etc/ssh/host_keys \
    && rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub \
    && sed -i 's|^HostKey /etc/ssh/ssh_host_|#&|' /etc/ssh/sshd_config \
    && printf '%s\n' \
      'HostKey /etc/ssh/host_keys/ssh_host_rsa_key' \
      'HostKey /etc/ssh/host_keys/ssh_host_ecdsa_key' \
      'HostKey /etc/ssh/host_keys/ssh_host_ed25519_key' \
      'PermitRootLogin no' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PubkeyAuthentication yes' \
      'UsePAM no' \
      'StrictModes no' \
      'X11Forwarding no' \
      'AllowTcpForwarding yes' \
      'AllowAgentForwarding yes' \
      'PrintMotd no' \
      'AcceptEnv LANG LC_*' \
      'ClientAliveInterval 60' \
      'ClientAliveCountMax 3' \
      > /etc/ssh/sshd_config.d/99-devcontainer.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

EXPOSE 22
WORKDIR /home/${USERNAME}
CMD ["/usr/local/bin/entrypoint.sh"]
