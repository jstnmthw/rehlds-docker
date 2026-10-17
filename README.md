# ReHLDS GoldSrc servers

A Docker image family that runs **Counter-Strike 1.6**, **Team Fortress
Classic** and **Day of Defeat** dedicated servers on the **ReHLDS** engine
stack — engine, Metamod, AMX Mod X and one bot per game, all assembled and
pinned at build time. One Dockerfile, a `GAME` build argument, one image per
game: `rehlds-cstrike:local`, `rehlds-tfc:local`, `rehlds-dod:local`.

## Why

Valve effectively froze the stock GoldSrc (HLDS) dedicated server long ago: it
still runs, but it gets no performance work and no bug fixes. **ReHLDS** is a
reverse-engineered, still actively maintained drop-in replacement for the
engine — and it is the reason this image exists:

- **Performance** — a substantial speed-up over stock HLDS: more headroom and
  lower CPU use, especially under load.
- **Maintenance** — years of bug fixes and stability work Valve never shipped,
  with releases still landing.
- **Hardening** — engine-level rate limiting (`sv_rehlds_stringcmdrate_*`,
  `sv_rehlds_movecmdrate_*`, `sv_rehlds_maxclients_from_single_ip`) that blunts
  the old `A2S_INFO` / *TSource Engine Query* UDP flood, a long-known way to peg
  a GoldSrc server's CPU.

## The stack

| Layer | Component | cstrike | tfc | dod |
|---|---|---|---|---|
| Engine | **ReHLDS** (`engine_i486.so` + `hlds_linux`) | ✓ | ✓ | ✓ |
| Game library | **ReGameDLL_CS** replaces `cstrike/dlls/cs.so` | ✓ | Valve's `tfc.so` | Valve's `dod.so` |
| Metamod | **Metamod-R** | ✓ | ✓ | ✓ |
| Plugins | **AMX Mod X** base + the game's add-on | `cstrike` add-on, **ReAPI** | `tfc` add-on (`tfcx`, stats) | `dod` add-on (`dodx`, `dodfun`, stats) |
| Bots | one per game, toggled by `BOTS_ENABLED` | **YaPB** | **FoxBot** (+597 stock waypoints) | **new_bot** (+ the Sturmbot waypoint pack) |
| Non-Steam | **Reunion** *(optional)*, toggled by `REUNION_ENABLED` | ✓ | ✓ | ✓ |

Exact pinned versions, source URLs and checksums are in
[`CHANGELOG.md`](CHANGELOG.md). Builds are reproducible: the base image is
pinned by digest, every component is pinned by version + SHA256, ReHLDS is
additionally GPG-verified, and the archives with no stable upstream URL (the
bots) are vendored in `vendor/`.

## How it works

Everything is assembled **at build time**, and the running container never
changes it.

**Build (stage 1, `scripts/build-server.sh` + `profiles/<game>.sh`):**
1. Install the game (HLDS appid 90, `mod <game>`) with SteamCMD, from the
   **`steam_legacy`** branch. *(The Half-Life 25th-anniversary update shipped a
   new HLDS whose `libsteam_api.so` is incompatible with the ReHLDS engine —
   it fails with `undefined symbol: SteamGameServer_Init`. `steam_legacy` is
   the older, ReHLDS-compatible HLDS.)* SteamCMD's appid-90 download is
   famously incremental, so the build loops it until the install is verified
   complete.
2. Fetch every stack component (a pinned GitHub release, or a vendored
   archive), verify it (SHA256 + GPG for ReHLDS), and apply it onto the
   install — replacing the engine (and, for CS, the game library), adding the
   addons and the bot, patching `liblist.gam` to load Metamod and enabling the
   game's AMX Mod X modules and plugins.
3. Record `VERSIONS` (the pinned set) and `STACK-MANIFEST` (every file the
   stack added or changed, with its hash).

