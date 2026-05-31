# ReHLDS Counter-Strike 1.6 server

A Docker image that runs a **Counter-Strike 1.6** dedicated server
on the **ReHLDS** engine stack — engine, game DLL, Metamod, AMX Mod X and bots,
all assembled and pinned at build time.

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

| Layer | Component | Role |
|---|---|---|
| Engine | **ReHLDS** | `engine_i486.so` + `hlds_linux` (replaces stock HLDS) |
| Game DLL | **ReGameDLL_CS** | `cstrike/dlls/cs.so` (+ `delta.lst`, `game.cfg`) |
| Metamod | **Metamod-R** | plugin loader |
| Plugins | **AMX Mod X** + **ReAPI** | admin/plugin platform + extended natives |
| Bots | **YaPB** | bots, toggled by `BOTS_ENABLED` |
| Non-Steam | **Reunion** *(optional)* | protocol 47/48 clients, toggled by `REUNION_ENABLED` |

Exact pinned versions, source URLs and checksums are in
[`CHANGELOG.md`](CHANGELOG.md). Builds are reproducible: the base image is
pinned by digest, every component is pinned by version + SHA256, and ReHLDS is
additionally GPG-verified.

## How it works

This image takes the **simple, robust** approach: everything is assembled
**at build time**, and the running container never changes it.

**Build (stage 1, `build-server.sh`):**
1. Install CS 1.6 (HLDS appid 90) with SteamCMD, from the **`steam_legacy`**
   branch. *(The Half-Life 25th-anniversary update shipped a new HLDS whose
   `libsteam_api.so` is incompatible with the ReHLDS engine — it fails with
   `undefined symbol: SteamGameServer_Init`. `steam_legacy` is the older,
   ReHLDS-compatible HLDS.)* SteamCMD's appid-90 download is famously
   incremental, so the build loops it until the install is verified complete.
2. Download every ReHLDS-stack release, verify it (SHA256 + GPG for ReHLDS),
   and apply it onto the install — replacing the engine and game DLL, adding
   the addons, and patching `liblist.gam` to load Metamod.

**Runtime (`entrypoint.sh`):**
1. On first run, seed the `/server` volume from the image's baked-in copy.
2. Render `server.cfg`, the Metamod `plugins.ini`, and `reunion.cfg` from the
   environment.
3. Run HLDS.

There is **no update machinery** — no SteamCMD at runtime, nothing that
re-applies the stack or can clobber ReHLDS. To move to newer component
versions you bump the pinned version in the `Dockerfile` and rebuild.

## Prerequisites

- A Linux host with **Docker Engine** + the **Docker Compose plugin**.
  Host networking (used by default) requires Linux.
