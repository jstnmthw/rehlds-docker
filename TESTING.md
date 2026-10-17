# Test plan

Verification steps for the ReHLDS image family: `rehlds-cstrike`, `rehlds-tfc`
and `rehlds-dod`. Sections 1–9 apply to every game; section 10 has the
per-game acceptance (banners, bot, modules). Run them in order.

Commands assume the repo directory with a `docker-compose.yml` in place. For a
single Counter-Strike server: `cp docker-compose.example.yml docker-compose.yml`,
`cp .env.example .env`, set `RCON_PASSWORD` / `SERVER_NAME`; the service is
`csserver`. For the five-server bridge layout:
`cp docker-compose.bridge.example.yml docker-compose.yml`, one env file per
server from the `*.env.example` templates, `docker network create gameservers`,
`mkdir -p serverdata/<name>` owned by uid 1000; the services are `cstrike-01`,
`cstrike-02`, `cstrike-03`, `tfc-01`, `dod-01`. Below, `<svc>` is the service
under test and `<game>` its game directory (`cstrike`, `tfc`, `dod`).

---

## 1. Clean build

**Purpose:** the build installs the game and assembles the ReHLDS stack, with
every archive verified.

```bash
docker compose build --no-cache                              # the template's image(s)
docker build --no-cache --build-arg GAME=tfc -t rehlds-tfc:local .   # or any one game directly
```

**Expect, per image:**
- `building <title> (GAME=<game>, mod <game>, bot <bot>)`;
- stage 1 loops `SteamCMD pass N` until `install complete and verified`;
- for tfc / dod, `trimming unused depot mod cstrike/`;
- `sha256 OK` for every component, `GPG signature OK  ReHLDS`, and
  `using vendored …` for the bot archive(s);
- the game's `enabled the … module in modules.ini` lines (cstrike: `cstrike`,
  `reapi`; tfc: `tfcx`; dod: `dodx`, `dodfun`) and, for tfc / dod, three
  `enabled the … plugin in plugins.ini` lines;
- for tfc, `dropped the depot's bundled libstdc++.so.6 / libgcc_s.so.1`;
- `resolves OK` for the game library, Metamod, AMX Mod X, the enabled modules,
  Reunion and the bot (the 32-bit loader trace; a `not found` fails the build);
- `N stack-owned files, digest …`, then `server assembled OK`;
- the only `.dll/.exe/.htm(l)` files reported are under `<game>/manual/`
  (and `tfc/classes/`) — the depot's own manual, left as installed;
- the image is tagged `rehlds-<game>:local`.

A deliberately wrong checksum (edit a `*_SHA256` ARG, including a vendored
one) **must** fail the build.

**Regression check** when the shared build changed (`build-server.sh`,
`Dockerfile` stage 1, `clear-execstack.py`, `stack-manifest.py`): build
`GAME=cstrike` from the previous commit and from the working tree, snapshot both
`/opt/hlds/serverfiles-base` trees (`sha256sum` of every file plus
`find -printf '%y %m %p'`) and diff. Only `steamapps/appmanifest_*.acf`
(SteamCMD bookkeeping) may differ.

---

## 2. First start

**Purpose:** a fresh volume is seeded and the server starts.

```bash
docker compose up -d <svc>
docker compose logs -f <svc>          # Ctrl+C to stop following
```

**Expect, in order:**
- the version banner (`ReHLDS <title> server`, then the `VERSIONS` lines:
  `Game`, `HLDS branch`, ReHLDS, Metamod-R, AMXModX, Reunion, the game's own
  components, `Stack digest`);
- `first run — seeding /server from the baked server copy` and `seeded N files`;
- `rendered <game>/server.cfg`, `rendered Metamod plugins.ini (bots=true [<bot>] reunion=false)`,
  `rendered users.ini …`, `seeded <game>/server-custom.cfg`;
- `started as uid 1000: no ownership fix, no privilege drop`;
- `starting HLDS — game <game>, map <map>, port <port>, N slots`;
- HLDS console output ending with the map loaded;
- after the health start-period: `docker compose ps` shows `healthy`.

