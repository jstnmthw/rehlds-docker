# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker image **family** for GoldSrc dedicated servers running on the
**ReHLDS engine stack**: one Dockerfile, a `GAME` build argument, one image per
game — `rehlds-cstrike:local` (Counter-Strike 1.6), `rehlds-tfc:local` (Team
Fortress Classic) and `rehlds-dod:local` (Day of Defeat). Every image carries
ReHLDS, Metamod-R, AMX Mod X (base + the game's add-on), optional Reunion, and
**one fixed bot per game** (YaPB / FoxBot / new_bot) behind the `BOTS_ENABLED`
gate; Counter-Strike additionally gets ReGameDLL_CS and ReAPI. ReHLDS replaces
the unmaintained stock GoldSrc HLDS engine: it is actively maintained,
substantially faster, and adds engine-level flood-rate limiting that stock HLDS
lacks.

## Commands

`docker compose` reads `docker-compose.yml`, which is **gitignored**. Copy a
template into place first — the `docker-compose*.example.yml` templates are
the tracked source:

- `docker-compose.example.yml` — one Counter-Strike server (`csserver`), host networking; owns the `build:`.
- `docker-compose.fleet.example.yml` — N Counter-Strike servers off the one image, host networking.
- `docker-compose.bridge.example.yml` — five servers of three games (`cstrike-01/02/03`, `tfc-01`, `dod-01`) on an external bridge network `gameservers`, one published UDP port each; one `build:` per game.

```bash
docker compose build                 # builds the image(s) the template declares (GAME build arg)
docker build --build-arg GAME=tfc -t rehlds-tfc:local .   # any one game directly (cstrike is the default)
docker compose build --no-cache      # clean build — re-runs SteamCMD + all downloads
docker compose up -d --build         # build + run
docker compose up -d                 # run / recreate with new env values (no rebuild)
docker compose logs -f <service>     # live HLDS console (csserver, or cstrike-01 / tfc-01 / dod-01 …)
docker compose exec <service> rcon "<cmd>"              # RCON (e.g. "meta list", "amxx version")
docker compose exec <service> /opt/hlds/healthcheck.sh   # A2S probe -> HEALTHY / UNHEALTHY
```

Build with `GPG_VERIFY=false` (compose build args, or `docker build --build-arg
GPG_VERIFY=false`) only when GitHub is unreachable at build time — SHA256
verification still runs.

Reset to a clean state: `docker compose down`, delete the server's volume dir
(`./serverdata/default` for the single server, `./serverdata/<name>` otherwise),
`docker compose up -d` — the next start re-seeds the volume.

**There is no test framework, linter, or build system beyond Docker.**
`TESTING.md` is a manual, numbered verification plan (clean build → first start →
stack loaded → master-server visibility → persistence → bot toggle → stack
refresh → no-root), with a section per game. To "run a single test", follow
that section's commands by hand.

## Architecture

### The ReHLDS stack is applied at BUILD time, not runtime

This is the central design decision. The running container has **no SteamCMD and
no update machinery** — nothing can ever clobber the engine.

- **Base image:** `cm2network/steamcmd`, pinned by digest (`BASE_DIGEST`).
- **Stage 1 `server-builder`** runs `scripts/build-server.sh`, which sources
  `profiles/${GAME}.sh` and:
  1. Installs the game (HLDS appid 90, `+app_set_config 90 mod <game>`,
     **`steam_legacy` branch**) via SteamCMD, looping until the install size
     stabilises and the sentinel files exist (appid-90 downloads are
     incrementally flaky). Snapshots the bare depot (SHA256 of every file).
  2. Fetches every stack component — a pinned GitHub release download, or a
     vendored archive from `vendor/` — verifies it (SHA256 for all, GPG for
     ReHLDS), and applies it onto `/build/serverfiles`: the shared stack in the
     script, the game's own parts in the profile's `profile_apply` hook.
  3. Writes `VERSIONS` (the pinned set, printed by the entrypoint banner) and
     `STACK-MANIFEST` (every file the build added to or changed in the depot,
     with its SHA256 — see [stack refresh](#runtime-seed-once-refresh-the-stack-render-then-run)).
- **Stage 2 `runtime`** bakes `/build/serverfiles` in as the immutable reference
  copy `/opt/hlds/serverfiles-base`, plus `VERSIONS`, `STACK-MANIFEST`, this
  game's profile as `/opt/hlds/profile.sh`, and its templates under
  `/opt/hlds/templates/`. (`/opt/cs16` was renamed to `/opt/hlds` when the image
  became multi-game; the path is referenced by the compose healthchecks.)

`steam_legacy` is mandatory: the post-25th-anniversary HLDS dropped the
`SteamGameServer_Init` symbol ReHLDS imports — the engine fails to load without
it. It installs `tfc` and `dod` cleanly too.

### Game profiles — what is shared, what is per game

`build-server.sh`, `entrypoint.sh`, `healthcheck.sh`, `rcon`, the compose
anchor and `config/reunion.cfg` are **shared and game-agnostic**. Everything
game-specific lives in **`profiles/<game>.sh`** — a bash file of variable
assignments and `profile_*` functions, sourced by `build-server.sh` (build) and
`entrypoint.sh` (runtime, variables only), so it must have no side effects:

| Variable / hook | Meaning |
|---|---|
| `GAME_TITLE`, `GAME_MOD`, `GAME_BOT` | banner title; SteamCMD mod name = game directory = `hlds -game`; the bot's name |
| `GAME_LIBRARY`, `GAME_BOT_LIBRARY` | the game library and the bot plugin (paths from the server root), checked by the build's loader trace |
| `GAME_DEFAULT_MAP`, `GAME_DEFAULT_MAXPLAYERS`, `GAME_DEFAULT_START_PARAMS` | entrypoint defaults for `DEFAULT_MAP`, `MAX_PLAYERS`, `EXTRA_START_PARAMS` |
| `GAME_SENTINELS`, `GAME_REQUIRED` | depot files the SteamCMD loop waits for; files that must exist after assembly |
| `GAME_AMXX_ADDON`, `GAME_AMXX_MODULES`, `GAME_AMXX_PLUGINS` | which `amxmodx-…-<addon>-linux.tar.gz` to apply; modules appended to `modules.ini`; stock plugins uncommented in AMXX `plugins.ini` |
| `GAME_OPERATOR_FILES` | files the image ships but the stack refresh never overwrites (bot tuning) |
| `profile_fetch`, `profile_apply`, `profile_versions` | fetch + apply the game's own components; its `VERSIONS` lines |

| | cstrike | tfc | dod |
|---|---|---|---|
| Game library | `cstrike/dlls/cs.so` **replaced by ReGameDLL_CS** | Valve's `tfc/dlls/tfc.so` | Valve's `dod/dlls/dod.so` |
| Extra components | ReGameDLL_CS, ReAPI | — | — |
| AMXX add-on → modules → plugins | `cstrike` → `cstrike`, `reapi` → (stock) | `tfc` → `tfcx` → `stats`, `statssounds`, `stats_logging` | `dod` → `dodx`, `dodfun` → same three |
| Bot (Metamod plugin line) | YaPB `addons/yapb/bin/yapb.so` | FoxBot `addons/foxbot/foxbot.so` | new_bot `new_bot/new_bot_mm.so` (in the gamedir, not `addons/`) + Sturmbot waypoint pack under `dod/sturmbot/waypoints/` |
| Bot tuning file(s) (volume, operator's) | `addons/yapb/conf/yapb.cfg` | `addons/foxbot/tfc/foxbot.cfg` (`max_bots`, stock 10), `default.cfg`, `configs/` | `new_bot/new_bot.cfg`, `new_bot/maps/default_bot.cfg` (`target_players 12`) |
| Defaults: map / slots / start params | `de_dust2` / 16 / `-pingboost 1 +sys_ticrate 1000` | `well` / 32 / none | `dod_anzio` / 32 / none |

Templates are per game too: `config/<game>/server.cfg` and
`config/<game>/plugins.ini` (the Metamod list; its `;@bot@` line is the game's
bot, toggled by `BOTS_ENABLED`). The ReHLDS flood, A2S, RCON, rate and logging
sections of `server.cfg` are identical across games; only the gameplay block
differs. **Adding a game** = a profile, the two templates, an env example, a
compose service, and the add-on's SHA256 ARG in the `Dockerfile`.

### Reproducible builds and vendoring

Every component version is a Dockerfile `ARG` paired with a `*_SHA256` ARG;
ReHLDS is additionally GPG-verified against a vendored key. Floating tags
(`latest`, `master`) are never used. Components with a stable upstream release
URL (ReHLDS, Metamod-R, AMX Mod X base + the three add-ons, Reunion, ReGameDLL,
ReAPI) are downloaded at build time. **Everything without one is vendored**
under `vendor/` and referenced from the `Dockerfile` by file name
(`*_ARCHIVE`) and SHA256: YaPB (upstream's rolling `continuous` release deletes
its previous assets on every push), FoxBot, new_bot (Google Drive) and the
Sturmbot waypoint pack. `fetch()` in `build-server.sh` takes either an
`https://` URL or an absolute path under `/build/vendor` and verifies the digest
the same way. `CHANGELOG.md` records the pinned set per game and each vendored
archive's upstream URL and download date.

**To upgrade a downloaded component:** bump its `*_VERSION` and `*_SHA256`
ARGs. **To upgrade a vendored one:** download the new archive, verify it, drop
it in `vendor/`, update `*_VERSION`, `*_ARCHIVE` and `*_SHA256`, record it in
`CHANGELOG.md`. Then rebuild the affected image(s) and recreate the servers:
the entrypoint refreshes existing volumes (next section).

### Runtime: seed once, refresh the stack, render, then run

`scripts/entrypoint.sh` sources `/opt/hlds/profile.sh` and:
1. **Seeds** the `/server` volume from `serverfiles-base` on first run and
   writes the image's `VERSIONS` to `/server/VERSIONS`. On later starts, if
   `/server/VERSIONS` differs from the image's (or is missing — a volume seeded
   by an older image), it **refreshes the stack-owned files**: every path in
   `STACK-MANIFEST` is re-copied from the image, except operator-owned files
   that already exist in the volume (`<game>/addons/amxmodx/configs/` for every
   game — `amxx.cfg`, `users.ini`, AMXX `plugins.ini` / `modules.ini` — plus the
   profile's `GAME_OPERATOR_FILES`, i.e. the bot tuning files). Nothing the
   image does not ship (added maps, logs, bans, learned bot data,
   `server-custom.cfg`) is touched, and nothing is deleted. `VERSIONS` ends with
   a digest of the manifest, so any change to an owned file — not only a version
   bump — triggers the refresh. A volume stamped for another game, or a
   non-empty one with no `<game>/liblist.gam`, is refused.
2. **Renders env-driven config on every start** — `server.cfg` (template + a
   generated env-override block appended last so it wins), Metamod
   `plugins.ini` (toggles the `@bot@` / `@reunion@` lines per `BOTS_ENABLED` /
   `REUNION_ENABLED`), `reunion.cfg` (only when Reunion is enabled), and the
   AMX Mod X `users.ini` (rewrites a container-managed `OWNER` block — see below).
3. Fixes ownership and `exec`s HLDS with `-game ${GAME_MOD}`, dropping to the
   unprivileged `steam` user via `gosu`. HLDS becomes the container's main
   process (clean SIGTERM). The compose templates start the container as that
   user already (`user: "1000:1000"`, all capabilities dropped), in which case
   the entrypoint skips the chown/`gosu` step and no root process exists at any
   point. A brand-new `./serverdata/<name>` bind-mounted volume must therefore
   be owned by uid 1000 before its first start (a named volume inherits it from
   the image's `/server`).

### The two-layer config model

`config/` holds the **curated source files** — the only server config tracked in
the repo. `serverdata/` is the **runtime volume**: the live, mutable
server install, seeded from the image's baked-in copy on first run, and
gitignored. Editing a file under `serverdata/` changes only the running server —
the repo's source of truth is `config/` plus the build.

#### Scope × authority — the rule that keeps it legible

Every config value has one **scope** (shared across all servers of a game, or
per-server) and one **authority** (where it is set). **One authority per
value** — never make the same value both env-tracked and operator-seeded, or it
becomes ambiguous which one wins.

| | Baked (build) | Env-rendered (every start) | Volume-seeded (once) |
|---|---|---|---|
| **Shared** | gameplay defaults, rates, flood / RCON / ReHLDS hardening (`config/<game>/server.cfg`); YaPB perf cvars (patched into `yapb.cfg`, cstrike); which AMXX modules/plugins are on | — | — |
| **Per-server** | — | identity, ports, passwords, `SV_*`, gates (`BOTS_ENABLED` / `REUNION_ENABLED`), `OWNER`, log retention (`LOG_RETENTION_DAYS`), `DEFAULT_MAP`, `MAX_PLAYERS`, `EXTRA_START_PARAMS` | `server-custom.cfg`, the bot tuning files, hand-added admins, `amxx.cfg`, reunion salt |

The **stack refresh** respects the same split: baked things are re-copied when
the image changes, volume-seeded things never are. Multi-server simply
instantiates the **per-server** column N times against the one shared image.

Config files fall into these categories — know which before editing:

| File | Kind | Editing rule |
|---|---|---|
| `config/<game>/server.cfg`, `config/<game>/plugins.ini`, `config/reunion.cfg` | **Templates** — copied to `/opt/hlds/templates/`, rendered every start | Edit the `config/` template. The live `<game>/` copy is overwritten. |
| `cstrike/addons/yapb/conf/yapb.cfg` | **Vendored + build-patched** — ships inside the YaPB archive; `profiles/cstrike.sh` rewrites our perf-cvar *values* in place at build time; seeded into the volume on first run, never refreshed | For a baked perf default, edit the `yapb_set` lines in `profiles/cstrike.sh` and rebuild. For bot tuning (quota/difficulty), edit the live copy — never overwritten after seeding. |
| `tfc/addons/foxbot/tfc/foxbot.cfg` (+ `default.cfg`, `configs/`), `dod/new_bot/new_bot.cfg` + `new_bot/maps/` | **Vendored, seeded** — stock bot tuning, untouched by the build | Edit the live copy for bot count / skill. Never overwritten. |
| `<game>/addons/amxmodx/configs/*` (`amxx.cfg`, `modules.ini`, `plugins.ini`, …) | **Stock, seeded** — the build only enables the game's modules/plugins; seeded on first run, never refreshed | Edit the live copy to tune AMX Mod X. Not tracked; never overwritten. |
| `<game>/server-custom.cfg` | **Operator escape hatch** — seeded empty by the entrypoint, `exec`'d last (`server.cfg` `exec`s it) | Operator's own server cvars. Never overwritten. |
| `<game>/addons/amxmodx/configs/users.ini` | **Managed block** — vendored AMXX file; the entrypoint rewrites only an `OWNER`-marked block each start | Set `OWNER` in the env file for the owner admin. Add other admins by hand, outside the managed block (they persist). |
| everything else in `STACK-MANIFEST` (engine, game library, Metamod, AMXX binaries, bot binaries and stock data, patched `liblist.gam`) | **Image-owned** — refreshed from the image whenever the stack changes | Never edit in the volume; change the build. |

Runtime values are all driven by the env file (`.env.example` is the documented
template; `<name>.env.example` per fleet member) — no rebuild needed to change
them. The **env keys are identical for every game**; only the defaults differ.
Bot *tuning* (count, difficulty) is the one thing deliberately not in the env:
it stays at each bot's stock defaults, tuned by editing the live bot config in
the volume — see [Bot config](#bot-config-per-game) below.

The `OWNER` env var holds the server owner's SteamID. When set, the entrypoint
bootstraps it into `users.ini` as a full AMX Mod X admin (flags
`abcdefghijklmnopqrstu` — all commands + immunity, account flags `ce` =
SteamID auth, no password). It rewrites only the block between its
`; >>> OWNER admin` / `; <<< OWNER admin` markers, so hand-added admins
elsewhere in the file survive. The bots have no SteamID admin model, so `OWNER`
does not touch them.

### Multi-server topology — one image per game, N services

This is **one image per game, many servers**, not one-repo-one-server. An image
is built once and is identical everywhere; all per-server difference is exactly
two things — an **env file** and a **`./serverdata/<name>` volume**. Adding a
server costs one env file plus a small service block, never a copied repo.

The split is strict:

- **Compose files hold topology only** — service name, `container_name`, the
  `./serverdata/<name>:/server` volume, `image:`, network and published port.
  They carry **no `${...}` interpolation**; all three templates share one anchor
  shape (`x-csserver` / `x-hlds`, merged with `<<:`). `build:` lives on one
  service per image, so the others reuse it — build once, run N.
- **Env files hold runtime config only** — everything the entrypoint reads
  (identity, ports, passwords, `SV_*`, `OWNER`, the `BOTS_ENABLED` /
  `REUNION_ENABLED` gates). Injected via `env_file:`, applied at start, no rebuild.

Two network topologies:

- **Host networking** (`docker-compose.example.yml`, `…fleet…`): reliable
  GoldSrc master-server registration; every server binds its own
  `SERVER_PORT` / `CLIENT_PORT` directly on the host, so those must be distinct
  per co-resident server. Whether multiple instances contend on the VAC/Steam
  port (UDP 26900) is unverified — see the open note in the fleet file.
- **Bridge networking** (`docker-compose.bridge.example.yml`): an external
  network `gameservers`, each service publishing one UDP port equal to its
  `SERVER_PORT` (the engine registers the port it binds, so host and container
  port are the same number). Separate network namespaces, so the 26900 question
  does not arise. This is the five-server layout: `tfc-01` 27015,
  `cstrike-01/02/03` 27016–27018, `dod-01` 27019 (client ports 270NN − 10); the
  env examples use the same map.

With more than one server, `docker compose exec` / `logs` take the **service
name**.

### Bot config per game

Each game ships exactly one bot, loaded by Metamod and gated by `BOTS_ENABLED`
(which toggles the `;@bot@` line of the rendered `plugins.ini`; when `false`,
the plugin never loads and none of its config runs). Bot tuning is **per-server,
operator-owned, in the volume**: seeded once from the image, listed in the
profile's `GAME_OPERATOR_FILES` so the stack refresh leaves it alone, and never
env-rendered.

- **cstrike / YaPB.** `yapb.cfg` is **vendored** — it ships inside the YaPB
  archive and is replaced wholesale on every YaPB version bump. Two concerns
  touch it, split by authority: our **performance defaults (shared, baked)** —
  `profiles/cstrike.sh` rewrites `yb_think_fps`, `yb_path_floyd_memory_limit`
  and `yb_path_astar_post_smooth` in place at build time, asserting each cvar
  exists and **failing the build** if upstream renames one — and **bot tuning
  (per-server, operator)**: `yb_quota` / `yb_quota_mode` / `yb_difficulty` /
  `yb_autovacate` stay at YaPB's stock defaults (`9` / `normal` / `3` / `1`),
  edited in the live `cstrike/addons/yapb/conf/yapb.cfg`. YaPB re-execs it each
  changelevel, so an edit applies on the next map with no restart. Across a
  YaPB bump, `scripts/migrate-yapb-cfg.py <name>` rewrites the live file from
  the new stock one keeping the tuned values (the refresh updates everything
  else in `addons/yapb/`).
- **tfc / FoxBot.** Stock config, untouched by the build. Bot count is
  `max_bots` (stock 10) in `tfc/addons/foxbot/tfc/foxbot.cfg`; `default.cfg`
  is the fallback for maps without a per-map `configs/<map>_bot.cfg`.
- **dod / new_bot.** Stock config, untouched by the build. Bot count is
  `target_players` (ships 12, `balance teams on`) in
  `dod/new_bot/maps/default_bot.cfg`; global behaviour in `dod/new_bot/new_bot.cfg`
  (all commented at stock). new_bot must be listed in Metamod's `plugins.ini`,
  never `config.ini` (its readme: that crashes). For maps it has no waypoint
  for it falls back to `dod/sturmbot/waypoints/` (the vendored pack). Fallback
  bot if new_bot misbehaves, documented in `profiles/dod.sh`, not shipped:
  Marine Bot.

## Gotchas

- `scripts/clear-execstack.py` clears the executable-stack ELF flag on GoldSrc
  `.so` files — Debian 13+ loaders reject exec-stack binaries. It runs in
  `build-server.sh`; required, do not remove. (The vendored bot `.so` files
  carry no exec-stack flag; the script is a no-op on them.)
- `build-server.sh` also patches `liblist.gam` (`gamedll_linux` → Metamod),
  appends the profile's modules to `modules.ini`, uncomments the profile's
  stock plugins in AMXX `plugins.ini`, and strips `.dll` / `.exe` files; the
  cstrike profile rewrites the YaPB perf-cvar values in `yapb.cfg`, the tfc
  profile drops FoxBot's HTML documentation and ignores the old Metamod the
  FoxBot zip bundles. These are all build-time mutations of SteamCMD/archive
  output, and they all end up in `STACK-MANIFEST`.
- **The depot's bundled 32-bit `libstdc++.so.6` / `libgcc_s.so.1`** sit at the
  server root and `hlds_run` puts `.` first on `LD_LIBRARY_PATH`, so they
  shadow the system ones. Valve's `tfc.so` needs a newer `CXXABI` than that
  copy has, so the tfc profile deletes the pair (the base image's
  `lib32stdc++6` takes over); cstrike and dod keep the depot as is.
  `build-server.sh` runs the 32-bit loader in trace mode over every library
  Metamod will dlopen (`GAME_LIBRARY`, Metamod, AMXX + its enabled modules,
  Reunion, `GAME_BOT_LIBRARY`) and fails the build on `not found`.
- **Stage 1 is one cached layer per game.** Any change to what it copies
  (`scripts/build-server.sh`, `clear-execstack.py`, `stack-manifest.py`,
  `profiles/`, `vendor/`, the signing key) re-runs SteamCMD for that game;
  changes to the runtime stage (entrypoint, templates, compose) do not.
- The regression check for a change that touches the shared build: build
  `GAME=cstrike` before and after and diff the two `serverfiles-base` trees
  (content hashes + modes). Only `VERSIONS` and `STACK-MANIFEST` are allowed to
  differ; the tree must be byte-identical.
- Each server needs an inbound port-forward for its own **UDP `SERVER_PORT`**.
- **Logging is unbounded at three sinks by default; this image caps all three.**
  (1) Docker's stdout capture of the HLDS console is capped by a `logging:`
  json-file block (`max-size 10m` × `max-file 3`) in the compose anchor — shared
  topology, so it applies to every fleet member at once. (2) The engine's
  in-volume logs (`<game>/logs/`, a new file per map change) and (3) AMX Mod X's
  logs (`addons/amxmodx/logs/`, daily) are pruned on every start by `prune_logs`
  in `entrypoint.sh`, gated per-server by `LOG_RETENTION_DAYS` (env-rendered;
  empty/0 = keep all). `log on` writes the gameplay log to *both* stdout and
  `<game>/logs/`, so caps (1) and (2) both matter. Reunion stays at
  `LoggingMode = 1` (console only → folds into sink 1).
