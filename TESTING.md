# Test plan

Verification steps for the ReHLDS CS 1.6 image. Run them in order. Commands
assume you are in the repo directory with a `.env` created
(`cp .env.example .env`, then set `RCON_PASSWORD` / `SERVER_NAME`).

The compose service is named `csserver`.

---

## 1. Clean build

**Purpose:** the build installs CS 1.6 and assembles the ReHLDS stack, with all
downloads verified.

```bash
docker compose build --no-cache
```

**Expect:**
- stage 1 loops `SteamCMD pass N` until `install complete and verified`;
- `sha256 OK` for every component and `GPG signature OK  ReHLDS`;
- `server assembled OK` with a non-zero file count;
- the build completes and tags `rehlds-csserver:local`.

A deliberately wrong checksum (edit a `*_SHA256` ARG) **must** fail the build.

---

## 2. First start

**Purpose:** a fresh volume is seeded and the server starts.

```bash
docker compose up -d
docker compose logs -f          # Ctrl+C to stop following
```

**Expect, in order:**
- the version banner;
- `first run — seeding /server from the baked server copy`;
- `rendered cstrike/server.cfg` / `rendered Metamod plugins.ini`;
- `starting HLDS — map de_dust2, port 27015, ...`;
- HLDS console output ending with the map loading (`Round_Start`);
- after the health start-period: `docker compose ps` shows `healthy`.

```bash
docker compose ps                         # State: Up (healthy)
docker compose exec csserver /opt/cs16/healthcheck.sh   # -> HEALTHY: A2S reply
```

---

## 3. ReHLDS stack loaded

**Purpose:** ReHLDS, Metamod-R, AMX Mod X, ReAPI and (default) YaPB are live.

```bash
docker compose logs csserver | grep -E 'Metamod-r|AMX Mod X|YaPB|ReGameDLL'
docker compose exec csserver rcon "meta list"     # Metamod-R + AMX Mod X (+ YaPB) RUN
docker compose exec csserver rcon "amx_modules"   # includes reapi
docker compose exec csserver rcon "amx_version"
```

**Expect:** the console banner shows `Metamod-r version 1.3.0.149`,
`AMX Mod X version 1.9.0.5303`, `ReGameDLL version 5.28.0.756`, and (with bots
on) `YaPB v4.4.957 successfully loaded`. The engine reports its ReHLDS build on
the `Exe build` line.

---

## 4. Master-server visibility

**Purpose:** the server is publicly listed and joinable.

**Preconditions:** `SV_LAN=0`, a valid `SV_REGION`, and **UDP `SERVER_PORT`
(27015) forwarded** from your router to the host.

- In a Steam client: **View → Servers → Internet**, filter for `SERVER_NAME`.
  It should appear within a few minutes.
- Connect from a Steam client on another network using `<public-ip>:27015`.

---

## 5. Restart / recreate / persistence

**Purpose:** the server survives restart and recreate, and the volume persists.

```bash
# leave a marker in the persistent volume
docker compose exec csserver sh -c 'echo test > /server/cstrike/persist-check.txt'

docker compose restart
docker compose exec csserver cat /server/cstrike/persist-check.txt   # -> test

docker compose down && docker compose up -d
docker compose exec csserver cat /server/cstrike/persist-check.txt   # -> test (volume kept)
```

On recreate the volume persists, so the server is **not** re-seeded. To get a
clean reset: `docker compose down`, delete the server's volume dir
(`./serverdata/default`), `docker compose up -d` — the logs then show
`first run — seeding` again.

---

## 6. Bot toggle

**Purpose:** `BOTS_ENABLED` controls YaPB.

```bash
# default (BOTS_ENABLED=true): YaPB is in the plugin list
docker compose exec csserver grep yapb \
  /server/cstrike/addons/metamod/plugins.ini        # -> line present

# disable
sed -i 's/^BOTS_ENABLED=.*/BOTS_ENABLED=false/' .env
docker compose up -d
docker compose exec csserver grep yapb \
  /server/cstrike/addons/metamod/plugins.ini        # -> no output
```

With bots enabled, joining the server shows YaPB bots filling slots; disabled,
none.

---

## 7. Reunion (optional)

Only if you set `REUNION_ENABLED=true`:

```bash
docker compose up -d
docker compose exec csserver grep reunion \
  /server/cstrike/addons/metamod/plugins.ini        # -> line present
docker compose exec csserver rcon "meta list"       # shows Reunion
```

---

## 8. YaPB config: baked perf, stock bot tuning

**Purpose:** our performance cvars are patched into `yapb.cfg` at build; bot
count/difficulty are left at YaPB defaults (not in `.env`); both live in
`yapb.cfg` and survive map changes. There is no `yapb-overlay.cfg`.

```bash
# server.cfg never sets yb_* — bot tuning is not env-driven:
docker compose exec csserver grep -c yb_quota /server/cstrike/server.cfg   # -> 0

# no overlay file, and yapb.cfg has no overlay exec hook:
docker compose exec csserver sh -c \
  'ls /server/cstrike/addons/yapb/conf/yapb-overlay.cfg 2>&1'             # -> No such file
docker compose exec csserver grep -c yapb-overlay /server/cstrike/addons/yapb/conf/yapb.cfg  # -> 0

# our perf cvars are baked into yapb.cfg:
docker compose exec csserver grep -E '^yb_think_fps' \
  /server/cstrike/addons/yapb/conf/yapb.cfg            # -> yb_think_fps "60.0"

# bot tuning is at YaPB stock defaults:
docker compose exec csserver grep -E '^yb_quota ' \
  /server/cstrike/addons/yapb/conf/yapb.cfg            # -> yb_quota "9"

# edit it live in yapb.cfg and reload the map; the new quota applies (no restart):
docker compose exec csserver sh -c \
  'sed -i "s/^yb_quota .*/yb_quota \"4\"/" /server/cstrike/addons/yapb/conf/yapb.cfg'
docker compose exec csserver rcon "changelevel de_dust2"
docker compose exec csserver rcon "yb_quota"          # -> 4
```

---

## 9. Multi-server fleet (optional)

**Purpose:** two servers run from the **one** built image, each fully independent.

**Preconditions:** image built (`docker compose build`); two env files with
**distinct** `SERVER_PORT` / `CLIENT_PORT`.

```bash
cp cstrike-01.env.example cstrike-01.env   # set RCON_PASSWORD; ports 27015/27005
cp cstrike-02.env.example cstrike-02.env   # set RCON_PASSWORD; ports 27016/27006
docker compose -f docker-compose.fleet.example.yml up -d
docker compose -f docker-compose.fleet.example.yml ps        # both Up
```

**Expect:**
- each server seeds its **own** volume on first start (`serverdata/cstrike-01`,
  `serverdata/cstrike-02`) — no shared state;
- each answers A2S on its own port:
  ```bash
  docker compose -f docker-compose.fleet.example.yml exec cstrike-01 /opt/cs16/healthcheck.sh
  docker compose -f docker-compose.fleet.example.yml exec cstrike-02 /opt/cs16/healthcheck.sh
  ```
- independent admin/state: set a different `OWNER` in each env file and confirm
  each server's `users.ini` carries its own owner block;
- **both** appear in the Steam Internet browser. If only one lists, check for a
  UDP 26900 (VAC/Steam port) clash — see the open note at the bottom of
  `docker-compose.fleet.example.yml`.
- clean shutdown per service: `docker compose -f docker-compose.fleet.example.yml stop cstrike-02`
  stops only #2; #1 keeps running.

---

## Done criteria checklist

- [ ] Image builds cleanly; SteamCMD install verified complete; SHA256 + the
      ReHLDS GPG check pass (Test 1)
- [ ] `docker compose up -d` yields a running, `healthy` server (Test 2)
- [ ] `meta list` shows Metamod-R and AMX Mod X; ReGameDLL + ReHLDS in the
      console banner (Test 3)
- [ ] Server appears in Steam's Internet browser and is joinable (Test 4)
- [ ] Server survives `restart` and `down`/`up`; the volume persists (Test 5)
- [ ] YaPB bots present iff `BOTS_ENABLED=true` (Test 6)
- [ ] Our perf cvars are baked into `yapb.cfg` (`yb_think_fps "60.0"`); bot
      count/difficulty are at YaPB stock defaults, not in `server.cfg`; a live
      `yapb.cfg` edit applies on the next changelevel (Test 8)
- [ ] Fleet: two servers run from one image, each with its own volume/ports, both
      list and answer A2S (Test 9)