```bash
docker compose ps                                    # State: Up (healthy)
docker compose exec <svc> /opt/hlds/healthcheck.sh   # -> HEALTHY: A2S reply
docker compose exec <svc> cat /server/VERSIONS       # == the banner
```

---

## 3. ReHLDS stack loaded

**Purpose:** ReHLDS, Metamod-R, AMX Mod X, the game module(s) and the bot are live.

```bash
docker compose logs <svc> | grep -iE 'ReHLDS|Metamod-r|AMX Mod X|ReGameDLL|yapb|foxbot|new_bot'
docker compose exec <svc> rcon "meta list"       # Metamod-R: AMX Mod X + the bot, both RUN
docker compose exec <svc> rcon "amxx modules"    # the game module(s), see section 10
docker compose exec <svc> rcon "amxx version"
```

**Expect:** `Metamod-r version 1.3.0.149`, `AMX Mod X 1.10.0.5476` in
`amxx version`, the engine's ReHLDS build on the `Exe build` line, and the
game's own banners from section 10.

---

## 4. Master-server visibility

**Purpose:** the server is publicly listed and joinable.

**Preconditions:** `SV_LAN=0`, a valid `SV_REGION`, and **UDP `SERVER_PORT`
forwarded** from your router to the host (host networking binds it directly;
the bridge template publishes it).

- In a Steam client: **View → Servers → Internet**, filter for `SERVER_NAME`.
  It should appear within a few minutes.
- Connect from a Steam client on another network using `<public-ip>:<port>`.

---

## 5. Restart / recreate / persistence

**Purpose:** the server survives restart and recreate, and the volume persists.

```bash
docker compose exec <svc> sh -c 'echo test > /server/<game>/persist-check.txt'

docker compose restart <svc>
docker compose exec <svc> cat /server/<game>/persist-check.txt   # -> test

docker compose up -d --force-recreate <svc>
docker compose exec <svc> cat /server/<game>/persist-check.txt   # -> test (volume kept)
docker compose logs <svc> | grep 'existing server volume'        # -> stack matches the image, keeping it
```

On recreate the volume persists, so the server is **not** re-seeded. To get a
clean reset: stop it, delete `./serverdata/<name>`, start — the logs then show
`first run — seeding` again.

Bans persist too — `server.cfg` execs `banned.cfg` / `listip.cfg` on every
start (on a fresh volume the first start logs `couldn't exec banned.cfg` until
the first `writeid` creates it):

```bash
docker compose exec <svc> rcon "banid 0 STEAM_0:0:424242"   # permanent ban, in memory
docker compose exec <svc> rcon "writeid"                     # -> <game>/banned.cfg in the volume
docker compose restart <svc>
docker compose exec <svc> rcon "listid"                      # -> STEAM_0:0:424242 still listed
docker compose exec <svc> rcon "removeid STEAM_0:0:424242; writeid"   # clean up
```

---

## 6. Bot toggle

**Purpose:** `BOTS_ENABLED` controls the game's bot.

```bash
# default (BOTS_ENABLED=true): the bot is in the Metamod plugin list
docker compose exec <svc> grep -v '^;' /server/<game>/addons/metamod/plugins.ini
#   cstrike -> linux addons/yapb/bin/yapb.so      tfc -> linux addons/foxbot/foxbot.so
#   dod     -> linux new_bot/new_bot_mm.so

# disable: BOTS_ENABLED=false in the env file, then
docker compose up -d <svc>
docker compose exec <svc> grep -v '^;' /server/<game>/addons/metamod/plugins.ini   # only amxmodx
docker compose logs <svc> | grep 'rendered Metamod'    # bots=false
```

With bots enabled, `rcon "status"` shows bot players after a minute; disabled,
none.

---

## 7. Reunion (optional)

Only if you set `REUNION_ENABLED=true`:

```bash
docker compose up -d <svc>
docker compose exec <svc> grep reunion /server/<game>/addons/metamod/plugins.ini   # -> line present
docker compose exec <svc> rcon "meta list"                                          # shows Reunion
```

