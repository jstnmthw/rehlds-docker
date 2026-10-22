# Changelog

All component versions are pinned for reproducible builds. Floating tags
(`latest`, `master`) are deliberately not used. Components with a stable
upstream release URL are downloaded at build time and verified by SHA256
(ReHLDS also by GPG); the ones without — the bots — are vendored under
`vendor/` and pinned by file name + SHA256 (see "Vendored archives" below).

## [Unreleased]

GoldSrc dedicated servers — Counter-Strike 1.6, Team Fortress Classic and Day
of Defeat — on the ReHLDS engine stack, assembled and pinned at build time, one
image per game. Nothing is tagged yet — this section is the working baseline
and records the current pinned set and design.

### Changes

- **2026-10-22 — DoD's bot is Marine Bot 0.97 Beta; new_bot is gone.**
  new_bot 0.3.0 leaked resident memory at every map change on a live server
  (75 to 128 MiB over 32 changes in sixteen hours, the step growing from
  0.24 to 2.85 MiB per change on the second pass through the same 18 maps;
  flat once the plugin was unloaded). Marine Bot, the fallback the dod profile
  named, ran four days on the same server from a hand-built trial: 182 map
  changes, resident memory 70.6 MiB on the first map and 70.4 MiB on the last,
  although it kicks and re-adds its bots at every changelevel just as new_bot
  did. The dod image now ships Marine Bot (`vendor/mb097-dod.zip`) with
  Martee's waypoints for the official maps
  (`vendor/martee_dod_waypoint_pack_v2.zip`) and the bot's GPL source
  (`vendor/mb097b-dod-source.zip`, not used by the build). Details:
  - **Loading.** Marine Bot is a game-library wrapper, not a Metamod plugin:
    `liblist.gam` stays on Metamod and HLDS starts with `+localinfo mm_gamedll
    marinebot/marinebot.so`. A new optional profile variable,
    `GAME_BOT_START_PARAMS`, carries that parameter; the entrypoint adds it
    while `BOTS_ENABLED=true`, separately from `EXTRA_START_PARAMS`, so setting
    those never drops the bot. `config/dod/plugins.ini` has no `@bot@` line any
    more. cstrike and tfc are unchanged (the variable is empty or unset).
  - **Libraries.** `marinebot.so` needs `CXXABI_1.3.9`, which the depot's
    bundled 32-bit `libstdc++.so.6` predates, so the dod profile drops the
    bundled `libstdc++.so.6` / `libgcc_s.so.1` as the tfc profile does; the
    loader check covers `marinebot.so` as the bot library.
  - **Operator files.** `marinebot/marine.cfg` (`max_bots`, stock 6, and the
    `recruit` block), `marine_dog-tags.txt`, `mapcfgs/` and `customwpts/` are
    seeded once and never refreshed; `defaultwpts/` is image-owned like the
    other bots' waypoints. Marine Bot reads its config and names at start-up.
  - **Existing dod volumes** keep new_bot's files (the refresh never deletes);
    they are unused. A volume seeded by the new_bot image gets Marine Bot's
    stock `marine.cfg` (6 bots) on the first start of this image.
  - **Known noise.** Metamod-R logs `user message id reused: msgid=76,
    oldname=…, newname=ScoreInfoL` about ten times a minute: Marine Bot
    registers DoD's `ScoreInfoLong` as `ScoreInfoL` from a stack buffer
    (`engine.cpp`, `pfnRegUserMsg`), Metamod-R keeps the pointer, and later
    registrations compare against garbage. The message id is right; only the
    log line is affected. A bot name containing `..` comes out as `unnamed`
    (ReHLDS), and Marine Bot then keeps that name across maps.

