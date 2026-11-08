# dev-container

在大服务器上开一个自己的 Docker 容器当开发机，用 SSH 或 VS Code Remote-SSH 连进去。

大机器通常是共用的，账号里不能随便 `apt install`，装了也怕和别人的版本打架。这个容器把这些隔开：里面是一套干净的 Ubuntu 22.04，zsh、uv、rustup、graphviz、中文字体都装好了，随便折腾，重建一次就回到原样。

```
你的电脑 ──SSH──▶ 宿主机 ──端口转发──▶ 容器
 VS Code           Docker            sshd + zsh + uv + rust
```

## 用法

宿主机上先装 Docker：

```bash
sudo apt install docker.io
sudo usermod -aG docker "$USER"   # 重新登录生效
docker run --rm hello-world       # 确认能跑
```

然后：

```bash
./run.sh
```

跑完会打印一段 `~/.ssh/config`，贴到自己电脑上，`ssh dev` 就能进。VS Code 装 Remote - SSH 扩展，选 `dev`，是同一回事。

改过 `Dockerfile` 之后：

```bash
./run.sh --rebuild
```

挂载的目录不受影响。其他命令：`--logs` 看 sshd 日志，`--rm` 删掉容器，`docker exec -it dev zsh` 不经过 sshd 直接进。

## 挂载

镜像只管环境，东西都放在挂载目录里，所以重建镜像不丢。

宿主机的 `$HOME` 挂到容器里**同样的路径**。这一点很关键：路径不一致的话，dotfiles、`~/.vscode-server`、脚本里写死的路径全都对不上。数据目录默认用 `/data/<用户名>`（存在的话），否则用 `$HOME/work`，挂进去也是同路径。

如果数据盘是机械硬盘，代码和 `target/`、`.venv` 别放上去，`cargo build` 和 `uv sync` 会被随机读写拖慢。数据集放数据盘，构建产物留在家目录。

## 资源限制

`run.sh` 顶上几个变量，用环境变量覆盖：

```bash
MEM=16g CPUS=4 ./run.sh
```

默认 32g 内存、8 核、512 个进程、2g shm。`--memory-swap` 和 `--memory` 设成一样，表示容器里不用 swap：用满了直接杀掉容器内的进程，整机不会跟着卡死。

`--shm-size` 值得单独说。默认 64M 太小，cargo 并行编译和 PyTorch DataLoader 会崩得莫名其妙，报错还看不出来是它。

## 端口

默认只绑 `127.0.0.1:2222`，只有宿主机自己能连。从外面连走跳板，`run.sh` 打印的配置里已经带了 `ProxyJump`：

```
你的电脑 ──SSH──▶ 宿主机 ──本地转发──▶ 127.0.0.1:2222 ──▶ 容器
```

宿主机在内网、或者有防火墙兜底的话，也可以直接暴露：

```bash
BIND_ADDR=0.0.0.0 ./run.sh
```

## 里面装了什么

- **uv**：单个静态二进制，从官方镜像拷。镜像里没装 Python 解释器，`uv sync` 会按 `pyproject.toml` 把需要的版本下载到项目里。
- **Rust**：`rustup` 装在 `/opt` 而不是 `$HOME`。`$HOME` 是挂载的，镜像里写进去会被覆盖，这是最容易踩的坑。`/opt` 下给了所有人写权限，换 uid 重建也不用重装。另外装了 `clang` 和 `mold`，链接比默认的 `ld` 快不少。
- **graphviz**：要的是 `dot` 这个二进制。Python 的 `graphviz` 包只是接口，不会自己排版。
- **fonts-noto-cjk**：画中文图必需。缺了它 matplotlib 会静默退回 DejaVu，图上的中文全变成方块，而且不报错。

## 几个坑

**代理。** 宿主机要是用 shell 函数开关代理（`pon`/`poff` 之类），那些函数不会跟进容器。`run.sh` 用 `-e http_proxy` 把宿主机环境变量透传进去，所以先开代理再 `./run.sh`。别把代理地址写进 `Dockerfile`，镜像推来推去会把内网地址带走。

**host key。** 容器重建后 host key 重新生成的话，客户端会报 `REMOTE HOST IDENTIFICATION HAS CHANGED`。这里把 key 放在命名卷 `dev-ssh-hostkeys` 里，重建不受影响。

**文件归属。** 容器写出的文件 uid 必须等于你，否则 `ls -l` 里是一串数字。`run.sh` 构建时传了 `--build-arg UID=$(id -u)`，正常不会出问题。真出现了，检查构建参数和当前用户是否一致。

**`~/.vscode-server` 会变大。** 它在挂载的家目录里，好处是重建镜像不用重装扩展，坏处是 VS Code 升级后留着旧版本。偶尔 `rm -rf ~/.vscode-server` 重连就行。

## 边界

`docker` 组等价于 root，组里的人可以 `docker run -v /:/host` 拿到整机权限。共享机器上"别人进不了我的容器"靠的是组里只有你，是策略不是机制隔离，要机制隔离用 rootless Podman。

容器也不对宿主机隐藏进程，宿主机 `ps` 什么都看得到。要藏得靠 `/proc` 的 `hidepid`，那是全机设置，和容器没关系。

这是开发环境，不是拿来跑对外服务的。
