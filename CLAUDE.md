# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker image for a **Counter-Strike 1.6 dedicated server running on the ReHLDS
engine stack** (ReHLDS, ReGameDLL_CS, Metamod-R, AMX Mod X, ReAPI, YaPB bots,
optional Reunion). ReHLDS replaces the unmaintained stock GoldSrc HLDS engine:
it is actively maintained, substantially faster, and adds engine-level
flood-rate limiting that stock HLDS lacks.

## Commands

```bash
docker compose build                 # build the image (tags rehlds-csserver:local)
docker compose build --no-cache      # clean build — re-runs SteamCMD + all downloads
docker compose up -d --build         # build + run
docker compose up -d                 # run / recreate with new .env values (no rebuild)
docker compose logs -f csserver      # live HLDS console
docker compose exec csserver rcon "<cmd>"            # RCON (e.g. "meta list", "amx_version")
docker compose exec csserver /opt/cs16/healthcheck.sh  # A2S probe -> HEALTHY / UNHEALTHY
```

Build with `GPG_VERIFY=false` (in `docker-compose.yml` build args, or
`docker build --build-arg GPG_VERIFY=false`) only when GitHub is unreachable at
build time — SHA256 verification still runs.

Reset to a clean state: `docker compose down`, delete the server's volume dir
(`./serverdata/default` for the single server, `./serverdata/<name>` for a fleet
member), `docker compose up -d` — the next start re-seeds the volume.

**There is no test framework, linter, or build system beyond Docker.**
`TESTING.md` is a manual, numbered verification plan (clean build → first start →
stack loaded → master-server visibility → persistence → bot toggle). To "run a
single test", follow that section's commands by hand.

## Architecture

### The ReHLDS stack is applied at BUILD time, not runtime

This is the central design decision. The running container has **no SteamCMD and
no update machinery** — nothing can ever clobber the engine.

- **Base image:** `cm2network/steamcmd`, pinned by digest (`BASE_DIGEST`).
- **Stage 1 `server-builder`** runs `scripts/build-server.sh`:
  1. Installs CS 1.6 (HLDS appid 90, **`steam_legacy` branch**) via SteamCMD,
     looping until the install size stabilises and sentinel files exist
     (appid-90 downloads are incrementally flaky).
  2. Downloads every ReHLDS-stack release asset, verifies it (SHA256 for all,
     GPG for ReHLDS), and applies it onto the serverfiles at `/build/serverfiles`.
- **Stage 2 `runtime`** bakes `/build/serverfiles` in as the immutable reference
  copy `/opt/cs16/serverfiles-base`.

`steam_legacy` is mandatory: the post-25th-anniversary HLDS dropped the
`SteamGameServer_Init` symbol ReHLDS imports — the engine fails to load without
it.

### Reproducible builds

Every component version is a Dockerfile `ARG` paired with a `*_SHA256` ARG;
ReHLDS is additionally GPG-verified against a vendored key. Floating tags
(`latest`, `master`) are never used. **To upgrade a component:** bump its
`*_VERSION` and `*_SHA256` ARGs in `Dockerfile`, then rebuild. `CHANGELOG.md`
records the pinned set.

### Runtime: seed + render, then run

`scripts/entrypoint.sh` starts as root and:
1. **Seeds** the `/server` volume from `serverfiles-base` on first run only
   (an existing volume is kept — operator edits and state persist).
2. **Renders env-driven config on every start** — `server.cfg` (template + a
   generated env-override block appended last so it wins), Metamod `plugins.ini`
   (toggles the YaPB / Reunion lines per `BOTS_ENABLED` / `REUNION_ENABLED`),
   `reunion.cfg` (only when Reunion is enabled), and the AMX Mod X
   `users.ini` (rewrites a container-managed `OWNER` admin block — see below).
3. Fixes ownership and `exec`s HLDS, dropping to the unprivileged `steam` user
   via `gosu`. HLDS becomes the container's main process (clean SIGTERM).

### The two-layer config model

