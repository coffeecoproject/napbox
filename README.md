# napbox

[中文](README.zh-CN.md)

Local dev environments for coding agents on Apple silicon Macs, without Docker.

napbox reads a project's compose file and gives every git worktree its own isolated set of services (databases, object storage, backends). Host ports are assigned by napbox and stay fixed for that environment. Idle environments go to sleep and wake up on the next connection. Agents drive it through MCP tools; scripts use the `napbox` command.

It is built on Apple's open-source [Containerization](https://github.com/apple/containerization) framework: one lightweight Linux VM per environment, with all its services in it.

**Status: 0.1.2, early.** Used daily on one machine for several projects (PostgreSQL with PostGIS, Redis, MinIO, Go and Node backends, nginx front ends). Expect rough edges.

## Requirements

- macOS 26 or later, Apple silicon
- Node.js 22.22 or later
- Claude Code, for the plugin (the `napbox` command works without it)

## Install

In Claude Code:

```
/plugin marketplace add coffeecoproject/napbox
/plugin install napbox@napbox
```

The first time an agent needs services, napbox reports that it is not set up and the agent calls the `setup` tool (Claude Code asks you first). Setup:

- downloads the Kata Containers kernel package from GitHub (about 700 MB, checked against a fixed checksum) and runc (about 10 MB), and pulls the vminit image from ghcr.io;
- asks macOS to install Rosetta if it is missing (for x86 programs inside the VM);
- copies `napboxd` to `~/Library/Application Support/napbox/` and registers it as a login item (`~/Library/LaunchAgents/io.github.coffeecoproject.napbox.plist`).

Without Claude Code: `npx napbox setup`.

## How it works

- **One environment per worktree.** Environments are named `<project>/<worktree>` (the main checkout is `<project>/main`). Two worktrees of the same project run side by side without port clashes.
- **Ports.** In compose, write only the container port (`- "5432"`). napbox assigns a host port on `127.0.0.1` and keeps it for the environment across sleep, wake, `up` again, napboxd restarts and profile changes. It is released only on `down`. Other worktrees and temporary environments get other ports, so read them from `napbox env` instead of hard-coding them. When a service needs its own address on the host (for example to build links a browser opens), write `${NAPBOX_API_3100}` in `environment` or `env_file`; napbox replaces it with the address this environment was given (`127.0.0.1:41217`) when the service starts.
- **Sleep.** After 30 minutes without connections an environment sleeps and its memory goes back to macOS. The next connection to one of its ports wakes it; that connection waits only until the service it connects to (and the services that one depends on) is ready, usually about a second for a database, while the rest of the environment keeps starting. Services start one by one in dependency order, so a service later in that order also waits for the ones before it to start. If any of those services has a `develop.watch` sync rule, the connection waits for the whole environment, so files changed while it slept are already synced.
- **Temporary environments.** `napbox up --temp <name>` starts a throwaway environment next to the dev one (an empty test database, for example), and `napbox down --temp <name>` deletes it. `napbox run <service>` starts a one-off environment, runs one service in the foreground and returns its exit code.
- **Builds.** `build:` is built inside a dedicated VM with BuildKit; the build cache is shared by all environments.
- **Network.** Environments cannot reach the host or the local network. `napbox egress none` also cuts off the internet, leaving only the services in the same environment.

## Commands

All commands print JSON (`napbox status --text` prints a table).

| Command | What it does |
|---|---|
| `napbox up [-f compose] [--build] [--profile P]` | Create or wake the environment, wait until healthy, print ports and variables |
| `napbox env` | Print `export NAPBOX_<SERVICE>_<PORT>=127.0.0.1:<port>` lines, ready for `eval "$(napbox env)"` |
| `napbox status [--text]` | State and ports of napboxd and the environments |
| `napbox logs <service> [--tail N] [-f]` | Service logs, without waking the environment |
| `napbox exec <service> -- <command>` | Run a command in a service (not interactive) |
| `napbox run <service> [-- <command>]` | Run one service once in a throwaway environment |
| `napbox reset <volume>` | Empty a named volume (the old data is kept for 7 days) |
| `napbox sleep` / `napbox down` | Sleep now / remove the environment (data kept for 7 days) |
| `napbox egress <open\|none>` | Switch network access |

`--temp <name>` works with `up`, `env`, `logs`, `exec`, `egress` and `down`.

## Compose support

napbox supports what local dev compose files commonly use, and rejects everything else with an error that says what and why, instead of ignoring it.

Supported: `image`, `build` (`context`, `dockerfile`, `target`, `args`), `command`, `entrypoint`, `environment`, `env_file`, `working_dir`, `init`, `shm_size`, `tmpfs`, `pull_policy`, `stop_grace_period`, `ports` (container port only), `expose`, `volumes` (named volumes, directories and single files), `depends_on` with conditions, `healthcheck`, `restart`, `profiles`, `develop.watch`, `secrets` (file form), memory limits, the default network, variable substitution, multiple compose files and YAML merge keys.

Not supported, among others: `read_only`, `cpus`, `pids_limit`, `security_opt`, `platform`, `privileged`, `cap_add: NET_ADMIN`, `network_mode`, `configs`, the `!reset` and `!override` YAML tags, and `build` options beyond the four above.

## Differences from Docker

- A single service cannot be restarted on its own. When a service restarts under its `restart` policy, the whole environment restarts. Put setup work (create databases, run migrations) in one-shot services that the backend waits for with `condition: service_completed_successfully`.
- Environments cannot reach each other. Services inside one environment can, by service name.
- Several networks are merged into one: all services of an environment can reach each other, and `internal: true` on a network has no effect. To cut off the internet, use `napbox egress none` for the whole environment.
- `napbox run` gives the service its host ports, unlike `docker compose run`.
- `exec` has no interactive terminal.
- Builds cannot use your Docker login or local Docker images: `FROM` must be pullable from a public registry.
- napbox does not export images. Package release images with another tool, such as Apple's `container`.
- Memory is returned to macOS only when an environment sleeps.

## License

[Apache License 2.0](LICENSE). The npm package bundles third-party code; see [NOTICE](NOTICE).
