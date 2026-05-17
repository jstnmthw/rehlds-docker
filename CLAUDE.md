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

Reset to a clean state: `docker compose down`, delete `DATA_DIR` (`./serverdata`),
`docker compose up -d` — the next start re-seeds the volume.

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
the repo. `serverdata/` is the **runtime volume** (`DATA_DIR`): the live, mutable
server install, seeded from the image's baked-in copy on first run, and
gitignored. Editing a file under `serverdata/` changes only the running server —
the repo's source of truth is `config/` plus the build.

Config files fall into three categories — know which before editing:

| File | Kind | Editing rule |
|---|---|---|
| `config/server.cfg`, `plugins.ini`, `reunion.cfg` | **Templates** — copied to `/opt/cs16/templates/`, rendered every start | Edit the `config/` template. The live `cstrike/` copy is overwritten. |
| `config/amxx.cfg`, `config/yapb-overlay.cfg` | **Curated, baked** — `build-server.sh` copies them into the serverfiles at build time | Edit the `config/` source; rebuild to bake. Seeded once into the volume, then never overwritten. |
| `cstrike/server-custom.cfg`, `cstrike/addons/amxmodx/configs/amxx-custom.cfg` | **Operator escape hatches** — seeded empty by the entrypoint, `exec`'d last (`server.cfg` and `amxx.cfg` respectively `exec` them) | Operator's own cvars (server / AMX Mod X). Never overwritten. |
| `cstrike/addons/amxmodx/configs/users.ini` | **Managed block** — vendored AMXX file; the entrypoint rewrites only an `OWNER`-marked block each start | Set `OWNER` in `.env` for the owner admin. Add other admins by hand in the live file, outside the managed block (they persist). |

Runtime values (hostname, RCON, ports, bot quota/difficulty, Reunion, owner
admin) are all driven by `.env` (`.env.example` is the documented template) — no
rebuild needed to change them.

The `OWNER` env var holds the server owner's SteamID. When set, the entrypoint
bootstraps it into `users.ini` as a full AMX Mod X admin (flags
`abcdefghijklmnopqrstu` — all commands + immunity, account flags `ce` =
SteamID auth, no password). It rewrites only the block between its
`; >>> OWNER admin` / `; <<< OWNER admin` markers, so hand-added admins
elsewhere in the file survive. YaPB has no SteamID admin model, so `OWNER`
does not touch it.

### YaPB bot config

`yapb.cfg` is **vendored** — it ships inside the YaPB release archive and is
replaced wholesale on every YaPB version bump. So bot tuning must NOT be edited
into `yapb.cfg` directly (it would silently vanish on rebuild). Instead:
- Tuning lives in `config/yapb-overlay.cfg`.
- `build-server.sh` appends `exec addons/yapb/conf/yapb-overlay.cfg` to the
  stock `yapb.cfg`.
- YaPB re-execs `yapb.cfg` on every changelevel, so the overlay re-applies after
  the stock defaults each map — its values always win and survive map changes.

## Gotchas

- `scripts/clear-execstack.py` clears the executable-stack ELF flag on GoldSrc
  `.so` files — Debian 13+ loaders reject exec-stack binaries. It runs in
  `build-server.sh`; required, do not remove.
- `build-server.sh` also patches `liblist.gam` (`gamedll_linux` → Metamod) and
  appends `reapi` to `modules.ini`. These are build-time mutations of
  SteamCMD/archive output, alongside the YaPB overlay hook.
- Networking is `network_mode: host` (reliable GoldSrc master-server
  registration). Only **UDP 27015** needs an inbound port-forward.
