# dev-container

用 Docker 在一台共享服务器上跑一个长期运行的 Ubuntu 容器，通过 SSH / VS Code Remote-SSH 接入，作为个人开发机。

## 特性

- **sshd 常驻**：容器就是一个 SSH 端点，`ssh dev` 或 VS Code Remote-SSH 直接连
- **uid/gid 与宿主机一致**：挂载目录里写出的文件不会变成数字 uid
- **镜像与状态分离**：工具链在镜像里，dotfiles / 缓存 / 数据在挂载卷里，重建镜像不丢
- **资源硬上限**：`--memory`、`--cpus`、`--pids-limit` 超限只杀容器内进程
- **`--init` 与日志轮转**：tini 回收僵尸进程，json-file 日志限制为 10m × 3
- **预装工具链**：zsh、tmux、git、vim、btop、uv、rustup、clang+mold、graphviz、Noto CJK 字体

## 要求

- 宿主机：Linux，已安装 Docker
- 客户端：SSH 客户端；VS Code 需装 Remote - SSH 扩展

```bash
sudo apt install docker.io
sudo usermod -aG docker "$USER"   # 重新登录生效
docker run --rm hello-world
```

## 使用

```bash
git clone https://github.com/shihuaidexianyu/dev-container.git
cd dev-container
./run.sh
```

`run.sh` 会构建镜像、启动容器，并打印一段 `~/.ssh/config` 配置。把这段加到本机，然后：

```bash
ssh dev
```

VS Code 中执行 `Remote-SSH: Connect to Host` → `dev`。

### 命令

| 命令 | 作用 |
| --- | --- |
| `./run.sh` | 构建并启动（已存在则 `docker start`） |
| `./run.sh --rebuild` | 改完 `Dockerfile` 后重建容器 |
| `./run.sh --logs` | 查看 sshd 日志 |
| `./run.sh --rm` | 删除容器（挂载数据不受影响） |
| `docker exec -it dev zsh` | 不经过 sshd 直接进入 |

## 配置

全部通过环境变量覆盖，默认值在 `run.sh` 顶部。

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NAME` | `dev` | 容器名，同时是 SSH Host 别名 |
| `IMAGE` | `dev-env:latest` | 镜像标签 |
| `SSH_PORT` | `2222` | 宿主机映射端口 |
| `BIND_ADDR` | `127.0.0.1` | 监听地址，`0.0.0.0` 表示对外暴露 |
| `MEM` | `32g` | 内存上限 |
| `CPUS` | `8` | CPU 配额 |
| `SHM` | `2g` | `/dev/shm` 大小 |
| `PIDS` | `1024` | 进程/线程数上限 |
| `LOG_MAX_SIZE` | `10m` | 单个日志文件上限 |
| `LOG_MAX_FILE` | `3` | 日志文件保留个数 |
| `HOME_MOUNT` | `$HOME` | 挂载到容器内同路径 |
| `DATA_MOUNT` | `/data/$USER` 或 `$HOME/work` | 数据目录，挂载到容器内同路径 |

```bash
MEM=16g CPUS=4 ./run.sh
BIND_ADDR=0.0.0.0 ./run.sh
```

## 文件

```
Dockerfile      镜像定义
entrypoint.sh   生成 host key，前台运行 sshd
run.sh          构建、启动、打印连接配置
```

## 挂载与持久化

| 宿主机 | 容器 | 内容 |
| --- | --- | --- |
| `$HOME` | `/home/<user>` | dotfiles、`~/.vscode-server`、shell 历史 |
| `$DATA_MOUNT` | 同路径 | 代码、数据集 |
| 卷 `dev-ssh-hostkeys` | `/etc/ssh/host_keys` | SSH host key，重建容器不变 |

容器内 `$HOME` 与宿主机同路径。路径不一致会导致 dotfiles、`~/.vscode-server` 和脚本里的绝对路径全部失效。

`--memory-swap` 与 `--memory` 相等，容器内禁用 swap：超限时杀掉容器内进程，不触发整机换页。

## 说明

- 镜像内不安装 Python 解释器，`uv sync` 按 `pyproject.toml` 将所需版本下载到项目目录
- `RUSTUP_HOME` / `CARGO_HOME` 位于 `/opt`，避免被 `$HOME` 挂载覆盖；权限为 `a+rwX`，换 uid 无需重装
- 代理地址不写入镜像，`run.sh` 通过 `-e http_proxy` 等透传宿主机环境变量
- 若数据盘为 HDD，建议将 `target/`、`.venv` 保留在 SSD 上的家目录

### Git 凭据

首次启动时 `entrypoint.sh` 在容器内生成一把独立的 ed25519 密钥，公钥打印在 `docker logs` 里：

```bash
docker logs dev | sed -n '/ssh-ed25519/p'
```

把它加到 GitHub 的 `Settings → SSH keys` 即可 `git clone` 私有仓库。容器不挂载宿主机的 `~/.ssh`，宿主机私钥不会进入容器。密钥位于挂载的家目录，重建容器后仍在。

## 限制

- `docker` 组等价于 root，组内成员可通过挂载宿主机根目录获得完整权限。用户间隔离依赖组成员控制，不是机制隔离；需要机制隔离请使用 rootless Podman
- 容器不隐藏宿主机上的进程，`ps` 可见容器内所有进程
- **没有 systemd**：PID 1 是 sshd，`systemctl`、`service`、`cron` 均不可用，容器内无法运行常驻服务
- **没有 sudo**：缺少系统包时需改 `Dockerfile` 重建，或 `docker exec -u root` 临时安装（重建后丢失）
- **没有 GUI**：图形界面程序需要 X11 转发
- 面向开发用途，不适用于对外提供服务

## License

MIT
