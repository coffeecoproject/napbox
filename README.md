# napbox

[中文](README.zh-CN.md)

Local dev environments for coding agents on Apple silicon Macs, without Docker.

napbox reads a project's compose file and gives every git worktree its own isolated set of services (databases, object storage, backends). Host ports are assigned by napbox and stay fixed for that environment. Idle environments go to sleep and wake up on the next connection. Agents drive it through MCP tools; scripts use the `napbox` command.

It is built on Apple's open-source [Containerization](https://github.com/apple/containerization) framework: one lightweight Linux VM per environment, with all its services in it.

**Status: 0.1.11, early.** Used daily on one machine for several projects (PostgreSQL with PostGIS, Redis, MinIO, Go and Node backends, nginx front ends). Expect rough edges.

## Why

Run a few coding agents in parallel, each in its own worktree, with Docker compose, and you hit three things:

- **Port clashes.** compose files hardcode host ports, so the second worktree's `up` fails on 5432. If they share one database instead, one agent's migration breaks another's data.
- **Memory that never comes back.** While any container is running, the Docker Desktop VM keeps all the memory you gave it, and agents rarely stop what they started.
- **Agents fumbling with Docker.** They assemble `docker compose` commands, guess ports and leave containers behind.

With napbox, each worktree gets its own services from the same compose file, on ports that never clash and stay fixed until you `down` it. Idle environments sleep and give their memory back; the next connection wakes them, and a database is usually ready in about a second. A new worktree can start with a copy of main's data. Agents use MCP tools and get JSON back.

To see it in a couple of minutes, try the [demo project](examples/demo).

## Requirements

- macOS 26 or later, Apple silicon
- Node.js 22.22 or later
- Claude Code for the plugin, or Codex for the MCP tools (the `napbox` command works without either)

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

In Codex:

```
npx napbox setup codex
```

This runs the same setup and adds napbox's MCP tools to Codex (with `codex mcp add`). Codex gets the tools only: the skill and the hooks (telling the agent its ports when a session starts, stopping `docker compose up`) are part of the Claude Code plugin.

Without an agent: `npx napbox setup`.

## How it works

- **One environment per worktree.** Environments are named `<project>/<worktree>` (the main checkout is `<project>/main`). Two worktrees of the same project run side by side without port clashes.
- **Ports.** In compose, write only the container port (`- "5432"`). napbox assigns a host port on `127.0.0.1` and keeps it for the environment across sleep, wake, `up` again, napboxd restarts and profile changes. It is released only on `down`. Other worktrees and temporary environments get other ports, so read them from `napbox env` instead of hard-coding them. When a service needs its own address on the host (for example to build links a browser opens), write `${NAPBOX_API_3100}` in `environment` or `env_file`; napbox replaces it with the address this environment was given (`127.0.0.1:41217`) when the service starts.
- **A hostname for the browser.** Each environment also gets a hostname such as `feat-x--crocwork.localhost`, which resolves to the Mac with no setup. Browsers keep cookies per hostname, not per port, so use it for page addresses: with several worktrees open in one browser, signing in to one does not sign you out of another. Every port has `NAPBOX_API_3100_SITE=feat-x--crocwork.localhost:41217`, and the hostname alone is `NAPBOX_HOSTNAME`; compose can reference them too (`PUBLIC_ORIGIN: http://${NAPBOX_API_3100_SITE}`). Programs still connect to services on `127.0.0.1`. napbox holds each port on both `127.0.0.1` and `[::1]`.
- **Ports for processes on the Mac.** When the project's own programs that run on the Mac (a dev backend, the backend and web pages that end-to-end tests start) also need their own ports per worktree, add `x-napbox: {host_ports: [server, web]}` at the top level of compose. Each name gets one port, exposed as `NAPBOX_HOST_SERVER=41230` (just the port number), and it stays fixed until `down` like service ports. napbox does not hold these ports; the project's programs listen on them. napbox checks a port is free when it assigns it; if another program takes it later, the project's program fails to start with "address in use". Names use lowercase letters, digits and underscores, start with a letter, and must not end in `_<digits>` or `_<digits>_site`.
- **Data from the main checkout.** Add `x-napbox: {seed: [pgdata, s3data]}` at the top level of compose to give a new worktree the main checkout's data (accounts, uploaded files) instead of empty volumes. Each time a worktree's environment stops cleanly (idle sleep, `napbox sleep`, napboxd quitting), napbox keeps an APFS clone of those volumes as its snapshot; the first `up` in a new worktree copies the main checkout's latest snapshot, without stopping or pausing it. It takes milliseconds and no extra disk space until either side writes. If the main checkout has no snapshot yet, `up` fails with `snapshot_not_found` rather than starting with empty volumes. A stop only counts as clean when every service exits within its `stop_grace_period` (10 seconds unless set) and the disk sync succeeds; otherwise no snapshot is taken, and `status` shows why under `snapshotError` (the `snapshot_not_found` message repeats it). For a service that is slow to stop, first check its log for what it waits on (some waits can be turned off); give it a longer `stop_grace_period` only for the time it really needs. One-off services such as migrations run again on the copied data.
- **Sleep.** After 30 minutes without connections an environment sleeps and its memory goes back to macOS. The next connection to one of its ports wakes it; that connection waits only until the service it connects to (and the services that one depends on) is ready, usually about a second for a database, while the rest of the environment keeps starting. Services start one by one in dependency order, so a service later in that order also waits for the ones before it to start. If any of those services has a `develop.watch` sync rule, the connection waits for the whole environment, so files changed while it slept are already synced.
- **Temporary environments.** `napbox up --temp <name>` starts a throwaway environment next to the dev one (an empty test database, for example), and `napbox down --temp <name>` deletes it. Since its data is deleted right away, `down` powers off its VM without waiting for services to shut down. `napbox run <service>` starts a one-off environment, runs one service in the foreground and returns its exit code.
- **Builds.** `build:` is built inside a dedicated VM with BuildKit; the build cache is shared by all environments. The images an environment builds are its own: other environments, temporary ones included, don't use them. `down` deletes them, and the next `up` builds again, reusing the cache for unchanged steps.
- **Network.** Environments cannot reach the host or the local network. `napbox egress none` also cuts off the internet, leaving only the services in the same environment.
- **Programs on the Mac a service needs.** When a service must call a program that listens on the Mac's `127.0.0.1` (a local model proxy, for example), list its port at the top level of compose: `x-napbox: {host_services: [8317]}`. Services reach it at `host.docker.internal:8317`, the same name as in Docker Desktop. napboxd connects to `127.0.0.1:8317` on the Mac for them through the VM's own channel, not the network, so other ports on the Mac and the local network stay unreachable and the program can keep listening on `127.0.0.1` only. Any code in that environment can use the listed program, temporary environments included; in `egress none` connections to it are refused. Environments created with `confine: true` cannot list host services.
- **Environments owned by another program.** A program that runs coding agents on copies of a project (CodeOS, for example) can create environments itself with the TypeScript client: `new NapboxClient().create({ name: "codeos/goal-12", owner: "codeos", directory: "/path/to/copy" })`. Pass `confine: true` when the agent can edit that copy's compose and must not see anything else on the Mac: every host path napbox would read or mount (compose files, `.env`, `.napbox.yaml`, `env_file`, bind mounts, `secrets` files, the build `context` and Dockerfile, `.dockerignore`, `develop.watch` paths) must resolve, following symlinks, to a path inside `directory`, or `create` fails with `path_outside_directory` and nothing starts. napbox records the copy's real path and checks again before every build and start (wake, `reset`, restarts, `develop.watch` rebuilds), so replacing a folder, or the copy directory itself, with a symlink afterwards stops the environment from starting. The VM only gets the copy itself, so a symlink swapped in after the check resolves inside the VM, not on the Mac. The program owning the environment must keep the agent from deleting or recreating the copy directory itself, since a swap timed between the last check and the VM opening the directory cannot be caught. Results carry `confined: true`. The client checks that napboxd is 0.1.7 or newer before sending `confine`, because older versions ignore it and start the environment unrestricted.

