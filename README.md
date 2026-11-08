# dev-container

在一台大服务器上开一个只属于自己的小容器，用来当开发机。

宿主机可能是很多人共用的，也可能只是你想把环境固定下来。这个仓库做的是同一件事：
用 Docker 起一个长期运行的 Ubuntu 容器，容器里跑 `sshd`，你用 SSH 或 VS Code
Remote-SSH 连进去，就像连一台独立的机器。

```
你的电脑  ──SSH──▶  宿主机（大机器）  ──端口转发──▶  容器（小机器）
   VS Code              Docker                     sshd + zsh + uv + rust
```

## 为什么要套一层容器

不套容器，直接在大机器上开个账号，其实也能干活。容器换来的是四件事：

| 想要 | 容器怎么做 |
| --- | --- |
| 环境可复现 | 工具链写进 `Dockerfile`，换机器重建一次就还原，不用回忆当初装了什么 |
| 不动系统 | 容器里 `apt install` 随便装，不碰宿主机的 `/usr`，也不需要 sudo |
| 资源有上限 | `--memory` / `--cpus` / `--pids-limit` 是硬限制，超了只杀容器里的进程 |
| 互不干扰 | 别人看到的是宿主机上一个普通进程，动不了你的环境 |

注意第三、四条不是"绝对安全"，见文末的[边界](#边界)。

## 快速开始

宿主机上（需要 root 或 sudo）：

```bash
sudo apt install docker.io
sudo usermod -aG docker "$USER"   # 重新登录后生效
docker run --rm hello-world       # 验证
```

然后把本仓库放到宿主机上，运行：

```bash
./run.sh
```

它会构建镜像、启动容器，最后打印一段 `~/.ssh/config` 配置。

把打印出来的那段加到你**自己电脑**的 `~/.ssh/config`，然后：

```bash
ssh dev
```

VS Code 装 Remote - SSH 扩展，命令面板选 `Remote-SSH: Connect to Host` → `dev`。

### 从外网连不进来？

`run.sh` 默认把容器的 22 端口绑在宿主机的 `127.0.0.1:2222` 上，也就是**只有宿主机
自己能连**。这样做是因为把一个 SSH 服务直接暴露到公网很容易被扫。从你的电脑连，
走 SSH 跳板（上面打印的配置里已经带 `ProxyJump`）：

```
你的电脑 ──SSH──▶ 宿主机 ──本地转发──▶ 127.0.0.1:2222 ──▶ 容器
```

如果宿主机本身就在内网、或者你有防火墙兜底，也可以直接暴露：

```bash
BIND_ADDR=0.0.0.0 ./run.sh
```

## 它长什么样

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | 镜像：sshd、zsh、tmux、git、uv、rustup、clang+mold、graphviz、中文字体 |
| `entrypoint.sh` | 生成 host key，前台运行 sshd |
| `run.sh` | 构建并启动容器，打印连接配置 |

## 三个分层：镜像、家目录、数据

这是这套东西最需要想清楚的地方。**镜像只装"环境"，状态和数据都在挂载目录里**，
所以重建镜像不丢东西。

| 层 | 放什么 | 在哪 |
| --- | --- | --- |
| 镜像 | apt 包、zsh、uv、rustup、字体、`dot` | `Dockerfile`，随时重建 |
| 家目录 | dotfiles、shell 历史、`~/.vscode-server`、AI CLI 凭据 | 挂载宿主机 `$HOME` |
| 数据 | 代码、数据集、模型 | 挂载 `/data/<username>` 或 `$HOME/work` |

两条经验：

- **容器内的 `$HOME` 路径要和宿主机完全一致**（都是 `/home/<username>`）。否则
  `~/.vscode-server`、dotfiles、脚本里写死的路径全对不上。`run.sh` 就是这么挂的。
- **代码和构建产物不要放机械盘**。如果大容量数据盘是 HDD，`cargo build` 和
  `uv sync` 会被随机读写卡住；把 `target/`、`.venv` 留在 SSD 上的家目录，
  只把数据集放数据盘。

## 容器里有什么

- **uv**：单个静态二进制，直接从官方镜像拷。镜像里**不装 Python 解释器**——
  `uv sync` 会按 `pyproject.toml` 把需要的版本下载到项目里。
- **Rust**：`rustup` 装到 `/opt`，不是 `$HOME`（`$HOME` 是挂载的，镜像里写进去会被
  覆盖），并 `chmod a+rwX`，这样容器里换 uid 也不用重装。附带 `clang` + `mold`，
  链接比默认 `ld` 快不少。
- **graphviz**：`dot` 二进制。Python 的 `graphviz` 包只是画图的接口，不会自己排版。
- **fonts-noto-cjk**：画中文图必需。缺了它 matplotlib 会静默回退到 DejaVu，
  图上的中文全变成方块，而且没有任何报错。

## 资源上限

默认值在 `run.sh` 顶部，都能用环境变量覆盖：

```bash
MEM=16g CPUS=4 ./run.sh
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `MEM` | `32g` | 内存硬上限 |
| `CPUS` | `8` | CPU 配额 |
| `SHM` | `2g` | `/dev/shm`，默认 64M 会让并行编译和 DataLoader 炸掉 |
| `PIDS` | `512` | 进程/线程数上限，防止 fork 炸弹 |

`--memory-swap` 故意设成和 `--memory` 相等，表示**容器内禁用 swap**：用满上限时
内核直接杀掉容器里的进程，而不是让整机开始疯狂换页。这就是 cgroup v2 的
`memory.max`，容器里可以自己看：

```bash
cat /sys/fs/cgroup/memory.max
```

## 日常操作

```bash
./run.sh             # 启动（已存在则 start）
./run.sh --rebuild   # 改完 Dockerfile 后重建
./run.sh --logs      # 看 sshd 日志
./run.sh --rm        # 删掉容器（挂载的数据不受影响）
docker exec -it dev zsh   # 不经过 sshd 直接进
```

## 几个容易踩的坑

**代理。** 如果宿主机靠 shell 函数（比如 `pon`/`poff`）开关代理，那些函数不会跟进
容器。`run.sh` 用 `-e http_proxy` 这种方式把宿主机环境变量透传进去，所以先开代理
再 `./run.sh`。**不要把代理地址写进 `Dockerfile`**——镜像会被推来推去，地址会跟着跑。

**host key 变化。** 容器重建后如果 host key 重新生成，客户端会报
`REMOTE HOST IDENTIFICATION HAS CHANGED`。这里把 key 放在命名卷
`dev-ssh-hostkeys` 里，重建容器不受影响。

**文件归属。** 容器里写出的文件 uid 必须等于你。`run.sh` 构建时传 `--build-arg
UID=$(id -u)`，所以 `ls -l` 不会出现一串数字 uid。如果出现了，检查构建参数和实际
用户是否一致。

**`~/.vscode-server` 越来越大。** 它在挂载的家目录里，好处是重建镜像不用重装扩展，
坏处是 VS Code 升级后会留下旧版本。偶尔 `rm -rf ~/.vscode-server` 重连即可。

## 不用 Docker 行不行

行。如果你在宿主机上有完整权限，直接 `apt install` + 自己的 dotfiles 仓库也能达到
"环境可复现"。容器主要多给你两样：**不会弄坏共享机器的系统**，和**一个硬性的资源
上限**。如果这两条不重要，别套这一层，它带来的复杂度（挂载、uid、端口、镜像层）
是实打实的。

## 边界

- **`docker` 组等价于 root。** 组内成员可以 `docker run -v /:/host` 拿到整机 root。
  共享机器上"别人进不了我的容器"靠的是**组里只有你自己**，这是策略，不是机制隔离。
  真要机制隔离，用 rootless Podman。
- **容器不对宿主机隐藏进程。** 宿主机 `ps` 能看到容器里的一切。想隐藏得靠
  `/proc` 的 `hidepid` 挂载选项，那是全机设置，和容器无关。
- **容器不是虚拟机。** 内核是共享的，容器内的 root 只在容器内有意义。
- 这是**开发环境**，不是用来跑对外服务的。别把 22 以外的端口暴露到公网。