- **2026-10-17 — Bans survive a restart (cstrike).** `config/cstrike/server.cfg`
  now `exec`s `listip.cfg` and `banned.cfg`, as the stock `server.cfg` it
  replaces did and as the new tfc / dod templates do. `amx_ban` / `amx_banip`
  (and `banid` / `addip`) write the lists to the volume via `writeid` /
  `writeip`, but GoldSrc only reloads them through those two lines — so far
  every Counter-Strike ban was in memory only and gone after a restart (the
  files were there; nothing read them). Neither ReGameDLL's `game_init.cfg` /
  `game.cfg` nor anything else in the tree loads them. On a fresh volume the
  first start logs `couldn't exec listip.cfg` / `banned.cfg` until the first
  `writeid` / `writeip` creates them; harmless.
- **2026-10-17 — One image family: `GAME` build argument, `tfc` and `dod`
  profiles, vendored bots, volume stack refresh.** The Counter-Strike-only
  image became a family — one Dockerfile, `--build-arg GAME=cstrike|tfc|dod`,
  one image per game tagged `rehlds-<game>:local` (the Counter-Strike image was
  `rehlds-csserver:local`). Everything game-specific moved out of
  `build-server.sh` / `entrypoint.sh` into `profiles/<game>.sh` (depot mod name,
  sentinels, AMX Mod X add-on + modules + plugins, bot, defaults, operator-owned
  files, fetch/apply hooks) and `config/<game>/{server.cfg,plugins.ini}`; the
  Metamod template's `@yapb@` tag is now `@bot@`. Regression check: a
  `GAME=cstrike` build before and after is byte-identical in every file's
  content and mode except `steamapps/appmanifest_*.acf` (SteamCMD's own
  bookkeeping: a timestamp, the anonymous account id, and the `mod cstrike`
  key that `+app_set_config 90 mod <game>` — now passed for every game — adds).
  Details:
  - **TFC and DoD** install from the same appid 90 / `steam_legacy` branch
    (`mod tfc`, `mod dod`; confirmed clean) and keep Valve's own game library
    (`tfc.so`, `dod.so`); they get the stock AMX Mod X `tfc` / `dod` add-ons
    with the `tfcx` / `dodx` + `dodfun` modules and the `stats`, `statssounds`
    and `stats_logging` plugins enabled by the build (they ship commented).
    Their `server.cfg` templates take the gameplay block from the stock
    `<game>/server.cfg` the depot ships and the add-on's `cvars.ini`; the
    ReHLDS, A2S, RCON, rate and logging sections are the Counter-Strike ones
    verbatim. No CS cvars carried over. The appid-90 depot always installs
    `cstrike/` alongside `valve/`, so the build trims any mod directory that is
    not the game's (280 MB per tfc/dod image, nothing for cstrike). Found while
    testing: the depot also bundles an old 32-bit `libstdc++.so.6` /
    `libgcc_s.so.1` at the server root, which `hlds_run` puts first on the
    library path, and Valve's `tfc.so` needs `CXXABI_1.3.8` that copy predates
    — Metamod died with "Failure to load game DLL". The tfc profile drops the
    bundled pair so the base image's `lib32stdc++6` is used (`cs.so` and
    `dod.so` are fine with the bundled one, so those trees are untouched), and
    `build-server.sh` now runs the 32-bit loader in trace mode over the game
    library, Metamod, AMX Mod X and its enabled modules, Reunion and the bot,
    failing the build on any unresolved dependency.
  - **One bot per game, behind `BOTS_ENABLED`:** YaPB (cstrike, as before),
    FoxBot 0.911 (tfc, Metamod plugin, 597 stock waypoints; its archive's
    bundled old Metamod and HTML docs are not shipped), new_bot 0.3.0 (dod,
    Metamod plugin in `dod/new_bot/`, 121 waypoints) plus the Sturmbot waypoint
    pack (743 waypoints under `dod/sturmbot/waypoints/`, new_bot's fallback).
    Bot tuning stays volume-seeded and operator-owned: `yapb.cfg`,
    `foxbot.cfg` (+ `default.cfg`, `configs/`), `new_bot.cfg` + `maps/`.
  - **Vendoring.** YaPB, FoxBot, new_bot and the waypoint pack live in
    `vendor/` (13 MB) and are referenced from the `Dockerfile` by file name
    (`*_ARCHIVE`) and SHA256; `fetch()` copies a vendored path instead of
    downloading, with the same digest check. This closes the YaPB `continuous`
    problem (its previous assets vanish on every upstream push): `YAPB_TAG` is
    gone, the pin is the file.
  - **Volume stack refresh (replaces `scripts/refresh-yapb.sh`).** The build
    now records `STACK-MANIFEST` — every file it added to or changed in the
    bare depot, with its SHA256 — and `VERSIONS` ends with a digest of it. The
    entrypoint keeps the image's `VERSIONS` as `/server/VERSIONS`; when it
    differs (or is missing, i.e. a volume seeded by an older image) it
    re-copies every manifest file from the image, except operator-owned files
    that already exist (`<game>/addons/amxmodx/configs/` and the profile's bot
    tuning files), touching nothing the image does not ship and deleting
    nothing. It also refuses a volume stamped for another game.
    `scripts/migrate-yapb-cfg.py` stays (yapb.cfg is operator-owned, so the
    refresh will not carry a YaPB bump into it).
  - `/opt/cs16` → `/opt/hlds` (healthcheck path in the compose templates).
    `GAME` is an `ENV` of the runtime image; the game's profile is baked as
    `/opt/hlds/profile.sh`. The image's `/server` is pre-created owned by uid
    1000 so a fresh named volume inherits it. Image labels: the shared stack
    (`rehlds`, `metamod`, `amxmodx`, `reunion`) plus `hlds.game`; the per-game
    `regamedll` / `reapi` / `yapb` labels are gone — `VERSIONS` is the record.
  - **Topology.** New `docker-compose.bridge.example.yml`: five services
    (`cstrike-01/02/03`, `tfc-01`, `dod-01`) on an external bridge network
    `gameservers`, one published UDP port each (`tfc-01` 27015, `cstrike-01/02/03`
    27016–27018, `dod-01` 27019; client ports 270NN − 10), `build:` on one
    service per image. New `cstrike-03`, `tfc-01` and `dod-01` env examples;
    `cstrike-01/02.env.example` renumbered to 27016/27017 so every template
    uses that one port map (the single-server `.env.example` keeps 27015). The
    env keys are identical for every game; `DEFAULT_MAP`, `MAX_PLAYERS` and
    `EXTRA_START_PARAMS` default from the profile (`de_dust2`/16/`-pingboost 1
    +sys_ticrate 1000`; `well`/32/none; `dod_anzio`/32/none).
- **2026-10-15 — YaPB 4.4.957 → 4.8.1311 (`continuous` build of 2026-10-14,
  master bffaa0b).** Upstream has not tagged a release since 4.4.957
  (2024-02-10); the `continuous` release is rebuilt from master on every push,
  but every build carries its own version in the asset name and a GitHub SHA256
  digest, so the pin is `YAPB_VERSION` + `YAPB_SHA256` as before, plus
  `YAPB_TAG=continuous` for the download URL. Caveat: upstream deletes the
  previous assets on the next push, so a later `--no-cache` rebuild fails at
  the fetch until both are bumped to the current build (digest from the
  release's asset list). Why: 4.4.957 saves bot practice data with a quadratic
  array copy at every level change; a 24/7 single-map server reached a 25–37 s
  one-core freeze per map change (diagnosed 2026-10-15). 4.8 rewrote that
  storage. Side effects: `yb_graph_analyze_fps` no longer exists (its
  `yapb_set` line is gone; 10 cvars removed, 22 added in `yapb.cfg`), and the
  practice (`.prc`, v2→v6) and vistable (`.vis`, v3→v5) files are rejected once
  ("Damaged ... Version number differs") and regenerated; graph files (v2) load
  unchanged. `yapb.cfg` lives in the volume and is seeded once, so
  `scripts/migrate-yapb-cfg.py <name>` rewrites it from the new image's stock
  file with the operator's tuned values carried over (run while the old
  container is still up, then `up -d`). **The rebuilt image alone does not
  upgrade an existing server:** the entrypoint seeds `/server` once and never
  refreshes it, so HLDS keeps loading the old `addons/yapb/bin/yapb.so` from
  the volume (found 2026-10-15, when all three fleet members logged "YaPB
  v4.4.957" from the new image). `scripts/refresh-yapb.sh <name>` copied the
  image's `addons/yapb` tree into the volume as a stopgap; the general stack
  refresh of 2026-10-17 (above) replaced it.
- **2026-10-13 — Runs with no root process.** The compose templates now start
  the container as the image's `steam` user (`user: "1000:1000"`) with every
  capability dropped and `no-new-privileges`. `entrypoint.sh` detects a
  non-root start and skips its chown / `gosu` step, running HLDS as that user
  directly; started as root (the image default) it behaves as before. A
  brand-new `./serverdata/<name>` volume must be owned by uid 1000 before the
  first start (an existing one already is, from its earlier root starts).

### Base image

| Image | Digest |
|---|---|
| `cm2network/steamcmd` | `sha256:45f6515d6c4dcde659c9ad6872bdbeacd1bf5c4e7f241829c4d2f28fb5eda581` |

Resolved 2026-05-15; pinned by **digest** in the `Dockerfile` (`BASE_DIGEST`).
A clean Debian-based SteamCMD image with the 32-bit libraries GoldSrc needs.

### HLDS / SteamCMD

- Every game = HLDS **appid 90** with `+app_set_config 90 mod <game>`
  (`cstrike`, `tfc`, `dod`), installed from the **`steam_legacy`** SteamCMD
  branch (`STEAM_BRANCH` build arg). The base install always includes
  `valve/` and `cstrike/`; the build trims the mods the image is not for.
- **Why `steam_legacy`:** the Half-Life 25th Anniversary update (Nov 2023)
  shipped a new HLDS whose `libsteam_api.so` no longer exports the legacy
  `SteamGameServer_Init` symbol that the ReHLDS engine imports — the engine
  fails to load with `undefined symbol: SteamGameServer_Init`. The
  `steam_legacy` branch is the pre-anniversary, ReHLDS-compatible HLDS.
- SteamCMD's appid-90 download is incremental and unreliable in a single pass;
  the build loops `app_update 90 -beta steam_legacy validate` until the install
  size stabilises and all sentinel files are present, then fails the build if
  it is still incomplete.

### Downloaded components

Fetched at build time from the official upstream GitHub Releases (no mirrors),
verified by SHA256; ReHLDS additionally verified by GPG signature. "Games"
says which images apply the component.

| Component | Version | Games | Asset & source URL | SHA256 |
|---|---|---|---|---|
| **ReHLDS** | 3.14.0.857 | all | [`rehlds-bin-3.14.0.857.zip`](https://github.com/rehlds/ReHLDS/releases/download/3.14.0.857/rehlds-bin-3.14.0.857.zip) | `8e0bb2b36c70896f94f1ab642eeed17dcc1b345045cf076aabd64a0a67a4b733` |
| **Metamod-R** | 1.3.0.149 | all | [`metamod-bin-1.3.0.149.zip`](https://github.com/rehlds/Metamod-R/releases/download/1.3.0.149/metamod-bin-1.3.0.149.zip) | `ede7f59c4e0220afe8c02aa348a130cce527f87d36ffdb674e37a501ce57be94` |
| **AMX Mod X** (base) | 1.10.0.5476 | all | [`amxmodx-1.10.0-git5476-base-linux.tar.gz`](https://github.com/alliedmodders/amxmodx/releases/download/1.10.0.5476/amxmodx-1.10.0-git5476-base-linux.tar.gz) | `cd99e956b02b4818324f3ed5a624d7cea8f00ef6593974bb97d912ae7591ec73` |
| **AMX Mod X** (cstrike add-on) | 1.10.0.5476 | cstrike | [`amxmodx-1.10.0-git5476-cstrike-linux.tar.gz`](https://github.com/alliedmodders/amxmodx/releases/download/1.10.0.5476/amxmodx-1.10.0-git5476-cstrike-linux.tar.gz) | `4af2ce169be4ffdd9a33be89d25f18967395b72433333aa900549d5bf0b4d508` |
| **AMX Mod X** (tfc add-on) | 1.10.0.5476 | tfc | [`amxmodx-1.10.0-git5476-tfc-linux.tar.gz`](https://github.com/alliedmodders/amxmodx/releases/download/1.10.0.5476/amxmodx-1.10.0-git5476-tfc-linux.tar.gz) | `b5a0d30a353e7150ef9ce4d6b8eb416fde98aeefb7ba671924517e3c34b205a4` |
| **AMX Mod X** (dod add-on) | 1.10.0.5476 | dod | [`amxmodx-1.10.0-git5476-dod-linux.tar.gz`](https://github.com/alliedmodders/amxmodx/releases/download/1.10.0.5476/amxmodx-1.10.0-git5476-dod-linux.tar.gz) | `5e1b5b1331a744ab63bf85f33eb343a4e29cdf899cd6e3922ca4aa9237c3061c` |
| **Reunion** | 0.2.0.25 | all | [`reunion-0.2.0.25.zip`](https://github.com/rehlds/ReUnion/releases/download/0.2.0.25/reunion-0.2.0.25.zip) | `0f238276719274216bd169c578eac2db4e041946b8b9f0e407e41ef9d85efdf5` |
| **ReGameDLL_CS** | 5.28.0.756 | cstrike | [`regamedll-bin-5.28.0.756.zip`](https://github.com/rehlds/ReGameDLL_CS/releases/download/5.28.0.756/regamedll-bin-5.28.0.756.zip) | `e9197ada843de6df4ed74cfe7b22bf5d93ba9e0c7b66490ca682120761978732` |
| **ReAPI** | 5.26.0.338 | cstrike | [`reapi-bin-5.26.0.338.zip`](https://github.com/rehlds/ReAPI/releases/download/5.26.0.338/reapi-bin-5.26.0.338.zip) | `0f39de7428aacd0fc6890eab0af62c616b592408dd7ab8e91aa53787fba9e08d` |

URLs confirmed reachable (HTTP 200); the ReHLDS-stack assets were resolved on
2026-05-15, AMX Mod X `1.10.0.5476` (base, cstrike) on 2026-05-31 and its tfc /
dod add-ons on 2026-10-17. These map to `ARG`s in the `Dockerfile`.

### Vendored archives

Kept in `vendor/` because upstream offers no stable, versioned download URL.
Each is referenced from the `Dockerfile` by file name (`*_ARCHIVE`) and
SHA256; `build-server.sh` verifies the digest exactly as for a download. The
upstream URL is where the file came from, on the date given.

| Archive (`vendor/`) | Component | Games | Upstream URL | Downloaded | SHA256 |
|---|---|---|---|---|---|
| `yapb-4.8.1311-linux.tar.xz` | **YaPB** 4.8.1311 (`continuous` build of 2026-10-14, master bffaa0b) | cstrike | `https://github.com/yapb/yapb/releases/download/continuous/yapb-4.8.1311-linux.tar.xz` (asset deleted by upstream's next push) | 2026-10-17 | `085653b21f9a395f2a443d35c65aa155a86618a3f67926dc3933ca527aa0aebb` |
| `foxbot_0911.zip` | **FoxBot** 0.911 (GitHub release `v0.911` of 2024-12-23, APGRoboCop/foxbot) | tfc | `https://github.com/APGRoboCop/foxbot/releases/download/v0.911/foxbot_0911.zip` | 2026-10-17 | `eea631c7c1a1ca59af915c8f63cb6fbcd8cc4d7008f490b9a2c0ab175d5cb25a` |
| `mb097-dod.zip` | **Marine Bot** 0.97 Beta, DoD edition (`marinebot.so` of 2025-01-30; GPL; upstream name `mb097(DOD).zip`) | dod | `https://sourceforge.net/projects/marinebot/files/Marinebot/Marine%20Bot%200.97%20Beta/mb097%28DOD%29.zip/download` | 2026-10-18 | `783994f80543156eec4872ca67ee473c4c2df9665bac226177d6281d500cb497` |
| `martee_dod_waypoint_pack_v2.zip` | **Martee's DoD waypoint pack for Marine Bot**, v2 (2025-12-30; a `.wpt` and a `.pth` for each official map, one custom map) | dod | `https://downloads.sturmbot.org/marine_bot/marine_bot_waypoint_packs/martee_dod_waypoint_pack_v2.zip` | 2026-10-18 | `8ac386ac42efdb0be36c1adefa46862ea2b6cdd4b4b0325c37f434f41f5ea71e` |
| `mb097b-dod-source.zip` | **Marine Bot 0.97b DoD source** (GPL; upstream name `mb097b(DOD)_sc.zip`, uploaded 2026-01-03). Kept as the corresponding source of the shipped binary; not used by the build | dod | `https://downloads.sourceforge.net/project/marinebot/Marinebot%20Sourcecode/Marine%20Bot%200.97%20Sourcecode/mb097b%28DOD%29_sc.zip` | 2026-10-22 | `46ebdb3ff97684527031a39b500e545ee40357f5edc399d5cb9480d5ae6e903b` |

Until 2026-10-22 the dod image shipped new_bot 0.3.0
(`new_bot-0.3.0.zip`, SHA256
`dcd5b3c9240ecca8e11d3a226e132a5c4480bf5eff9ff2acca3348d92d3922e9`) and the
Sturmbot waypoint pack for it
(`sturmbot_4_new_bot_waypoints-2026-10-04.zip`, SHA256
`8d4466b30a8eede273a3566cd40cbb7b4c068d7565b7c74f8a6984bd31a77c14`); both are
no longer referenced by the `Dockerfile`.

### Pinned set per image

| | `rehlds-cstrike` | `rehlds-tfc` | `rehlds-dod` |
|---|---|---|---|
| Depot | appid 90, `mod cstrike`, `steam_legacy` | appid 90, `mod tfc`, `steam_legacy` | appid 90, `mod dod`, `steam_legacy` |
| ReHLDS / Metamod-R / Reunion | 3.14.0.857 / 1.3.0.149 / 0.2.0.25 | same | same |
| AMX Mod X | 1.10.0.5476 base + cstrike | 1.10.0.5476 base + tfc | 1.10.0.5476 base + dod |
| Game library | ReGameDLL_CS 5.28.0.756 (+ ReAPI 5.26.0.338) | Valve's `tfc.so` | Valve's `dod.so` |
| Bot | YaPB 4.8.1311 | FoxBot 0.911 | Marine Bot 0.97b + Martee's waypoints v2 |

The image's `/opt/hlds/VERSIONS` lists exactly this, plus a digest of the
stack manifest.

### Version resolution notes

- **ReAPI** repository moved from `s1lentq/reapi` to
  [`rehlds/ReAPI`](https://github.com/rehlds/ReAPI).
- **Reunion** repository is [`rehlds/ReUnion`](https://github.com/rehlds/ReUnion).
  `0.2.0.25` is the latest *stable* release (`0.2.0.34` is a pre-release).
- **AMX Mod X**: `1.10.0.5476` is the latest *stable* (non-prerelease) build.
  The base and cstrike Linux assets share the `AMXX_VERSION` / `AMXX_BUILD` ARGs
  and are pinned together. Metamod-R and ReAPI are compatible with AMX Mod X 1.10.
- **YaPB**: `4.4.957` (2024-02-10) is still the last tagged release; upstream
  now publishes only the rolling `continuous` pre-release, rebuilt from master
  on every push, whose previous assets vanish on the next push. The pinned
  build is therefore vendored (`vendor/yapb-<version>-linux.tar.xz`); to bump
  it, download the current `continuous` Linux asset, check its SHA256 against
  the release's digest, drop it in `vendor/` and update `YAPB_VERSION`,
  `YAPB_ARCHIVE` and `YAPB_SHA256`. The assets are GPG-signed (key
  `FC03F18A5E7DCE282A4B9D48194F2DA6C5F2FA24`), but that key is not published on
  keys.openpgp.org or the maintainer's GitHub keys, so YaPB is SHA256-only.
- **FoxBot**: 0.911 (2024-12-23) is the latest release; a `v1.0-beta2`
  prototype exists upstream and is not used. The zip bundles an old Metamod
  (`addons/metamod/`) and HTML documentation, neither of which is shipped.
- **Marine Bot**: 0.97 Beta (binary 2025-01-30, source uploaded 2026-01-03)
  is the latest release on SourceForge; the project ships no waypoints for
  DoD 1.3, hence Martee's pack. Loaded through Metamod's `mm_gamedll`
  override, as its readme says for Linux dedicated servers.
- **AMX Mod X add-ons**: the `tfc` and `dod` tarballs ship their own
  `configs/{core,cvars,maps,modules,plugins}.ini`, which overwrite the base
  ones when extracted after the base tarball — the same order the `cstrike`
  add-on uses.
- **ReHLDS**: the `rehlds-bin` release asset ships the default ("bugfixed")
  engine build.

### GPG verification

- ReHLDS releases are GPG-signed by **ReHLDS Team `<team@rehlds.dev>`**, key
  fingerprint `63547829004F07716F7BE4856C32C4282E60FB67` (Ed25519).
- The public key is vendored at `config/rehlds-signing-key.asc` so the build
  does not depend on keyserver availability. The build imports it, asserts the
  fingerprint, and runs `gpg --verify` on the ReHLDS release. Verified OK on
  2026-05-15.
- Set `--build-arg GPG_VERIFY=false` to skip this if GitHub is unreachable at
  build time; SHA256 verification always runs.
- The other components publish no detached signatures; they are pinned and
  verified by SHA256.

### apt packages

Installed on top of the base image, without a strict version pin (leaf
packages from the Debian repos):

- build stage: `curl`, `ca-certificates`, `unzip`, `xz-utils`, `gnupg`
- runtime stage: `python3` (healthcheck + `rcon`), `gosu` (privilege drop),
  `ca-certificates`. The build stage's `python3` also runs
  `stack-manifest.py`.

### Architecture

- Multi-stage `Dockerfile`, `GAME` build argument: stage 1 installs the game
  and applies the ReHLDS stack as `profiles/<game>.sh` describes; stage 2 is a
  lean runtime with the finished server, `VERSIONS`, `STACK-MANIFEST`, the
  profile and the game's templates baked in under `/opt/hlds`.
- `build-server.sh` — shared build-time SteamCMD install loop + component
  fetch/verify + assembly, snapshotting the depot before and after to write
  the stack manifest. Patches `liblist.gam`, appends the profile's modules to
  `modules.ini`, uncomments the profile's stock plugins in AMXX `plugins.ini`,
  trims unused depot mods and strips `.dll` / `.exe` files. The cstrike
  profile rewrites the YaPB performance-cvar *values* in the stock `yapb.cfg`
  in place (bot tuning is left at YaPB's stock defaults, tuned in the live
  volume copy).
- `entrypoint.sh` — runtime: seed the volume on first run, refresh the
  stack-owned files when the image's stack changed, render env-driven config,
  run HLDS as an unprivileged user. Set `OWNER` to the server owner's SteamID
  and it bootstraps that SteamID into AMX Mod X as a full admin via a
  container-managed marked block in `users.ini`; hand-added admins elsewhere are
  left untouched.
- `healthcheck.sh` — A2S-query healthcheck.
- `rcon` — minimal GoldSrc RCON client for admin commands.
- ReHLDS flood-protection defaults in every `config/<game>/server.cfg`.