## Commands

All commands print JSON (`napbox status --text` prints a table).

| Command | What it does |
|---|---|
| `napbox up [-f compose] [--build] [--profile P]` | Create or wake the environment, wait until healthy, print ports and variables |
| `napbox env` | Print `export NAPBOX_<SERVICE>_<PORT>=127.0.0.1:<port>` lines (plus `_SITE` and `NAPBOX_HOSTNAME` for the browser), ready for `eval "$(napbox env)"` |
| `napbox status [--text]` | State and ports of napboxd and the environments |
| `napbox logs <service> [--tail N] [-f]` | Service logs, without waking the environment |
| `napbox exec <service> -- <command>` | Run a command in a service (not interactive) |
| `napbox run <service> [-- <command>]` | Run one service once in a throwaway environment |
| `napbox reset <volume...> [--from <dir>]` | Empty named volumes, or with `--from` replace them with the latest snapshot of another worktree's environment of the same project (the old data is kept for 7 days) |
| `napbox sleep` / `napbox down` | Sleep now / remove the environment (data kept for 7 days) |
| `napbox egress <open\|none>` | Switch network access |

`--temp <name>` works with `up`, `env`, `logs`, `exec`, `egress` and `down`.

## Compose support

napbox supports what local dev compose files commonly use, and rejects everything else with an error that says what and why, instead of ignoring it.

Supported: `image`, `build` (`context`, `dockerfile`, `target`, `args`), `command`, `entrypoint`, `environment`, `env_file`, `working_dir`, `init`, `shm_size`, `tmpfs`, `pull_policy`, `stop_grace_period`, `ports` (container port only), `expose`, `volumes` (named volumes, directories and single files), `depends_on` with conditions, `healthcheck`, `restart`, `profiles`, `develop.watch`, `secrets` (file form), memory limits (`mem_limit`, `deploy.resources.limits.memory`; as in Docker, a service without one is not capped on its own and shares the whole environment's memory), the default network, variable substitution, multiple compose files and YAML merge keys.

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
- There is no swap in the virtual machine. When a service stalls on memory (at its own limit, or with the whole environment's memory used up), napbox ends the process using the most memory and says why in the service's log, instead of letting it hang.

## Contributing

Bug reports and ideas are welcome as [issues](https://github.com/coffeecoproject/napbox/issues).

Code contributions will require signing a Contributor License Agreement (CLA). You keep the copyright to your contribution; the CLA lets coffeecoproject license it under the project's current license and under other terms in the future, including commercial ones. The CLA is not in place yet, so pull requests are not accepted for now. Please open an issue instead.

## License

[Functional Source License 1.1, ALv2 Future License](LICENSE) (FSL-1.1-ALv2). You can use, modify and redistribute napbox for any purpose, including using it at work on commercial projects, except making it available to others in a commercial product or service that substitutes for napbox or offers substantially similar functionality. Each version also becomes available under the Apache License 2.0 two years after it is released.

Versions 0.1.7 and earlier were released under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) and remain under it.

The npm package bundles third-party code; see [NOTICE](NOTICE).