---

## 8. Stack refresh on an existing volume

**Purpose:** a rebuilt image reaches an existing volume: the stack-owned files
are re-copied, the operator's files are not, nothing is deleted.

```bash
# plant: an edit to an image-owned file, an operator admin, bot tuning, a custom cvar, an extra file
V=./serverdata/<name>/<game>
echo '# planted' >> $V/addons/metamod/config.ini
echo '"STEAM_0:0:424242" "" "abc" "ce"   ; planted' >> $V/addons/amxmodx/configs/users.ini
echo 'sv_gravity 500' >> $V/server-custom.cfg
touch $V/maps/zz_custom.bsp
rm ./serverdata/<name>/VERSIONS            # or rebuild the image with a changed pin
docker compose up -d --force-recreate <svc>
docker compose logs <svc> | grep -E 'refreshing|refreshed'
```

**Expect:** `existing server volume found — image stack differs, refreshing the
stack-owned files`, then `refreshed N stack-owned file(s) from the image; K
operator-owned file(s) kept`. Afterwards `config.ini` no longer has the planted
line (it matches the image's copy), `users.ini`, `server-custom.cfg` and the
bot tuning file still have theirs, `maps/zz_custom.bsp` still exists, and
`./serverdata/<name>/VERSIONS` equals the image's. A second start logs `stack
matches the image, keeping it`.

A volume of another game is refused: starting the `tfc` image on a `cstrike`
volume exits with `FATAL: /server holds a 'cstrike' install but this image is
'tfc'`.

---

## 9. No root process

**Purpose:** with the compose anchor (`user: "1000:1000"`, `cap_drop: ALL`,
`no-new-privileges`) nothing in the container runs as root or with capabilities.

```bash
docker top <container> -eo uid,pid,cmd          # uid 1000 on every line
docker exec <container> grep CapEff /proc/1/status   # CapEff: 0000000000000000
docker exec <container> find /server -type f \( -iname '*.dll' -o -iname '*.exe' -o -iname '*.htm*' \) | grep -v /manual/   # nothing
```

---

## 10. Per-game acceptance

Run sections 2, 3, 6 and 9 for each game and check these specifics. Bots take
the bot's own join delay (FoxBot `pause 5` + one bot every 3 s; new_bot and
YaPB a few seconds) after the map loads.

### 10a. Counter-Strike 1.6 (`rehlds-cstrike`)

- Banner: `Game cstrike (Counter-Strike 1.6)`, `ReGameDLL_CS 5.28.0.756`,
  `ReAPI 5.26.0.338`, `YaPB 4.8.1311 (vendored)`.
- Console: `ReGameDLL version: 5.28.0.756-dev`, `YaPB v4.8.1311 successfully loaded for game: Counter-Strike v1.6.`.
- `rcon "meta list"`: `AMX Mod X` and `YaPB`, both `RUN`.
- `rcon "amxx modules"`: `cstrike` and `reapi` running.
- `rcon "status"`: YaPB bots (stock `yb_quota 9`) present on `de_dust2`.
- `rcon "yb_quota"` → `9`; our baked perf cvars: `grep -E '^yb_think_fps' /server/cstrike/addons/yapb/conf/yapb.cfg` → `"60.0"`.
- Live bot tuning: `sed -i 's/^yb_quota .*/yb_quota "4"/' …/yapb.cfg`, `rcon "changelevel de_dust2"`, `rcon "yb_quota"` → `4` (no restart).
- Defaults with an empty env: map `de_dust2`, 16 slots, `-pingboost 1 +sys_ticrate 1000` (`docker top` shows them).

### 10b. Team Fortress Classic (`rehlds-tfc`)

- Banner: `Game tfc (Team Fortress Classic)`, `FoxBot 0.911 (vendored)`.
- Console: FoxBot's own lines — `[Config] Reading foxbot_commanders.txt`,
  `loading waypoint file: tfc/addons/foxbot/tfc/waypoints/well.fwp` — and no
  `badf` plugin-load error or `Failure to load game DLL`.
- `rcon "meta list"`: `AMX Mod X` and `FoxBot`, both `RUN`.
- `rcon "amxx modules"`: `tfcx` running (plus the auto-loaded base modules).
- `rcon "status"`: FoxBot bots joining on `well` (stock `max_bots 10`,
  `addbot` lines in `foxbot.cfg`), moving and capturing.
- `/server/tfc/addons/amxmodx/configs/plugins.ini`: `stats.amxx`,
  `statssounds.amxx`, `stats_logging.amxx` uncommented.
- Defaults with an empty env: map `well`, 32 slots, no extra start parameters.
- Bot tuning: edit `max_bots` in `/server/tfc/addons/foxbot/tfc/foxbot.cfg`,
  `rcon "changelevel well"` — the new count applies.

### 10c. Day of Defeat (`rehlds-dod`)

- Banner: `Game dod (Day of Defeat)`, `new_bot 0.3.0 (vendored)`,
  `Sturmbot wpts 2026-10-04`.
- Console: `metamod version is compatible with new_bot`, `new_bot: plugin attaching`
  (a `…/routes/dod_anzio.wpr1 doesn't exist` line is normal: route files are generated).
- `rcon "meta list"`: `AMX Mod X` and `new_bot`, both `RUN`.
- `rcon "amxx modules"`: `dodx` and `dodfun` running.
- `rcon "status"`: new_bot bots on `dod_anzio` (`target_players 12` from
  `new_bot/maps/default_bot.cfg`).
- `/server/dod/sturmbot/waypoints/` holds 743 `.wpt` files;
  `/server/dod/new_bot/waypoints/` 121.
- Defaults with an empty env: map `dod_anzio`, 32 slots, no extra start parameters.
- Bot tuning: edit `target_players` in `/server/dod/new_bot/maps/default_bot.cfg`,
  `rcon "changelevel dod_anzio"` — the new count applies.

---

## 11. Multi-server (bridge layout)

**Purpose:** five servers of three games run from the three images, each fully
independent.

```bash
docker compose up -d dod-01 && docker compose logs -f dod-01   # new port, nothing to take down
docker compose up -d tfc-01
docker compose up -d cstrike-01   # then -02, -03, one at a time while empty
docker compose ps                 # five Up (healthy)
for s in cstrike-01 cstrike-02 cstrike-03 tfc-01 dod-01; do
  docker compose exec $s /opt/hlds/healthcheck.sh
  docker compose exec $s rcon "meta list"
done
```

**Expect:** each server seeds its own `serverdata/<name>` (no shared state),
answers A2S on its own published port, carries its own `OWNER` block in
`users.ini`, and `docker compose stop <name>` stops only that one.

---

## Done criteria checklist

- [ ] All three images build cleanly; SteamCMD install verified complete per
      game; SHA256 (downloaded + vendored) and the ReHLDS GPG check pass (Test 1)
- [ ] `GAME=cstrike` tree byte-identical to the previous build except the
      `appmanifest_*.acf` files (Test 1, regression check)
- [ ] First start yields a running, `healthy` server per game, with the volume
      stamped (`/server/VERSIONS`) (Test 2)
- [ ] `meta list` shows AMX Mod X + the game's bot; the game module(s) load;
      ReHLDS in the console banner (Tests 3, 10)
- [ ] Server appears in Steam's Internet browser and is joinable (Test 4)
- [ ] Server survives `restart` and recreate; the volume persists (Test 5)
- [ ] Bots present iff `BOTS_ENABLED=true`, for each game (Tests 6, 10)
- [ ] A changed image refreshes an existing volume's stack files and keeps the
      operator's; another game's volume is refused (Test 8)
- [ ] uid 1000 on every process line, `CapEff` all zeros, no `.dll` / `.exe` /
      bot HTML in the tree (Test 9)
- [ ] Bridge layout: five servers from three images, each on its own volume and
      port (Test 11)
