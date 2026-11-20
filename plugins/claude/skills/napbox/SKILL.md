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

不用手动启停：闲置 30 分钟会自动休眠，下次连接时自动唤醒。唤醒时连接只等它连的服务（和这个服务依赖的）就绪，数据库一般约 1 秒；连启动慢的后端要等后端自己起来。服务按依赖顺序一个个启动，排在后面的服务要等前面的先启动。连的服务（或它依赖的）写了 `develop.watch` 同步规则时等整个环境起完，休眠期间改的文件这时已经同步进去。

## 新项目要用到这些服务

这台电脑上的服务由 napbox 起，不用 Docker。给项目写 compose、启动脚本、测试脚本和 README 时照下面写，这样项目一开始就是 napbox 的写法，以后不用再迁：

- compose 写成仓库根目录的 `compose.yaml`（放在别处就写 `.napbox.yaml`，见下面）。写完调 `up` 起来验证。
- `ports` 只写容器端口（`- "5432"`），不写宿主机端口，宿主机端口由 napbox 分配。
- 程序从环境变量读服务的地址和端口，不给默认端口；没设就报错退出。启动脚本、测试脚本从 `npx napbox up` 或 `npx napbox env` 的 JSON 里取地址，传给程序。
- 建库、建角色、跑迁移写成一次性服务，见下面「服务启动前要先建库」。
- 脚本里不调 `docker`，也不调苹果的 `container` 这类别的容器工具：要用完就扔的库用 `npx napbox up --temp`，要单独跑一次某个服务用 `npx napbox run`。README 里写这些命令，不写 `docker compose`。
- 要发到 x86 服务器的镜像：服务写 `platform: linux/amd64`，发版脚本用 `npx napbox save -o images.tar` 构建并导出，不用 `docker build`、`container build`。包是 `docker image load` 能读的 tar，镜像名是服务的 `image`，输出的 JSON 里有每个镜像的 digest。上传、部署还是项目自己的脚本做。
- 测试用的一次性数据库，数据也放命名卷，和开发库一样，不用 `tmpfs` 内存盘：临时环境的卷随环境一起删；命名卷是标准的 ext4，速度和内存盘相近；内存盘里的数据算环境的内存，库大了会把别的服务挤掉。
- 只用 napbox 支持的写法：不写 `read_only`、`cpus`、`pids_limit`、`security_opt`；镜像和 Dockerfile 的 `FROM` 用公开仓库能拉到的。自己写的 compose 报 `compose_unsupported` 时，按错误信息改掉。

## 网页页面测试（端到端、截图对比）

被测的服务、网页和浏览器都放进 napbox 的环境，本机只跑测试运行器（Playwright）。不用本机装的 Chrome，也不用别的容器工具起浏览器。

- **被测的那一套和线上一样组装**：入口代理、构建好的前后端都写成 compose 服务，页面测试连这一套，不连开发服务器。
- **构建好的前后端在 Dockerfile 里构建**（多阶段的 `target`），compose 用 `build:` 打进镜像。不要在本机编译好再把 `dist` 挂进去：本机的 `dist` 是这个目录里单元测试、类型检查和别的 worker 共用的，会一边写一边被读；打进镜像的每个环境各一份，`down` 时一起删，没改过的步骤用缓存，几秒就好。构建上下文用 `.dockerignore` 排除 `node_modules`、`dist` 和本机的运行状态文件。
- **每个 worker 一套临时环境**：测试脚本按 worker 数起 `npx napbox up --temp e2e-<编号>`，跑完 `npx napbox down --temp e2e-<编号>`。各套有自己的数据库，并行互不干扰。
- **浏览器是环境里的一个服务**，跑 Playwright 自带的 `run-server`，用的是项目自己装好的 Playwright（把仓库目录只读挂进去，pnpm 的软链接、monorepo 子目录里的依赖都能解析）。写在单独一个 compose 文件里（比如 `e2e/browser.compose.yaml`），起页面测试的环境时和被测的那份一起传给 `up`（`--file` 给两次，按顺序合并）；没有被测环境的场合（比如往开发环境里录数据）也能单独起一套只有浏览器的：

  ```yaml
  services:
    browser:
      image: mcr.microsoft.com/playwright:v1.60.0-noble   # 和项目装的 Playwright 同一版本
      init: true
      shm_size: 1g
      volumes:
        - ..:/work:ro   # 仓库根目录，相对这份 compose 所在的目录
      command: ["node", "/work/node_modules/@playwright/test/cli.js", "run-server", "--port", "3000", "--host", "0.0.0.0"]
      ports: ["3000"]
      healthcheck:   # 端口通了才算起好，up 返回后就能连
        test: ["CMD", "node", "-e", "require('net').connect(3000,'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))"]
        interval: 1s
        retries: 30
  ```

  `cli.js` 的路径按项目里装 Playwright 的位置写（monorepo 里可能在 `e2e/node_modules` 下，只装了 `playwright` 的就是 `node_modules/playwright/cli.js`）。