**Runtime (`scripts/entrypoint.sh`):**
1. On first run, seed the `/server` volume from the image's baked-in copy. On
   later starts, if the image's stack changed, re-copy the stack-owned files
   into the volume — never the operator's (see [Updating](#updating)).
2. Render `server.cfg`, the Metamod `plugins.ini`, `reunion.cfg` and the
   `OWNER` admin from the environment.
3. Run HLDS.

There is **no update machinery** — no SteamCMD at runtime, nothing that
re-applies the stack or can clobber ReHLDS. To move to newer component
versions you bump the pin in the `Dockerfile` and rebuild.

## Prerequisites

- A Linux host with **Docker Engine** + the **Docker Compose plugin**.
  Host networking (the single-server template's default) requires Linux.
- Outbound internet for the build (SteamCMD + component downloads).
- An inbound port-forward of each server's **UDP `SERVER_PORT`** (see
  [Port forwarding](#port-forwarding)).

## Quick start (one Counter-Strike server)

```bash
cp docker-compose.example.yml docker-compose.yml   # single-server topology
cp .env.example .env
nano .env                       # at minimum, set RCON_PASSWORD and SERVER_NAME
docker compose up -d --build
docker compose logs -f          # watch the boot
```

`docker-compose.yml` is gitignored — copy a template into place first
(`docker-compose.example.yml` for a single server, `docker-compose.fleet.example.yml`
for a CS fleet, `docker-compose.bridge.example.yml` for several games). The
templates stay tracked; your working copy is yours.

The build takes a while (SteamCMD installs the game and the ReHLDS stack is
assembled). Once built, container start is quick. You should see in the logs
the version banner, the seed step, and HLDS reaching the map.

Within a few minutes the server appears in Steam's **Internet** server browser.

To build another game directly: `docker build --build-arg GAME=tfc -t rehlds-tfc:local .`
(`GAME=dod` likewise; `cstrike` is the default).

## Configuration

Everything is configured through the server's **env file** (`.env` for the
single server, `<name>.env` per fleet member) — applied at container start,
no rebuild needed. See [`.env.example`](.env.example) for the full list. **The
keys are the same for every game; only the defaults differ.**

| Variable | Purpose | cstrike | tfc | dod |
|---|---|---|---|---|
| `SERVER_NAME` | name in the server browser | `ReHLDS Counter-Strike 1.6` | `ReHLDS Team Fortress Classic` | `ReHLDS Day of Defeat` |
| `RCON_PASSWORD` | remote console password — **set this** | *(empty = RCON off)* | | |
| `SERVER_PASSWORD` | join password (empty = public) | *(empty)* | | |
| `OWNER` | SteamID bootstrapped as a full AMX Mod X admin | *(empty)* | | |
| `SERVER_PORT` / `CLIENT_PORT` | game/query UDP port, client channel | `27015` / `27005` | | |
| `MAX_PLAYERS` | player slots | `16` | `32` | `32` |
| `DEFAULT_MAP` | boot map | `de_dust2` | `well` | `dod_anzio` |
| `SV_REGION` | Steam master-server region (`255` = world) | `255` | | |
| `BOTS_ENABLED` | load the game's bot (count/skill are the bot's own config — see below) | `true` | | |
| `REUNION_ENABLED` | accept non-Steam clients | `false` | | |
| `LOG_RETENTION_DAYS` | prune in-volume logs older than N days on start | `14` (examples) | | |
| `EXTRA_START_PARAMS` | extra HLDS launch flags | `-pingboost 1 +sys_ticrate 1000` | *(none)* | *(none)* |

After editing the env file: `docker compose up -d` (or `up -d <name>`) to
recreate with the new settings.

The env file holds **runtime** config only; topology (container name, volume
path, published port) lives in `docker-compose.yml`. Bot **count and
difficulty** are not in the env — they stay at each bot's stock defaults, tuned
by editing the bot's live config in the volume; `BOTS_ENABLED` only decides
whether the bot loads at all.

