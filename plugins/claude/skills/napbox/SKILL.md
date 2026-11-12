---
name: napbox
description: 项目需要数据库、对象存储、后端这类本地服务，或者有 compose.yaml / docker-compose.yml，要运行、测试、连接这些服务时使用；新项目要加这些服务、要写 compose 或启动脚本时也用。napbox 用同一份 compose 给每个 worktree 起一套隔离的服务，代替 docker compose up。
---

# 用 napbox 运行项目的服务

napbox 按项目的 compose 文件给每个 worktree 起一套隔离的服务。不用 Docker，端口由 napbox 分配，多个 worktree 同时运行也不冲突。

## 基本流程

1. 调用 `up` 工具。它等服务都就绪后返回端口和变量，比如 `NAPBOX_API_3100` 是 `127.0.0.1:41217`。
2. 代码和测试连返回的地址，不要写死 compose 里的端口，也不要写死 napbox 给的端口。换了会话或忘了端口，用 `env` 工具查。
3. 在服务里执行命令（迁移、psql）用 `exec` 工具；看日志用 `logs` 工具。

同一个环境的端口固定不变：休眠、唤醒、再次 `up`、napboxd 重启后都是同一个，别的程序也占不走。换 profile 再 `up` 也一样：没启用的 profile 里的服务也留着端口，启用后就是那个，所以分几步 `up`、每次带不同的 profile，端口也不会变（只是每换一次定义，整个环境重启一次）。只有 `down` 回收环境后才释放。告诉用户地址时不用说“可能会变”。但这只对这一个环境成立：另一个 worktree、临时环境、`down` 之后再起，都是别的端口，所以写进代码和提交的配置里仍然不行。

不用手动启停：闲置 30 分钟会自动休眠，下次连接时自动唤醒。刚唤醒的第一条连接要等约 1 秒。

## 新项目要用到这些服务

这台电脑上的服务由 napbox 起，不用 Docker。给项目写 compose、启动脚本、测试脚本和 README 时照下面写，这样项目一开始就是 napbox 的写法，以后不用再迁：

- compose 写成仓库根目录的 `compose.yaml`（放在别处就写 `.napbox.yaml`，见下面）。写完调 `up` 起来验证。
- `ports` 只写容器端口（`- "5432"`），不写宿主机端口，宿主机端口由 napbox 分配。
- 程序从环境变量读服务的地址和端口，不给默认端口；没设就报错退出。启动脚本、测试脚本从 `npx napbox up` 或 `npx napbox env` 的 JSON 里取地址，传给程序。
- 建库、建角色、跑迁移写成一次性服务，见下面「服务启动前要先建库」。
- 脚本里不调 `docker`：要用完就扔的库用 `npx napbox up --temp`，要单独跑一次某个服务用 `npx napbox run`。README 里写这些命令，不写 `docker compose`。
- 只用 napbox 支持的写法：不写 `read_only`、`cpus`、`pids_limit`、`security_opt`、`platform`；镜像和 Dockerfile 的 `FROM` 用公开仓库能拉到的。自己写的 compose 报 `compose_unsupported` 时，按错误信息改掉。

## 常见情况

- **前端、小程序、App 要连环境里的后端**：它们跑在本机，不在环境里，后端地址要由项目的启动脚本交给它们。脚本从 `npx napbox up` 返回的 JSON（或 `npx napbox env`）里取出后端的地址：网页前端（vite 这类）用环境变量传进去；读不到环境变量的（微信小程序、手机 App）由脚本生成一份本地配置文件，加进 `.gitignore`，不提交。缺这份文件时明确报错、提示先运行启动脚本，不要悄悄回退到原来的地址。单元测试自己给一个固定地址，不依赖这份文件。不要为了凑回原来的端口去改 compose。
- **compose 文件不在默认位置**：给 `up` 传 `files`，或者在 worktree 根目录写 `.napbox.yaml`，内容是 `compose: server/compose.yaml`。
- **改了 compose**：再调一次 `up`，会按新定义重建。
- **改了 Dockerfile 或打进镜像的文件**：给 `up` 传 `build: true`，和 `docker compose up --build` 一样。不传时只在镜像还没有时构建。源码挂载进容器的文件不用重新构建。
- **compose 写了 `develop.watch`**：`up` 后就生效，不用 `docker compose watch`。改文件自动同步、重建、重启，休眠期间改的唤醒时补上。觉得没同步时看 `status` 的 `watchError`。
- **`image_build_failed`**：错误信息里有构建输出的最后几十行和完整日志的路径。修好 Dockerfile 后传 `build: true` 再调 `up`。失败不影响已经在跑的环境。
- **服务启动前要先建库、建角色、跑迁移**：写成一次性服务（`restart: "no"`，做完就退出），后端用 `depends_on` 的 `condition: service_completed_successfully` 等它跑完。不要让后端连不上就退出、靠 `restart` 重试：napbox 里一个服务按 `restart` 重启，整个环境连数据库一起重启，会一直重来。数据库的 `healthcheck` 要走 TCP（比如 `pg_isready -h 127.0.0.1`），postgres 第一次初始化时只开本地 socket 的临时服务也会让 socket 检查通过。
- **要清空数据**：`reset` 只清指定的数据卷，旧数据保留 7 天。
- **测试要一套用完就扔的服务**（比如一个空的数据库，以前会用 `docker run` 起）：给 `up` 传 `temp`（自己起个名字）。它在开发环境之外另起一个临时环境，返回它自己的端口；`env`、`logs`、`exec`、`egress` 传同一个 `temp` 就是操作它。用完调 `down` 传同一个 `temp`，数据直接删掉。临时环境不休眠，闲置了自己销毁，也没有 `sleep`、`reset`。
- **要单独跑一次某个服务**（测试、检查，以前会用 `docker compose run`）：用 `run` 工具。它临时起一个环境、在前台跑这个服务、跑完销毁，返回退出码和输出。
- **把这两件事写进项目的脚本**：对应的命令行是 `npx napbox up --temp <名字>`、`npx napbox down --temp <名字>` 和 `npx napbox run <服务> [-- 命令]`，`run` 的退出码和那个服务一样。
- **工具报 `daemon_unavailable`**：调用 `setup`。它会下载约 700MB 的内核包并注册登录项，要先让用户知道。
- **`compose_unsupported`**：compose 用了 napbox 不支持的写法，错误信息里有说明。项目原有的 compose 不要改，把情况告诉用户。
- **`image_unavailable`，且镜像在 Docker 里有**：用 `image_import` 导入。

## 限制

- 不能单独重启一个服务，`restart` 规则和 `up` 都是整个环境一起重启。
- `exec` 不支持交互，要在容器里切目录或设变量就用 `["sh", "-c", "..."]`。
- 构建镜像时拿不到本机 Docker 的登录信息和本地镜像：Dockerfile 的 `FROM` 要是公开仓库能拉到的镜像。
- 只支持 Apple 芯片的 Mac。