- **本机的测试运行器连它**：Playwright 配置里 `use.connectOptions` 写 `{ wsEndpoint: 'ws://' + 这套环境的 NAPBOX_BROWSER_3000 + '/', exposeNetwork: '<loopback>' }`，每个 worker 连自己那套环境的浏览器。
- **用完整的 Chromium**：`use` 里同时写 `channel: 'chromium'`，浏览器服务按它启动镜像里装着的完整 Chromium。不写时用的是 Playwright 默认的精简版无界面浏览器（`chrome-headless-shell`），和用户的浏览器有差别。napbox 的环境是 Linux ARM，没有 Chrome 和 Edge，`channel: 'chrome'` 用不了，Chromium 和 Chrome 同一个内核。项目里有几份 Playwright 配置连同一个浏览器服务时（比如页面测试和录数据），连法和 `channel` 放在一个共用的模块里，各份配置引用它。
- **页面地址用这套环境的 `_SITE` 地址**（入口代理的 `http://${NAPBOX_GATEWAY_80_SITE}` 这类，主机名见下面「浏览器打开的页面地址用主机名」），测试在本机用 `request` 登录、调接口也用同一个地址：`exposeNetwork: '<loopback>'` 包括 `*.localhost`，浏览器打开它经测试的连接回到本机，环境断网（`egress none`）时也通。这样本机登录拿到的 cookie 交给浏览器照样能用，页面也算安全来源，`crypto.randomUUID`、剪贴板、通知这些只在安全来源能用的接口照常可用。不要写服务名（`http://gateway`）：它不算安全来源，cookie 的域名也和本机调接口的对不上。
- **版本要一致**：镜像 tag 和项目装的 Playwright 同一版本，镜像里的浏览器是按版本配的，不一致时报找不到浏览器；测试运行器和浏览器服务的 Playwright 版本不同时，一连就报 `Playwright version mismatch`。升级 Playwright 时一起改镜像 tag。
- **登录状态按 worker 各存一份**：登录是在某一套环境的数据库里登的，cookie 也只记在那套环境的主机名下。在全局准备阶段登录一次、存成一个 `storageState` 文件给所有 worker 用，别的 worker 拿到的等于没登录。每个 worker 在自己那套环境里登录，存到按 worker 编号命名的文件。
- **上传、下载、截图、trace 照常用**：`setInputFiles` 传本机的文件，下载 `saveAs`、截图、trace 都写在本机的输出目录。没有有头的窗口，失败了看 trace（`npx playwright show-trace`），不要为了看窗口改回本机浏览器。
- **截图对比的基准图用环境里这个浏览器拍**（Linux、arm64），镜像或 Playwright 版本变了要重拍。
- **要确认页面不依赖外网**：起好临时环境后调 `egress`，传 `none` 和同一个 `temp`（脚本里是 `npx napbox egress none --temp <名字>`），外网请求直接失败，环境里的服务照常能访问。

## 常见情况