**Config files inside the volume** (`serverdata/<name>/<game>/`, e.g.
`serverdata/default/cstrike/` for the single server):

- `server.cfg` — regenerated every start from `config/<game>/server.cfg` + the
  env file. Do **not** edit it directly; it is overwritten.
- `server-custom.cfg` — **your** server escape hatch. Seeded empty, `exec`'d
  last (so it wins), never overwritten. Put any custom server cvars here.
- **Bot tuning** — seeded from the image once, then yours, applied on the next
  map change (YaPB) or map change / restart (the others):
  - cstrike: `addons/yapb/conf/yapb.cfg` — `yb_quota` / `yb_quota_mode` /
    `yb_difficulty` / `yb_autovacate` at YaPB's stock `9` / `normal` / `3` / `1`.
    Our performance defaults (`yb_think_fps` etc.) are baked into this file at
    build time.
  - tfc: `addons/foxbot/tfc/foxbot.cfg` — `max_bots` (stock 10), skill, chat;
    `default.cfg` is the fallback for maps without a `configs/<map>_bot.cfg`.
  - dod: `new_bot/maps/default_bot.cfg` — `target_players` (ships 12,
    `balance teams on`); global behaviour in `new_bot/new_bot.cfg`.
- `addons/amxmodx/configs/users.ini` — the AMX Mod X admin list. Seeded from
  the image, then yours to edit. If `OWNER` is set, the container also rewrites
  a marked owner block in it on every start (full admin by SteamID); admins you
  add by hand outside that block persist.
- `addons/amxmodx/configs/amxx.cfg` and the other `addons/amxmodx/configs/*`
  files — AMX Mod X's stock configs (the build only enables the game's modules
  and stats plugins), seeded from the image, then yours to edit.

### ReHLDS flood protection

The flood-protection cvars live in every `config/<game>/server.cfg`:

```
sv_rehlds_stringcmdrate_max_avg 80
sv_rehlds_stringcmdrate_max_burst 400
sv_rehlds_movecmdrate_max_avg 400
sv_rehlds_movecmdrate_max_burst 2500
sv_rehlds_maxclients_from_single_ip 5
```

