# napbox 演示项目

[English](README.md)

一个用来试 napbox 的小项目：PostgreSQL、Redis、一次性的迁移服务和一个显示笔记列表的 Node 后端。按下面走一遍：两个 worktree 同时运行、新 worktree 带着主目录的数据起来、休眠和唤醒。

先装好 napbox（见[主 README](../../README.zh-CN.md#安装)）。下面的命令没全局安装时都可以写成 `npx napbox …`。

## 1. 拷成单独的仓库

napbox 按 git worktree 区分环境，所以要把演示项目从 napbox 仓库里拷出来。先 `git clone https://github.com/coffeecoproject/napbox`，在克隆下来的仓库根目录执行：

```bash
cp -R examples/demo ~/napbox-demo
cd ~/napbox-demo && git init -q && git add . && git commit -qm init
```

## 2. 起主目录的环境

```bash
napbox up
```

第一次要拉镜像、构建 `api`。返回时服务都已就绪，输出里有 napbox 分的宿主机端口，比如 `NAPBOX_API_3000=127.0.0.1:41558`。打开页面加一条笔记：

```bash
eval "$(napbox env)" && open http://$NAPBOX_API_3000
```

## 3. 给主目录的数据拍快照

`compose.yaml` 里写了 `x-napbox: {seed: [pgdata]}`，环境每次正常停下，napbox 都用 APFS 克隆给这个卷留一份快照。不等闲置 30 分钟，现在就让它停下：

```bash
napbox sleep
```

## 4. 第二个 worktree，带着主目录的数据

```bash
git worktree add ../napbox-demo-feature
cd ../napbox-demo-feature && napbox up
```

输出里是另一组端口，`seededFrom` 写着 `napbox-demo/main`。打开它的页面，主目录写的笔记在这里；在这里加的笔记只在这里，主目录看不到。

```bash
eval "$(napbox env)" && open http://$NAPBOX_API_3000
napbox status --text
```

## 5. 休眠和唤醒

```bash
napbox sleep
time curl -s http://$NAPBOX_API_3000/ -o /dev/null
```

休眠时虚拟机停了、内存还给 macOS，但端口一直开着。`curl` 一连就唤醒环境，等到 `api`（和它依赖的服务）就绪才接上，一般约 1 秒。不手动 `sleep` 的话，闲置 30 分钟也会这样。

## 收尾

```bash
napbox down && cd ../napbox-demo && napbox down
git worktree remove ../napbox-demo-feature
```

`down` 释放端口，数据保留 7 天后删除。

## 里面有什么

| 文件 | |
|---|---|
| `compose.yaml` | 只写容器端口；迁移写成一次性服务，`api` 等它跑完；`api` 写了 `init: true`，收到 SIGTERM 会退出（不然要等满 `stop_grace_period` 被强制结束，快照就拍不成）；`PUBLIC_ADDRESS: ${NAPBOX_API_3000}` 让页面显示自己在宿主机上的地址 |
| `migrate.sql` | 建 `notes` 表 |
| `api/` | 约 50 行 Node：笔记存 PostgreSQL，访问次数记在 Redis |
