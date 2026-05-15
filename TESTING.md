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
clean reset: `docker compose down`, delete `DATA_DIR`, `docker compose up -d` —
the logs then show `first run — seeding` again.

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

## Done criteria checklist

- [ ] Image builds cleanly; SteamCMD install verified complete; SHA256 + the
      ReHLDS GPG check pass (Test 1)
- [ ] `docker compose up -d` yields a running, `healthy` server (Test 2)
- [ ] `meta list` shows Metamod-R and AMX Mod X; ReGameDLL + ReHLDS in the
      console banner (Test 3)
- [ ] Server appears in Steam's Internet browser and is joinable (Test 4)
- [ ] Server survives `restart` and `down`/`up`; the volume persists (Test 5)
- [ ] YaPB bots present iff `BOTS_ENABLED=true` (Test 6)