If legitimate players are being rate-limited, raise the values in
`<game>/server-custom.cfg` (exec'd last, so it wins) and watch the console log.

## Server admin

The server is managed with Docker plus RCON (`csserver` below is the
single-server service; in a fleet use the service name, e.g. `tfc-01`):

```bash
docker compose logs -f csserver               # live console output
docker compose restart csserver               # restart
docker compose exec csserver rcon "meta list"  # run a console command via RCON
docker compose exec csserver rcon "stats"
docker compose exec csserver rcon "amxx version"
```

`rcon` is a small client baked into the image; it reads `RCON_PASSWORD` from
the environment. RCON also works from any external RCON tool against your
public IP.

### In-game admin

Set `OWNER` in the env file to your SteamID to get full AMX Mod X admin
in-game — all command flags plus immunity, authenticated by SteamID with no
admin password. After `docker compose up -d`, verify with `amx_who` or by
opening `amxmodmenu` in the in-game console. Add further admins by editing
`<game>/addons/amxmodx/configs/users.ini` directly (outside the
container-managed `OWNER` block, which is regenerated each start).

## Updating

- **Component versions** are pinned as `ARG`s in the `Dockerfile`. To upgrade
  a downloaded component (ReHLDS, Metamod-R, AMX Mod X, Reunion, ReGameDLL,
  ReAPI), bump its `*_VERSION` and `*_SHA256`. To upgrade a vendored one
  (YaPB, FoxBot, new_bot, the waypoint pack), drop the new archive into
  `vendor/` and bump `*_VERSION`, `*_ARCHIVE` and `*_SHA256`. Then rebuild the
  affected image(s) and recreate the servers one at a time while they are
  empty (`docker compose up -d <name>`).
- **Existing volumes follow the image.** The entrypoint keeps the image's
  `VERSIONS` in `/server/VERSIONS`; when a rebuilt image's stack differs it
  re-copies every stack-owned file (engine, game library, Metamod, AMX Mod X,
  the bot's binaries and stock data, patched files) into the volume and leaves
  the operator's files alone — `server-custom.cfg`, `addons/amxmodx/configs/`
  (`amxx.cfg`, `users.ini`, …), the bot tuning files, maps you added, logs,
  bans and learned bot data. Nothing is deleted. Across a **YaPB** version
  bump, `scripts/migrate-yapb-cfg.py <name>` carries your tuned values into
  the new stock `yapb.cfg` (the one YaPB file the refresh leaves alone).
- **The games themselves** do not meaningfully update — they are pinned to the
  `steam_legacy` branch and installed once at build time.

## Verifying

```bash
# the ReHLDS stack loaded:
docker compose exec csserver rcon "meta list"        # -> Metamod-R: AMX Mod X + the bot (YaPB / FoxBot / new_bot)
docker compose exec csserver rcon "amxx version"

# the server answers Steam queries:
docker compose exec csserver /opt/hlds/healthcheck.sh   # -> HEALTHY
docker compose ps                                       # -> healthy

# the image's pinned set and the volume's:
docker compose exec csserver cat /opt/hlds/VERSIONS /server/VERSIONS
```

See [`TESTING.md`](TESTING.md) for the full test plan, with a section per game.

## Port forwarding

Forward each server's **UDP `SERVER_PORT`** on your router to the host's LAN
IP. With host networking the server binds it directly on the host; with the
bridge template it is the one published port (host port = `SERVER_PORT`).

| Port | Proto | Purpose | Forward? |
|---|---|---|---|
| `SERVER_PORT` (27015…) | UDP | game traffic + Steam (A2S) queries | **Yes** |
| `CLIENT_PORT` (27005…) | UDP | client/RCON channel | usually not needed (outbound) |
| `26900` | UDP | VAC | outbound only |

Master-server listing can take a few minutes after start.

## Persistence

Each server's files live in its own host directory under `./serverdata/<name>`
(the single server's is `./serverdata/default`), seeded from the image's baked-in
copy on first run. Maps, logs, admin lists (`users.ini`), bans (`banned.cfg` /
`listip.cfg`, reloaded by `server.cfg` on every start) and bot tuning persist
there. To reset a server to a clean state, stop it and delete its
`./serverdata/<name>` directory — the next start re-seeds it. The containers
run as uid 1000 with no root process, so a brand-new directory must be owned by
uid 1000 before its first start.

## Running multiple servers

Run any number of servers from the **one** image per game — no copied repos.
Each server is just a service block, its own env file, and its own
`./serverdata/<name>` volume. Two templates:

- [`docker-compose.fleet.example.yml`](docker-compose.fleet.example.yml) — N
  Counter-Strike servers on host networking (`cstrike-01`, `cstrike-02`).
- [`docker-compose.bridge.example.yml`](docker-compose.bridge.example.yml) —
  five servers of three games on a bridge network, one published UDP port
  each: `tfc-01` 27015, `cstrike-01/02/03` 27016–27018, `dod-01` 27019.

```bash
# bridge layout: the network exists once, each image is built once
docker network create gameservers
cp docker-compose.bridge.example.yml docker-compose.yml
docker compose build                          # rehlds-cstrike, rehlds-tfc, rehlds-dod

# one env file per server; keep SERVER_PORT equal to the published port
cp cstrike-01.env.example cstrike-01.env      # … -02, -03
cp tfc-01.env.example tfc-01.env
cp dod-01.env.example dod-01.env

# volumes owned by uid 1000, then one server at a time
mkdir -p serverdata/{cstrike-01,cstrike-02,cstrike-03,tfc-01,dod-01}
docker compose up -d dod-01 && docker compose logs -f dod-01
docker compose exec dod-01 rcon "meta list"
```

Each server is fully independent: own env file, own `./serverdata/<name>`
volume (admins, bans, bot tuning, Reunion salt), own port. The compose file
holds only **topology** (service name, container name, volume, image, network,
port) with no `${...}` interpolation; all runtime config is in the env files.

> **Host networking:** co-resident servers share the host network, so give
> each a distinct `SERVER_PORT` / `CLIENT_PORT`. The VAC/Steam port (UDP 26900)
> behaviour with multiple instances still needs confirming — see the note at
> the bottom of the fleet file. The bridge template sidesteps this: every
> container has its own network namespace.

## Troubleshooting

| Symptom | Check |
|---|---|
| Container `unhealthy` | `docker compose logs`. The healthcheck is an A2S probe; it passes once the server answers queries. |
| Not in the server browser | `SV_LAN=0`, a valid `SV_REGION`, **UDP `SERVER_PORT` forwarded**, host firewall open. Listing can take a few minutes. |
| `undefined symbol: SteamGameServer_Init` | The build used the wrong HLDS — the `STEAM_BRANCH` build arg must be `steam_legacy`. Rebuild. |
| Build fails on GPG | If GitHub is unreachable at build time, build with `--build-arg GPG_VERIFY=false` (SHA256 verification still runs). |
| `FATAL: … holds a 'tfc' install but this image is 'cstrike'` | The volume belongs to another game's server — check the `volumes:` line. |
| `rcon` rejected | `RCON_PASSWORD` mismatch, or RCON disabled (empty password). |
| Want to reset everything | `docker compose down`, delete the server's `./serverdata/<name>` dir, `docker compose up -d`. |

## Out of scope

Intentionally **not** implemented:

- HLTV / SourceTV
- Web admin panel
- Stats / external logging integrations
- A fleet manager / orchestrator. Running several servers is supported (see
  [Running multiple servers](#running-multiple-servers)), but it is a static
  compose file you edit by hand — no dynamic scaling or scheduler.
- Dynamic DNS / changing-IP handling
- Other games: adding one is a profile, two templates, an env example and a
  compose service (see `CLAUDE.md`), but only cstrike, tfc and dod ship.

## Repository layout

```
Dockerfile                        multi-stage: build the server for ${GAME} -> lean runtime image
docker-compose.example.yml        single CS server: build, volume, restart, healthcheck (host network)
docker-compose.fleet.example.yml  N CS servers off the one image (host network)
docker-compose.bridge.example.yml five servers / three games on a bridge network, one port each
                                  (copy one to docker-compose.yml — gitignored — to run)
.env.example                      single-server runtime config, every tunable commented
cstrike-0[123].env.example        per-server runtime config templates (same keys for every game)
tfc-01.env.example
dod-01.env.example
profiles/
  cstrike.sh  tfc.sh  dod.sh      per-game: depot mod, sentinels, AMXX add-on/modules/plugins,
                                  bot, defaults, operator-owned files, fetch/apply hooks
scripts/
  build-server.sh       build-time: SteamCMD install + ReHLDS assembly (shared)
  stack-manifest.py     build-time: which files the stack owns (for the volume refresh)
  clear-execstack.py    build-time: clear the exec-stack ELF flag
  entrypoint.sh         runtime: seed / refresh volume, render config, run HLDS
  healthcheck.sh        A2S-query healthcheck
  rcon                  minimal RCON client for admin commands
  migrate-yapb-cfg.py   carry tuned yapb.cfg values across a YaPB bump (cstrike)
config/
  cstrike/ tfc/ dod/    server.cfg + Metamod plugins.ini templates per game
  reunion.cfg           Reunion config template (shared)
  rehlds-signing-key.asc  vendored ReHLDS GPG public key
vendor/                 SHA256-pinned archives with no stable upstream URL:
                        YaPB, FoxBot, new_bot, the Sturmbot waypoint pack
```
