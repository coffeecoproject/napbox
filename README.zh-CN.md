# napbox

[English](README.md)

给 coding agent 用的 Mac 本地开发环境，不用 Docker，只支持 Apple 芯片。

napbox 按项目的 compose 文件，给每个 git worktree 起一套隔离的服务（数据库、对象存储、后端）。宿主机端口由 napbox 分配，同一个环境的端口固定不变。闲置的环境自动休眠，下次有连接进来时自动唤醒。agent 通过 MCP 工具使用它，项目脚本用 `napbox` 命令。

底层是苹果开源的 [Containerization](https://github.com/apple/containerization)：一个环境一台轻量的 Linux 虚拟机，环境里的服务都在这台虚拟机里。

**状态：0.1.13，早期版本。** 已经在一台电脑上给好几个项目日常使用（带 PostGIS 的 PostgreSQL、Redis、MinIO、Go 和 Node 后端、nginx 前端），但还会有不顺手的地方。

## 为什么

用 Docker compose 同时让几个 coding agent 各在一个 worktree 里干活，会碰到三件事：

- **端口冲突。** compose 里把宿主机端口写死了，第二个 worktree 一 `up` 就卡在 5432 上。改成共用一个库，这个 agent 跑迁移又会弄乱那个 agent 的数据。
- **内存回不来。** 只要还有一个容器在跑，Docker Desktop 的虚拟机就占着分给它的全部内存，而 agent 起了的东西很少会关。
- **agent 用 Docker 不顺手。** 要自己拼 `docker compose` 命令、猜端口，用完的容器一直留着。

用 napbox，每个 worktree 按同一份 compose 起一套自己的服务，端口不冲突，`down` 之前一直不变。闲置的环境休眠，内存还给 macOS，下次连接时唤醒，数据库一般约 1 秒就能连上。新 worktree 可以带着主目录的数据起来。agent 用 MCP 工具，拿到的是 JSON。

想几分钟看明白，就跑一遍[演示项目](examples/demo/README.zh-CN.md)。

## 要求

- macOS 26 或更新版本，Apple 芯片
- Node.js 22.22 或更新版本
- 用插件需要 Claude Code，用 MCP 工具也可以是 Codex（`napbox` 命令两个都不依赖）

## 安装

在 Claude Code 里：

```
/plugin marketplace add coffeecoproject/napbox
/plugin install napbox@napbox
```

agent 第一次要起服务时，napbox 会报还没准备好，agent 就去调用 `setup` 工具（Claude Code 会先问你）。setup 会：

- 从 GitHub 下载 Kata Containers 的内核包（约 700MB，按固定的校验值核对）和 runc（约 10MB），从 ghcr.io 拉取 vminit 镜像；
- 没装 Rosetta 时请 macOS 安装（虚拟机里运行 x86 的程序要用）；
- 把 `napboxd` 放到 `~/Library/Application Support/napbox/`，注册成登录项（`~/Library/LaunchAgents/io.github.coffeecoproject.napbox.plist`）。

在 Codex 里：

```
npx napbox setup codex
```

它做同样的 setup，再把 napbox 的 MCP 工具加进 Codex（用的是 `codex mcp add`）。Codex 里只有工具：技能和钩子（会话开始时告诉 agent 端口、拦下 `docker compose up`）是 Claude Code 插件里的。

不用 agent 的话：`npx napbox setup`。

## 怎么工作

- **一个 worktree 一个环境。** 环境叫 `<项目>/<worktree>`，主工作区是 `<项目>/main`。同一个项目的两个 worktree 可以同时运行，端口不冲突。
- **端口。** compose 里只写容器端口（`- "5432"`）。napbox 在 `127.0.0.1` 上分一个宿主机端口，这个环境一直用它：休眠、唤醒、再次 `up`、napboxd 重启、换 profile 都不变，`down` 了才释放。别的 worktree 和临时环境是别的端口，所以要从 `napbox env` 读，不要写死。环境里的服务要知道自己在宿主机上的地址时（比如服务端生成给浏览器打开的链接），在 `environment` 或 `env_file` 里写 `${NAPBOX_API_3100}`，起服务时换成这个环境分到的地址（`127.0.0.1:41217`）。
- **浏览器用的主机名。** 每个环境还有一个主机名，比如 `feat-x--crocwork.localhost`，解析到本机，不用配置。浏览器按主机名存 cookie、不看端口，所以页面地址用它：同一个浏览器里同时开几个 worktree，登录不会互相覆盖。每个端口有一个 `NAPBOX_API_3100_SITE=feat-x--crocwork.localhost:41217`，主机名本身是 `NAPBOX_HOSTNAME`；compose 里也能引用（`PUBLIC_ORIGIN: http://${NAPBOX_API_3100_SITE}`）。程序连服务还是用 `127.0.0.1`。napbox 同时占着 `127.0.0.1` 和 `[::1]` 上的端口。
- **本机上跑的进程的端口。** 项目自己在本机跑的程序（开发后台、页面测试起的后台和网页）也要每个 worktree 一组端口时，在 compose 顶层写 `x-napbox: {host_ports: [server, web]}`。每个名字分一个端口，变量是 `NAPBOX_HOST_SERVER=41230`（只是端口号），和服务的端口一样固定到 `down`。napbox 不占着这些端口，由项目的程序自己监听：分的时候确认没人在用，之后要是被别的程序占了，项目的程序启动时会报端口被占。名字用小写字母、数字和下划线，小写字母开头，不能以 `_数字` 或 `_数字_site` 结尾。
- **主目录的数据。** 在 compose 顶层写 `x-napbox: {seed: [pgdata, s3data]}`，新 worktree 就带着主目录的数据（账号、上传的文件）起来，不是空卷。worktree 的环境每次正常停下（闲置休眠、`napbox sleep`、napboxd 退出），napbox 把这些卷用 APFS 克隆留一份快照；新 worktree 第一次 `up` 复制主目录最新的快照，主目录不停也不冻结。复制只要几毫秒，两边都没写之前不多占空间。主目录还没有快照时 `up` 报 `snapshot_not_found`，不会用空卷起来。服务都在各自的 `stop_grace_period`（没写是 10 秒）内退出、存盘成功才算正常停下；没正常停下不拍快照，`status` 的 `snapshotError` 写着原因（`snapshot_not_found` 的报错里也有）。服务停得慢的，先看它的日志在等什么（有的等待可以关掉），确实要的时间再用更长的 `stop_grace_period` 留出来。迁移这类一次性服务会在复制来的数据上再跑一次。
- **休眠。** 30 分钟没有连接就休眠，内存还给 macOS。下次连它的端口就自动唤醒，这条连接只等它连的服务（和这个服务依赖的）就绪，数据库一般约 1 秒，环境里其余服务在后台接着起。服务按依赖顺序一个个启动，排在后面的服务要等前面的先启动。这些服务里有写了 `develop.watch` 同步规则的，连接等整个环境起完，休眠期间改的文件这时已经同步进去。
- **临时环境。** `napbox up --temp <名字>` 在开发环境旁边另起一个用完就扔的环境（比如测试用的空库），`napbox down --temp <名字>` 删掉它。它的数据马上就删，所以 `down` 直接关掉它的虚拟机，不等服务收尾。`napbox run <服务>` 临时起一个环境，在前台跑一个服务，返回它的退出码。
- **构建。** 写了 `build:` 的服务在单独的虚拟机里用 BuildKit 构建，所有环境共用一份构建缓存。构建出的镜像归这个环境自己，别的环境（包括临时环境）用不上；`down` 时一起删，下次 `up` 重新构建，没改过的步骤用缓存。
- **发到 x86 服务器的镜像。** 服务写 `platform: linux/amd64`，镜像就拉 x86 的、构建成 x86 的，在本机由 Rosetta 执行，所以本机测的就是要发出去的那一份。`napbox save -o images.tar` 按 compose 构建（没写 `build` 的拉下来），写成 `docker image load` 能读的 tar。包里的镜像名是服务的 `image`，没写是 `<项目名>-<服务名>:latest`；输出的 JSON 里有每个镜像的 digest，服务器的 Docker 用 containerd 镜像库时，加载后的镜像 ID 就是它。`save` 不起环境，不碰开发环境；构建出的镜像导出后就删，构建缓存留着。上传和部署由项目自己做。
- **网络。** 环境访问不到宿主机和局域网。`napbox egress none` 还会断开外网，只剩同一个环境里的服务能互相访问。
- **服务要用本机上的程序。** 服务要调本机 `127.0.0.1` 上监听的程序（比如本地的模型反代）时，在 compose 顶层列出它的端口：`x-napbox: {host_services: [8317]}`。服务连 `host.docker.internal:8317`，名字和 Docker Desktop 的一样。napboxd 经虚拟机自己的通道（不走网络）在本机替它连 `127.0.0.1:8317`，本机别的端口和局域网照样连不到，那个程序也只用监听 `127.0.0.1`。这个环境里的任何代码都能用列出的程序，临时环境也一样；`egress none` 时连它会被拒绝。用 `confine: true` 建的环境不能列。
- **由别的程序持有的环境。** 在项目副本上跑编程 agent 的程序（比如 CodeOS）可以用 TypeScript 客户端自己建环境：`new NapboxClient().create({ name: "codeos/goal-12", owner: "codeos", directory: "/副本/路径" })`。agent 能改副本里的 compose、又不该碰本机别的文件时传 `confine: true`：napbox 会读或会挂进环境的宿主机路径（compose 文件、`.env`、`.napbox.yaml`、`env_file`、绑定挂载、`secrets` 的文件、构建的 `context` 和 Dockerfile、`.dockerignore`、`develop.watch` 的路径），解开符号链接后都要在 `directory` 以内，否则 `create` 报 `path_outside_directory`，什么也不起。napbox 记下副本目录的真实路径，之后每次构建、起环境（唤醒、`reset`、按 restart 重启、`develop.watch` 重建）前都再查：之后把里面的目录、或者副本目录本身换成符号链接，环境就起不来。虚拟机只共享副本目录本身，查完之后再换上的符号链接在虚拟机里解析，到不了本机。持有环境的程序要保证 agent 删不掉、建不了副本目录本身：恰好卡在最后一次检查和虚拟机打开目录之间换掉它，napbox 拦不住。结果里带 `confined: true`。旧版 napboxd 不认识 `confine`、会不加限制照常起环境，所以客户端先确认 napboxd 是 0.1.7 以上再发。

## 命令

命令都输出 JSON（`napbox status --text` 输出表格）。

| 命令 | 作用 |
|---|---|
| `napbox up [-f compose] [--build] [--profile P]` | 创建或唤醒环境，等服务都就绪，输出端口和变量 |
| `napbox env` | 输出 `export NAPBOX_<服务>_<端口>=127.0.0.1:<端口>`（还有给浏览器的 `_SITE` 和 `NAPBOX_HOSTNAME`），可以直接 `eval "$(napbox env)"` |
| `napbox status [--text]` | napboxd 和各环境的状态、端口 |
| `napbox logs <服务> [--tail N] [-f]` | 服务的日志，不唤醒环境 |
| `napbox exec <服务> -- <命令>` | 在服务里执行命令（不支持交互） |
| `napbox run <服务> [-- <命令>]` | 在临时环境里把一个服务跑一次 |
| `napbox save -o <文件> [服务...]` | 构建并导出镜像，写成 `docker image load` 能读的 tar，不起环境 |
| `napbox reset <数据卷...> [--from <目录>]` | 清空命名卷；带 `--from` 时换成同一个项目另一个 worktree 环境最新的快照（旧数据保留 7 天） |
| `napbox sleep` / `napbox down` | 马上休眠 / 回收环境（数据保留 7 天） |
| `napbox egress <open\|none>` | 切换能不能上外网 |

`up`、`env`、`logs`、`exec`、`egress`、`down` 可以加 `--temp <名字>`。

## 支持的 compose 写法

本地开发的 compose 常用的写法都支持。别的写法直接报错，说清楚是哪里、为什么，不会悄悄忽略。

支持：`image`、`build`（`context`、`dockerfile`、`target`、`args`）、`command`、`entrypoint`、`environment`、`env_file`、`working_dir`、`init`、`shm_size`、`tmpfs`、`pull_policy`、`platform`（`linux/arm64`、`linux/amd64`）、`stop_grace_period`、`ports`（只取容器端口）、`expose`、`volumes`（命名卷、目录和单个文件）、带条件的 `depends_on`、`healthcheck`、`restart`、`profiles`、`develop.watch`、`secrets`（文件形式）、内存上限（`mem_limit`、`deploy.resources.limits.memory`；没写的服务和 Docker 一样不单独封顶，共用整个环境的内存）、默认网络、变量替换、多份 compose 合并、YAML 合并键。

不支持的有：`read_only`、`cpus`、`pids_limit`、`security_opt`、`privileged`、`cap_add: NET_ADMIN`、`network_mode`、`configs`、YAML 标签 `!reset` 和 `!override`，以及上面四个以外的 `build` 选项。

## 和 Docker 不一样的地方

- 不能单独重启一个服务。一个服务按 `restart` 重启时，整个环境一起重启。建库、跑迁移这类准备工作写成一次性服务，后端用 `condition: service_completed_successfully` 等它跑完。
- 环境之间互相访问不到。同一个环境里的服务可以用服务名互相访问。
- 多个网络合成一个：同一个环境里的服务都能互相访问，网络上写的 `internal: true` 不起作用。要断外网，用 `napbox egress none` 断整个环境的。
- `napbox run` 的服务照常分配宿主机端口，和 `docker compose run` 不同。
- `exec` 没有交互终端。
- 构建时用不了本机 Docker 的登录信息和本地镜像：`FROM` 要能从公开仓库拉到。
- napbox 不导出镜像，发布用的镜像要用别的工具打包，比如苹果的 `container`。
- 内存只在环境休眠时才还给 macOS。
- 虚拟机用系统共用的 NAT 网，网段是 `192.168.64.0/24`。这个网段被别的程序的虚拟机网络占了时，起环境报 `address_unavailable`（连不上网关）。常见两种：苹果 `container` 没固定网段，在 `~/.config/container/config.toml` 写 `[network]` `subnet = "192.168.65.0/24"` 再重启它；用虚拟机网络的程序崩溃后系统留着网段不放，运行 `sudo killall InternetSharing` 或重启电脑。
- 虚拟机没有交换空间。服务卡在内存上（到了自己的上限，或整个环境的内存用完）时，napbox 结束占内存最多的那个进程，在服务的日志里写明原因，不让它一直卡着。

## 参与贡献

问题和想法欢迎提 [issue](https://github.com/coffeecoproject/napbox/issues)。

贡献代码需要先签贡献者许可协议（CLA）。贡献的版权仍归你；CLA 允许 coffeecoproject 按项目当前的许可证发布你的贡献，以后也可以按别的条款发布，包括商业条款。CLA 还没准备好，所以暂时不接受 pull request，请先提 issue。

## 许可证

[Functional Source License 1.1, ALv2 Future License](LICENSE)（FSL-1.1-ALv2）。可以为任何目的使用、修改和再分发 napbox，包括在工作中用它开发商业项目；只是不能拿它做成商业产品或服务提供给别人，用来替代 napbox 或提供基本相同的功能。每个版本发布满两年后，也可以按 Apache License 2.0 使用。

0.1.7 及以前的版本按 [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) 发布，仍然适用 Apache License 2.0。

npm 包里带了第三方代码，见 [NOTICE](NOTICE)。
