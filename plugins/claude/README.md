# napbox

给 coding agent 用的 Mac 本地开发环境：按项目的 compose 文件给每个 worktree 起一套隔离的服务，端口不冲突，闲置自动休眠，连接时自动唤醒，不依赖 Docker。

## 安装

```
/plugin marketplace add coffeecoproject/napbox
/plugin install napbox@napbox
```

## 第一次使用

让 agent 启动项目的服务就行。它发现 napbox 还没准备好时会调用 `setup` 工具，你同意后它会：

- 从 GitHub 下载约 700MB 的 Kata 内核包，校验后取出内核；从 ghcr.io 拉取 vminit 镜像；
- 把后台程序 `napboxd` 放到 `~/Library/Application Support/napbox/`，注册成登录项（`~/Library/LaunchAgents/io.github.coffeecoproject.napbox.plist`）。

## 这个插件运行什么

- **MCP 工具**：`up`、`run`、`env`、`status`、`logs`、`exec`、`reset`、`sleep`、`down`、`egress`、`setup`。
- **钩子**：会话开始和压缩上下文后，当前 worktree 有环境就告诉 agent 端口；已接入的项目（有环境记录或 `.napbox.yaml`）拦下 `docker compose up`、`start`、`run`；运行 `docker run` 或者自己在本机起数据库时只提醒一句，不拦。别的 `docker` 命令和没接入的项目不受影响。
- 第一次启动某个版本时，npm 把固定版本的 `napbox` 包装进 `~/Library/Caches/napbox/`。

## 要求

macOS 26 或更新版本，Apple 芯片，Node.js 22.22 或更新版本。