`config/` holds the **curated source files** — the only server config tracked in
the repo. `serverdata/` is the **runtime volume**: the live, mutable
server install, seeded from the image's baked-in copy on first run, and
gitignored. Editing a file under `serverdata/` changes only the running server —
the repo's source of truth is `config/` plus the build.

#### Scope × authority — the rule that keeps it legible

Every config value has one **scope** (shared across all servers, or per-server)
and one **authority** (where it is set). **One authority per value** — never make
the same value both env-tracked and operator-seeded, or it becomes ambiguous which
one wins.

| | Baked (build) | Env-rendered (every start) | Volume-seeded (once) |
|---|---|---|---|
| **Shared** | gameplay defaults, rates, flood / RCON / ReHLDS hardening (`config/server.cfg`); YaPB perf cvars (patched into `yapb.cfg`) | — | — |
| **Per-server** | — | identity, ports, passwords, `SV_*`, gates (`BOTS_ENABLED` / `REUNION_ENABLED`), `OWNER` | `server-custom.cfg`, YaPB bot tuning (live `yapb.cfg`), hand-added admins, `amxx.cfg`, reunion salt |

The two axes map onto the file table below: **authority** is the "Kind" column,
and the **env-rendered** column is what `.env` drives. Multi-server simply
instantiates the **per-server** column N times against the one shared image.

Config files fall into three categories — know which before editing:

| File | Kind | Editing rule |
|---|---|---|
| `config/server.cfg`, `plugins.ini`, `reunion.cfg` | **Templates** — copied to `/opt/cs16/templates/`, rendered every start | Edit the `config/` template. The live `cstrike/` copy is overwritten. |
| `cstrike/addons/yapb/conf/yapb.cfg` | **Vendored + build-patched** — ships inside the YaPB archive; `build-server.sh` rewrites our perf-cvar *values* in place at build time, then it is seeded into the volume on first run | For a baked perf default, edit the `yapb_set` lines in `build-server.sh` and rebuild. For bot tuning (quota/difficulty), edit the live `cstrike/` copy directly — never overwritten after seeding. |
| `cstrike/addons/amxmodx/configs/amxx.cfg` | **Stock, seeded** — ships inside the AMX Mod X archive; the build leaves it untouched and the entrypoint seeds it into the volume on first run | Edit the live `cstrike/` copy directly to tune AMX Mod X. Not tracked in the repo; never overwritten. |
| `cstrike/server-custom.cfg` | **Operator escape hatch** — seeded empty by the entrypoint, `exec`'d last (`server.cfg` `exec`s it) | Operator's own server cvars. Never overwritten. |
| `cstrike/addons/amxmodx/configs/users.ini` | **Managed block** — vendored AMXX file; the entrypoint rewrites only an `OWNER`-marked block each start | Set `OWNER` in `.env` for the owner admin. Add other admins by hand in the live file, outside the managed block (they persist). |

