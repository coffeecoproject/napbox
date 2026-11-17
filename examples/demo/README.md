# napbox demo

[中文](README.zh-CN.md)

A small project to try napbox with: PostgreSQL, Redis, a one-shot migration service and a Node backend that shows a list of notes. It walks through two worktrees running side by side, a new worktree starting with main's data, and sleep/wake.

You need napbox set up first (see the [main README](../../README.md#install)). Every command below also works without a global install as `npx napbox …`.

## 1. Make it its own repository

napbox tells environments apart by git worktree, so copy the demo out of a clone of the napbox repository (`git clone https://github.com/coffeecoproject/napbox`) and run this from the clone's root:

```bash
cp -R examples/demo ~/napbox-demo
cd ~/napbox-demo && git init -q && git add . && git commit -qm init
```

## 2. Start main

```bash
napbox up
```

The first run pulls the images and builds `api`. When it returns, every service is ready and the output lists the host ports napbox picked, for example `NAPBOX_API_3000=127.0.0.1:41558`. Open the page and add a note:

```bash
eval "$(napbox env)" && open http://$NAPBOX_API_3000
```

## 3. Snapshot main's data

`compose.yaml` declares `x-napbox: {seed: [pgdata]}`. napbox snapshots that volume (an APFS clone) every time the environment stops cleanly. Make it stop now instead of waiting 30 idle minutes:

```bash
napbox sleep
```

## 4. A second worktree, with main's data

```bash
git worktree add ../napbox-demo-feature
cd ../napbox-demo-feature && napbox up
```

The output has different ports and `seededFrom` naming `napbox-demo/main`. Open its page: the note you wrote on main is there. Notes you add here stay here, and main doesn't see them.

```bash
eval "$(napbox env)" && open http://$NAPBOX_API_3000
napbox status --text
```

## 5. Sleep and wake

```bash
napbox sleep
time curl -s http://$NAPBOX_API_3000/ -o /dev/null
```

While it sleeps, the VM is stopped and its memory is back with macOS, but the port stays open. The `curl` wakes the environment and waits until `api` (and what it depends on) is ready, which usually takes about a second. Without `napbox sleep`, the same happens after 30 idle minutes.

## Clean up

```bash
napbox down && cd ../napbox-demo && napbox down
git worktree remove ../napbox-demo-feature
```

`down` frees the ports and keeps the data for 7 days before deleting it.

## What's in it

| File | |
|---|---|
| `compose.yaml` | Container ports only; the migration as a one-shot service that `api` waits for; `init: true` on `api` so it stops on SIGTERM (otherwise it is killed after `stop_grace_period` and no snapshot is taken); `PUBLIC_ADDRESS: ${NAPBOX_API_3000}` so the page can show its own host address |
| `migrate.sql` | Creates the `notes` table |
| `api/` | About 50 lines of Node: notes in PostgreSQL, a visit counter in Redis |
