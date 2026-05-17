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

There is **no update machinery** — no SteamCMD at runtime, no overlay
re-application, nothing that can clobber ReHLDS. To move to newer component
versions you bump the pinned version in the `Dockerfile` and rebuild.

## Prerequisites

- A Linux host with **Docker Engine** + the **Docker Compose plugin**.
  Host networking (used by default) requires Linux.
- Outbound internet for the build (SteamCMD + component downloads).
- A public, port-forwarded **UDP 27015** to be reachable from the internet
  (see [Port forwarding](#port-forwarding)).

## Quick start

```bash
cp .env.example .env
nano .env                       # at minimum, set RCON_PASSWORD and SERVER_NAME
docker compose up -d --build
docker compose logs -f          # watch the boot
```

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
| `BOTS_ENABLED` | load YaPB bots | `true` |
| `BOT_QUOTA` / `BOT_DIFFICULTY` | bot count / skill | `6` / `3` |
| `REUNION_ENABLED` | accept non-Steam clients | `false` |
| `EXTRA_START_PARAMS` | extra HLDS launch flags | `-pingboost 1 +sys_ticrate 1000` |

After editing `.env`: `docker compose up -d` to recreate with the new settings.

**Config files inside the volume** (`DATA_DIR/cstrike/`):

- `server.cfg` — regenerated every start from `config/server.cfg` + your
  `.env`. Do **not** edit it directly; it is overwritten.
- `server-custom.cfg` — **your** server escape hatch. Seeded empty, `exec`'d
  last (so it wins), never overwritten. Put any custom server cvars here.
  (An older `serverextra.cfg` is auto-renamed to this on first start.)
- `addons/yapb/conf/yapb-overlay.cfg` — YaPB tuning overlay. Seeded with
  performance-tuned bot defaults, `exec`'d after YaPB's stock `yapb.cfg` (so it wins)
  on every map, never overwritten. Edit it to tune bots; see `yapb.cfg` for the
  full cvar list.
- `addons/amxmodx/configs/users.ini` — the AMX Mod X admin list. Seeded from
  the image, then yours to edit. If `OWNER` is set in `.env`, the container
  also rewrites a marked owner block in it on every start (full admin by
  SteamID); admins you add by hand outside that block persist.
- `addons/amxmodx/configs/amxx-custom.cfg` — **your** AMX Mod X escape hatch.
  Seeded empty, `exec`'d last by `amxx.cfg` (so it wins), never overwritten.
  Put AMX Mod X cvar overrides (scrolling messages, vote ratios, ...) here
  instead of editing `amxx.cfg`.
- other `addons/amxmodx/configs/*` files — seeded from the image, then yours
  to edit; they live in the volume and persist.

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

The serverfiles live in a volume (`DATA_DIR`, default `./serverdata`), seeded
from the image's baked-in copy on first run. Maps, logs, admin lists
(`users.ini`) and bans persist there. To reset the server to a clean state,
stop it and delete the directory — the next start re-seeds it.

## Running a second instance

```bash
cp -r . ../cs16-server-2 && cd ../cs16-server-2
# edit .env: different SERVER_PORT (e.g. 27016), CONTAINER_NAME, DATA_DIR
docker compose up -d --build
```

Each instance is fully independent (own `.env`, own volume, own port).

## Troubleshooting

| Symptom | Check |
|---|---|
| Container `unhealthy` | `docker compose logs`. The healthcheck is an A2S probe; it passes once the server answers queries. |
| Not in the server browser | `SV_LAN=0`, a valid `SV_REGION`, **UDP 27015 forwarded**, host firewall open. Listing can take a few minutes. |
| `undefined symbol: SteamGameServer_Init` | The build used the wrong HLDS — the `STEAM_BRANCH` build arg must be `steam_legacy`. Rebuild. |
| Build fails on GPG | If GitHub is unreachable at build time, build with `--build-arg GPG_VERIFY=false` (SHA256 verification still runs). |
| `rcon` rejected | `RCON_PASSWORD` mismatch, or RCON disabled (empty password). |
| Want to reset everything | `docker compose down`, delete `DATA_DIR`, `docker compose up -d`. |

## Out of scope

Intentionally **not** implemented:

- HLTV / SourceTV
- Web admin panel
- Stats / external logging integrations
- Multi-instance orchestration (the compose file is copy-pasteable, but there
  is no built-in second-instance config)
- Dynamic DNS / changing-IP handling

## Repository layout

```
Dockerfile              multi-stage: build the server -> lean runtime image
docker-compose.yml      production compose: env, volume, restart, healthcheck
.env.example            every tunable, commented
scripts/
  build-server.sh       build-time: SteamCMD install + ReHLDS assembly
  entrypoint.sh         runtime: seed volume, render config, run HLDS
  healthcheck.sh        A2S-query healthcheck
  rcon                  minimal RCON client for admin commands
config/
  server.cfg            CS 1.6 config template (ReHLDS flood protection)
  plugins.ini           Metamod plugin list template
  amxx.cfg              AMX Mod X core config
  yapb-overlay.cfg      YaPB performance/behaviour overlay (exec'd after yapb.cfg)
  reunion.cfg           Reunion config template
  rehlds-signing-key.asc  vendored ReHLDS GPG public key
```