Runtime values (hostname, RCON, ports, Reunion, owner admin, and the
`BOTS_ENABLED` bot gate) are all driven by `.env` (`.env.example` is the
documented template) — no rebuild needed to change them. Bot *tuning* (quota,
difficulty) is the one exception: it is not in `.env` at all — it stays at YaPB's
stock defaults, tuned by editing the live `yapb.cfg` — see
[YaPB bot config](#yapb-bot-config) below.

The `OWNER` env var holds the server owner's SteamID. When set, the entrypoint
bootstraps it into `users.ini` as a full AMX Mod X admin (flags
`abcdefghijklmnopqrstu` — all commands + immunity, account flags `ce` =
SteamID auth, no password). It rewrites only the block between its
`; >>> OWNER admin` / `; <<< OWNER admin` markers, so hand-added admins
elsewhere in the file survive. YaPB has no SteamID admin model, so `OWNER`
does not touch it.

### Multi-server topology — one image, N services

This is **one image, many servers**, not one-repo-one-server. The image is built
once and is identical everywhere; all per-server difference is exactly two things —
an **env file** and a **`./serverdata/<name>` volume**. Adding a server costs one
env file plus a small service block, never a copied repo.

The split is strict:

- **Compose files hold topology only** — service name, `container_name`, the
  `./serverdata/<name>:/server` volume, and `image:`. They carry **no `${...}`
  interpolation**; `docker-compose.yml` (single) and `docker-compose.fleet.example.yml`
  share one anchor shape (`x-csserver: &csserver`, merged with `<<: *csserver`).
- **Env files hold runtime config only** — everything the entrypoint reads
  (identity, ports, passwords, `SV_*`, `OWNER`, the `BOTS_ENABLED` / `REUNION_ENABLED`
  gates). Injected via `env_file:`, applied at start, no rebuild.

The single server lives at `./serverdata/default` with `.env`; the fleet example
defines `cstrike-01` / `cstrike-02`, each with its own `cstrike-NN.env` and
`./serverdata/cstrike-NN` volume. `build:` lives only on the single-server service,
so the fleet reuses the one built image — build once (`docker compose build`), run N.
With more than one server, `docker compose exec` / `logs` take the **service name**
(and the fleet needs `-f docker-compose.fleet.example.yml`).

### YaPB bot config

`yapb.cfg` is **vendored** — it ships inside the YaPB release archive and is
replaced wholesale on every YaPB version bump. Two distinct concerns touch it,
split by authority:

- **Our performance/behaviour defaults (shared, baked).** `build-server.sh`
  rewrites a handful of cvar *values* in place in the stock `yapb.cfg` at build
  time (`yb_think_fps`, `yb_path_floyd_memory_limit`, `yb_path_astar_post_smooth`,
  `yb_graph_analyze_fps`) — the same in-place-patch approach used for
  `liblist.gam` / `modules.ini`. Because the values live *in* `yapb.cfg` (which
  YaPB re-execs every changelevel) they survive map changes with no runtime
  overlay, and because the patch re-runs every build it never "vanishes" on a
  version bump. The patch asserts each target cvar exists and **fails the build**
  if upstream renames one. To change a baked default, edit the `yapb_set` lines
  in `build-server.sh` and rebuild.
- **Bot tuning (per-server, operator-owned).** Bot count, mode and difficulty
  (`yb_quota` / `yb_quota_mode` / `yb_difficulty` / `yb_autovacate`) are left at
  YaPB's **stock defaults** (`9` / `normal` / `3` / `1`). The build does not
  touch them. Tune them by editing the live `cstrike/addons/yapb/conf/yapb.cfg`
  in the volume — the standard YaPB way, same model as `amxx.cfg`. YaPB re-execs
  `yapb.cfg` each changelevel, so an edit there applies on the next map with no
  restart (and, unlike `server.cfg`/`server-custom.cfg` cvars, is *not* clobbered
  by that re-exec).

The environment's only bot setting is `BOTS_ENABLED`, which just gates whether
YaPB loads at all (it toggles the `yapb.so` line in the rendered `plugins.ini`);
when `false`, the plugin never loads and none of `yapb.cfg` runs. Bot tuning is
therefore *not* in the `server.cfg` env block.

## Gotchas

- `scripts/clear-execstack.py` clears the executable-stack ELF flag on GoldSrc
  `.so` files — Debian 13+ loaders reject exec-stack binaries. It runs in
  `build-server.sh`; required, do not remove.
- `build-server.sh` also patches `liblist.gam` (`gamedll_linux` → Metamod),
  appends `reapi` to `modules.ini`, and rewrites the YaPB perf-cvar values in
  `yapb.cfg`. These are all build-time mutations of SteamCMD/archive output.
- Networking is `network_mode: host` (reliable GoldSrc master-server
  registration). Each server needs an inbound port-forward for its own
  **UDP `SERVER_PORT`** (default 27015); co-resident fleet servers must therefore
  use distinct `SERVER_PORT` / `CLIENT_PORT`. Whether multiple instances contend
  on the VAC/Steam port (UDP 26900) under host networking is unverified — see the
  open note in `docker-compose.fleet.example.yml`.