- Outbound internet for the build (SteamCMD + component downloads).
- A public, port-forwarded **UDP 27015** to be reachable from the internet
  (see [Port forwarding](#port-forwarding)).

## Quick start

```bash
cp docker-compose.example.yml docker-compose.yml   # pick the single-server topology
cp .env.example .env
nano .env                       # at minimum, set RCON_PASSWORD and SERVER_NAME
docker compose up -d --build
docker compose logs -f          # watch the boot
```

`docker-compose.yml` is gitignored — copy a template into place first
(`docker-compose.example.yml` for a single server, `docker-compose.fleet.example.yml`
for a fleet). The templates stay tracked; your working copy is yours.

The build takes a while (SteamCMD installs CS 1.6 and the ReHLDS stack is
assembled). Once built, container start is quick. You should see in the logs
the version banner, the seed step, and HLDS reaching the map.

Within a few minutes the server appears in Steam's **Internet** server browser.

## Configuration

Everything is configured through **`.env`** — applied at container start, no
rebuild needed. See [`.env.example`](.env.example) for the full list.

| Variable | Purpose | Default |
|---|---|---|
| `SERVER_NAME` | name in the server browser | `ReHLDS Counter-Strike 1.6` |
| `RCON_PASSWORD` | remote console password — **set this** | `changeme-rcon-pass` |
| `SERVER_PASSWORD` | join password (empty = public) | *(empty)* |
| `OWNER` | SteamID bootstrapped as a full AMX Mod X admin | *(empty)* |
| `SERVER_PORT` | game/query UDP port | `27015` |
| `MAX_PLAYERS` | player slots | `16` |
| `DEFAULT_MAP` | boot map | `de_dust2` |
| `SV_REGION` | Steam master-server region (`255` = world) | `255` |
| `BOTS_ENABLED` | load YaPB bots (count/skill are YaPB defaults — edit `yapb.cfg`, see below) | `true` |
| `REUNION_ENABLED` | accept non-Steam clients | `false` |
| `EXTRA_START_PARAMS` | extra HLDS launch flags | `-pingboost 1 +sys_ticrate 1000` |

After editing `.env`: `docker compose up -d` to recreate with the new settings.

`.env` holds **runtime** config only; topology (container name, volume path) lives
in `docker-compose.yml`. Bot **count and difficulty** are not in `.env` — they stay
at YaPB's stock defaults, tuned by editing the live `addons/yapb/conf/yapb.cfg`
(see below); `BOTS_ENABLED` only decides whether bots load at all.

**Config files inside the volume** (`serverdata/<name>/cstrike/`, e.g.
`serverdata/default/cstrike/` for the single server):

- `server.cfg` — regenerated every start from `config/server.cfg` + your
  `.env`. Do **not** edit it directly; it is overwritten.
- `server-custom.cfg` — **your** server escape hatch. Seeded empty, `exec`'d
  last (so it wins), never overwritten. Put any custom server cvars here.
  (An older `serverextra.cfg` is auto-renamed to this on first start.)
- `addons/yapb/conf/yapb.cfg` — YaPB's own config, and the place for all bot
  tuning: count, mode and difficulty (`yb_quota` / `yb_quota_mode` /
  `yb_difficulty` / `yb_autovacate`) are at YaPB's stock defaults (`9` /
  `normal` / `3` / `1`). Edit them here in the live file — changes apply on the
  next map change, no restart, and survive it (YaPB re-execs this file each map).
  Our performance defaults (`yb_think_fps` etc.) are baked into this file at
  build time. (`.env`'s `BOTS_ENABLED` only toggles whether YaPB loads.)
- `addons/amxmodx/configs/users.ini` — the AMX Mod X admin list. Seeded from
  the image, then yours to edit. If `OWNER` is set in `.env`, the container
  also rewrites a marked owner block in it on every start (full admin by
  SteamID); admins you add by hand outside that block persist.
- `addons/amxmodx/configs/amxx.cfg` and the other `addons/amxmodx/configs/*`
  files — AMX Mod X's stock configs, seeded from the image, then yours to edit.
  They live in the volume and persist; edit `amxx.cfg` directly to tune AMX Mod X
  (scrolling messages, vote ratios, ...).

### ReHLDS flood protection

The flood-protection cvars live in `config/server.cfg`:

```
sv_rehlds_stringcmdrate_max_avg 80
sv_rehlds_stringcmdrate_max_burst 400
sv_rehlds_movecmdrate_max_avg 400
sv_rehlds_movecmdrate_max_burst 2500
sv_rehlds_maxclients_from_single_ip 5
```

If legitimate players are being rate-limited, raise the values in
`cstrike/server-custom.cfg` (exec'd last, so it wins) and watch the console log.

## Server admin

The server is managed with Docker plus RCON:

```bash
docker compose logs -f csserver               # live console output
docker compose restart csserver               # restart
docker compose exec csserver rcon "meta list"  # run a console command via RCON
docker compose exec csserver rcon "stats"
docker compose exec csserver rcon "amx_version"
```

`rcon` is a small client baked into the image; it reads `RCON_PASSWORD` from
the environment. RCON also works from any external RCON tool against your
public IP.

Running [multiple servers](#running-multiple-servers)? Address each by its
service name and add the fleet file, e.g.
`docker compose -f docker-compose.fleet.example.yml exec cstrike-01 rcon "meta list"`.

### In-game admin

Set `OWNER` in `.env` to your SteamID to get full AMX Mod X admin in-game —
all command flags plus immunity, authenticated by SteamID with no admin
password. After `docker compose up -d`, verify with `amx_who` or by opening
`amxmodmenu` in the in-game console. Add further admins by editing
`cstrike/addons/amxmodx/configs/users.ini` directly (outside the
container-managed `OWNER` block, which is regenerated each start).

## Updating

- **Component versions** (ReHLDS, AMX Mod X, …) are pinned as `ARG`s in the
  `Dockerfile`. To upgrade, bump the version and its `*_SHA256`, then
  `docker compose up -d --build`.
- **CS 1.6 itself** does not meaningfully update — it is pinned to the
  `steam_legacy` branch and installed once at build time.

## Verifying

```bash
# the ReHLDS stack loaded:
docker compose exec csserver rcon "meta list"        # -> Metamod-R, AMX Mod X (+ YaPB)
docker compose exec csserver rcon "amx_version"

# the server answers Steam queries:
docker compose exec csserver /opt/cs16/healthcheck.sh   # -> HEALTHY
docker compose ps                                       # -> healthy
```

See [`TESTING.md`](TESTING.md) for the full test plan.

## Port forwarding

The container uses **host networking**, so the server binds ports directly on
the host. Forward this on your router to the host's LAN IP:

| Port | Proto | Purpose | Forward? |
|---|---|---|---|
| `27015` | UDP | game traffic + Steam (A2S) queries | **Yes** |
| `27005` | UDP | client/RCON channel | usually not needed (outbound) |
| `26900` | UDP | VAC | outbound only |

Only **UDP 27015** needs an inbound forward for a normal public server. Master-
server listing can take a few minutes after start.

## Persistence

Each server's files live in its own host directory under `./serverdata/<name>`
(the single server's is `./serverdata/default`), seeded from the image's baked-in
copy on first run. Maps, logs, admin lists (`users.ini`) and bans persist there.
To reset a server to a clean state, stop it and delete its `./serverdata/<name>`
directory — the next start re-seeds it.

## Running multiple servers

Run any number of servers from the **one** image this repo builds — no copied
repos. Each server is just a service block, its own env file, and its own
`./serverdata/<name>` volume. See
[`docker-compose.fleet.example.yml`](docker-compose.fleet.example.yml), which
defines two (`cstrike-01`, `cstrike-02`).

```bash
# 1. build the shared image once (the single-server template owns the build:)
docker compose -f docker-compose.example.yml build

# 2. one env file per server, each with a DISTINCT SERVER_PORT / CLIENT_PORT
cp cstrike-01.env.example cstrike-01.env    # edit: RCON_PASSWORD, ports, name, ...
cp cstrike-02.env.example cstrike-02.env

# 3. bring the fleet up (each `up` only renders + seeds its own volume)
docker compose -f docker-compose.fleet.example.yml up -d
docker compose -f docker-compose.fleet.example.yml exec cstrike-01 rcon "meta list"
```

Each server is fully independent: own env file, own `./serverdata/<name>` volume
(admins, bans, bot tuning in `yapb.cfg`, Reunion salt), own ports. The compose file holds only
**topology** (service name, container name, volume, image) with no `${...}`
interpolation; all runtime config is in the env files.

> **Co-resident servers share the host network.** Give each a distinct
> `SERVER_PORT` / `CLIENT_PORT`. The VAC/Steam port (UDP 26900) behaviour with
> multiple instances still needs confirming — see the note at the bottom of the
> fleet file if only one server ends up listed.

## Troubleshooting

| Symptom | Check |
|---|---|
| Container `unhealthy` | `docker compose logs`. The healthcheck is an A2S probe; it passes once the server answers queries. |
| Not in the server browser | `SV_LAN=0`, a valid `SV_REGION`, **UDP 27015 forwarded**, host firewall open. Listing can take a few minutes. |
| `undefined symbol: SteamGameServer_Init` | The build used the wrong HLDS — the `STEAM_BRANCH` build arg must be `steam_legacy`. Rebuild. |
| Build fails on GPG | If GitHub is unreachable at build time, build with `--build-arg GPG_VERIFY=false` (SHA256 verification still runs). |
| `rcon` rejected | `RCON_PASSWORD` mismatch, or RCON disabled (empty password). |
| Want to reset everything | `docker compose down`, delete the server's `./serverdata/<name>` dir (single server: `./serverdata/default`), `docker compose up -d`. |

## Out of scope

Intentionally **not** implemented:

- HLTV / SourceTV
- Web admin panel
- Stats / external logging integrations
- A fleet manager / orchestrator. Running several servers is supported (see
  [Running multiple servers](#running-multiple-servers)), but it is a static
  compose file you edit by hand — no dynamic scaling or scheduler.
- Dynamic DNS / changing-IP handling

## Repository layout

```
Dockerfile                       multi-stage: build the server -> lean runtime image
docker-compose.example.yml       single-server topology template: build, volume, restart, healthcheck
docker-compose.fleet.example.yml multi-server template: N services off the one image
                                 (copy one to docker-compose.yml — gitignored — to run)
.env.example                     single-server runtime config, every tunable commented
cstrike-01.env.example           per-server runtime config templates for the fleet
cstrike-02.env.example
scripts/
  build-server.sh       build-time: SteamCMD install + ReHLDS assembly
  entrypoint.sh         runtime: seed volume, render config, run HLDS
  healthcheck.sh        A2S-query healthcheck
  rcon                  minimal RCON client for admin commands
config/
  server.cfg            CS 1.6 config template (ReHLDS flood protection)
  plugins.ini           Metamod plugin list template
  reunion.cfg           Reunion config template
  rehlds-signing-key.asc  vendored ReHLDS GPG public key
docs/
  multi-server-refactor.md  the phased plan behind the single-image/N-servers layout
```