- **前端、小程序、App 要连环境里的后端**：它们跑在本机，不在环境里，后端地址要由项目的启动脚本交给它们。脚本从 `npx napbox up` 返回的 JSON（或 `npx napbox env`）里取出后端的地址：网页前端（vite 这类）用环境变量传进去；读不到环境变量的（微信小程序、手机 App）由脚本生成一份本地配置文件，加进 `.gitignore`，不提交。缺这份文件时明确报错、提示先运行启动脚本，不要悄悄回退到原来的地址。这份文件是端口的副本：项目回收环境的命令要一起删掉它，项目说明里写明起停环境用项目的脚本（直接调 napbox 的 `up`、`down` 不会更新它）。单元测试自己给一个固定地址，不依赖这份文件。不要为了凑回原来的端口去改 compose。
- **浏览器打开的页面地址用主机名**：每个环境有自己的主机名（`feat-x--crocwork.localhost`，解析到本机，不用配置），每个端口有一个 `NAPBOX_<服务>_<端口>_SITE`（主机名加端口），主机名本身是 `NAPBOX_HOSTNAME`。浏览器按主机名存 cookie、不看端口，都用 `127.0.0.1` 时同一个浏览器里开几个 worktree 会互相覆盖登录。启动脚本给人打开的页面地址、服务端生成给浏览器的链接、允许的来源都用 `_SITE`；本机程序的端口拼成 `http://${NAPBOX_HOSTNAME}:${NAPBOX_HOST_WEB}`。后端校验 `Host` 或来源的（允许的来源、`ALLOWED_HOSTS` 这类）要放行这个主机名。程序连服务（数据库、本机脚本调接口）还是用 `127.0.0.1` 的那个变量。小程序、手机 App 这类不在本机浏览器里打开的不一定认 `*.localhost`，照旧用原来的地址。
- **环境里的服务要知道自己在宿主机上的地址**（比如服务端生成给浏览器打开的链接、允许的来源）：在 compose 的 `environment` 或 `env_file` 里写 `PUBLIC_ORIGIN: http://${NAPBOX_API_3100_SITE}`（给浏览器的）或 `http://${NAPBOX_API_3100}`（`127.0.0.1` 的），起服务时换成这个环境分到的地址。只能用在这两处，引用的要是这个 compose 里启用的服务在 `ports` 里写的端口（`NAPBOX_HOSTNAME` 也行）；不要让启动脚本先 up 一次取端口再 up 一次。
- **项目自己在本机跑的程序要监听端口**（开发时在本机跑的后台和网页，不在 compose 里；页面测试的不算，见上面「网页页面测试」）：不要写死端口，也不要自己按目录算一组。在 compose 顶层写 `x-napbox: {host_ports: [server, web]}`，`up` 返回的变量里（或 `npx napbox env`）有 `NAPBOX_HOST_SERVER`，值是端口号，启动脚本把它交给程序（比如写进 `.env`）。每个 worktree 一组，固定到 `down`。napbox 不占着这些端口，程序自己监听；启动时报端口被占，是别的程序抢先占了，停掉它或者 `down` 后重新 `up` 换一组。名字用小写字母、数字和下划线，不能以 `_数字` 或 `_数字_site` 结尾（要编号写成 `worker2`）。compose 里不能引用 `${NAPBOX_HOST_…}`：环境里访问不到本机。
- **环境里的服务要用本机上的程序**（比如本机 `127.0.0.1` 上的模型反代）：不要让那个程序改成监听 `0.0.0.0`，也不要把本机的登录凭据挂进环境。在 compose 顶层写 `x-napbox: {host_services: [8317]}`（列本机端口号），服务连 `host.docker.internal:8317`（和 Docker Desktop 同名），napboxd 在本机替它连 `127.0.0.1:8317`；本机别的端口、局域网照样连不到。列了的程序这个环境里任何代码都能用，所以只列真要的，先和用户确认；出网模式 `none` 时连它会被拒绝；confine 的环境不能列。端口因人而异时写成变量：`host_services: ["${CODEX_PROXY_PORT:-8317}"]`。程序要的密钥按下一条放。
- **服务要用密钥**（API key、令牌这类不进 git 的值）：不写进 compose，也不靠调用方的环境变量（用工具 `up`、自动唤醒时带不进去）。服务用 `env_file: [{path: ./本地文件.env, required: false}]` 读一个不进 git 的文件，缺了照样能起。改了里面的值要再调一次 `up`。新 worktree 里的这份文件由开 worktree 的工具带过去（比如 Claude Code 的 `.worktreeinclude`），不要写在启动脚本里拷。
- **compose 文件不在默认位置**：给 `up` 传 `files`，或者在 worktree 根目录写 `.napbox.yaml`，内容是 `compose: server/compose.yaml`。
- **改了 compose**：再调一次 `up`，会按新定义重建。
- **改了 Dockerfile 或打进镜像的文件**：给 `up` 传 `build: true`，和 `docker compose up --build` 一样。不传时只在镜像还没有时构建。新起的临时环境 `up` 时会自己构建，不用另外先构建一遍：构建出的镜像只归这个环境，`down` 时一起删。源码挂载进容器的文件不用重新构建。
- **compose 写了 `develop.watch`**：`up` 后就生效，不用 `docker compose watch`。改文件自动同步、重建、重启，休眠期间改的唤醒时补上。觉得没同步时看 `status` 的 `watchError`。
- **`image_build_failed`**：错误信息里有构建输出的最后几十行和完整日志的路径。修好 Dockerfile 后传 `build: true` 再调 `up`。失败不影响已经在跑的环境。
- **服务启动前要先建库、建角色、跑迁移**：写成一次性服务（`restart: "no"`，做完就退出），后端用 `depends_on` 的 `condition: service_completed_successfully` 等它跑完。不要让后端连不上就退出、靠 `restart` 重试：napbox 里一个服务按 `restart` 重启，整个环境连数据库一起重启，会一直重来。数据库的 `healthcheck` 要走 TCP（比如 `pg_isready -h 127.0.0.1`），postgres 第一次初始化时只开本地 socket 的临时服务也会让 socket 检查通过。
- **要清空数据**：`reset` 只清指定的数据卷，旧数据保留 7 天。
- **分支要主目录的真实数据**（账号、附件，新库只有表登录不了）：不要自己 pg_dump、逐表复制。在 compose 顶层写 `x-napbox: {seed: [pgdata, s3data]}`（列要带过去的命名卷），新 worktree 第一次 `up` 时自动从主目录环境的快照复制这些卷，迁移这类一次性服务在复制来的数据上重跑，`up` 的结果里 `seededFrom` 写着数据是哪个环境、什么时候的。快照是主目录环境正常停下（闲置休眠、`sleep`）时拍的，复制不碰正在运行的主目录，拿到的是它上次停下时的数据。已有环境要换成主目录现在的快照：`reset` 给这些卷、`from` 给主目录的路径。报 `snapshot_not_found` 是主目录还没留下快照：等它闲置休眠；要马上拍就在主目录 `sleep` 一次，但这会断开主目录的连接、结束在跑的命令，先问用户主目录有没有在跑测试。报错或主目录 `status` 的 `snapshotError` 写着上次停下没拍成的原因时，先处理它再 `sleep`：常见的是某个服务过了 `stop_grace_period`（没写是 10 秒）还没退出、被强制结束——先查它为什么停得慢（日志里停下那段），能关掉的等待（比如单机用不上的集群下线等待）先关掉，剩下的才给它设更长的 `stop_grace_period`。
- **测试要一套用完就扔的服务**（比如一个空的数据库，以前会用 `docker run` 起）：给 `up` 传 `temp`（自己起个名字）。它在开发环境之外另起一个临时环境，返回它自己的端口；`env`、`logs`、`exec`、`egress` 传同一个 `temp` 就是操作它。用完调 `down` 传同一个 `temp`，数据直接删掉。临时环境不休眠，闲置了自己销毁，也没有 `sleep`、`reset`。
- **要单独跑一次某个服务**（测试、检查，以前会用 `docker compose run`）：用 `run` 工具。它临时起一个环境、在前台跑这个服务、跑完销毁，返回退出码和输出。
- **把这两件事写进项目的脚本**：对应的命令行是 `npx napbox up --temp <名字>`、`npx napbox down --temp <名字>` 和 `npx napbox run <服务> [-- 命令]`，`run` 的退出码和那个服务一样。
- **服务的内存**：compose 没写 `mem_limit` 的服务不单独封顶，和环境里其他没写的服务共用整个环境的内存，不用为了「默认偏紧」去加 `mem_limit`。服务卡在内存上时（到了自己的 `mem_limit`，或整个环境用完），napbox 十几秒内结束占内存最多的那个进程，服务的日志（`logs`）里有一行 `napbox：……卡住了……结束了……`，写着是哪个进程、上限多少、怎么调；测试里看到浏览器崩溃、连接断开、退出码 137 时先看这一行。
- **工具报 `daemon_unavailable`**：调用 `setup`。它会下载约 700MB 的内核包并注册登录项，要先让用户知道。
- **`compose_unsupported`**：compose 用了 napbox 不支持的写法，错误信息里有说明。项目原有的 compose 不要改，把情况告诉用户。
- **`path_outside_directory`**：这个环境是带 confine 建的（`status` 里 `confined: true`，通常是 CodeOS 这类程序在项目副本上建的），compose 里挂载、读取的宿主机路径解开符号链接后都要在代码目录以内。错误信息写着哪个服务、哪个字段、哪个路径越界了；把它改成目录里的路径（或者去掉），不要用符号链接绕：之后每次起环境都会再查。

## 限制

- 不能单独重启一个服务，`restart` 规则和 `up` 都是整个环境一起重启。
- `exec` 不支持交互，要在容器里切目录或设变量就用 `["sh", "-c", "..."]`。
- 构建镜像时拿不到本机 Docker 的登录信息和本地镜像：Dockerfile 的 `FROM` 要是公开仓库能拉到的镜像。
- 只支持 Apple 芯片的 Mac。
