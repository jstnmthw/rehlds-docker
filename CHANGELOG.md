# Changelog

All component versions are pinned for reproducible builds. Floating tags
(`latest`, `master`) are deliberately not used. The one exception is the
download *location* of YaPB: upstream stopped tagging releases, so the asset
comes from its `continuous` release, but it is still pinned by its own build
number and SHA256 (see the 2026-10-15 change below).

## [Unreleased]

A Counter-Strike 1.6 dedicated server on the ReHLDS engine stack, assembled and
pinned at build time. Nothing is tagged yet — this section is the working
baseline and records the current pinned set and design.

### Changes

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
  container is still up, then `up -d`).
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

- Counter-Strike 1.6 = HLDS **appid 90**, installed from the **`steam_legacy`**
  SteamCMD branch (`STEAM_BRANCH` build arg).
- **Why `steam_legacy`:** the Half-Life 25th Anniversary update (Nov 2023)
  shipped a new HLDS whose `libsteam_api.so` no longer exports the legacy
  `SteamGameServer_Init` symbol that the ReHLDS engine imports — the engine
  fails to load with `undefined symbol: SteamGameServer_Init`. The
  `steam_legacy` branch is the pre-anniversary, ReHLDS-compatible HLDS.
- SteamCMD's appid-90 download is incremental and unreliable in a single pass;
  the build loops `app_update 90 -beta steam_legacy validate` until the install
  size stabilises and all sentinel files are present, then fails the build if
  it is still incomplete.

### Overlay components

All assets are from the official upstream GitHub Releases (no mirrors),
verified by SHA256; ReHLDS additionally verified by GPG signature.

| Component | Version | Asset & source URL | SHA256 |
|---|---|---|---|
| **ReHLDS** | 3.14.0.857 | [`rehlds-bin-3.14.0.857.zip`](https://github.com/rehlds/ReHLDS/releases/download/3.14.0.857/rehlds-bin-3.14.0.857.zip) | `8e0bb2b36c70896f94f1ab642eeed17dcc1b345045cf076aabd64a0a67a4b733` |
| **ReGameDLL_CS** | 5.28.0.756 | [`regamedll-bin-5.28.0.756.zip`](https://github.com/rehlds/ReGameDLL_CS/releases/download/5.28.0.756/regamedll-bin-5.28.0.756.zip) | `e9197ada843de6df4ed74cfe7b22bf5d93ba9e0c7b66490ca682120761978732` |
| **Metamod-R** | 1.3.0.149 | [`metamod-bin-1.3.0.149.zip`](https://github.com/rehlds/Metamod-R/releases/download/1.3.0.149/metamod-bin-1.3.0.149.zip) | `ede7f59c4e0220afe8c02aa348a130cce527f87d36ffdb674e37a501ce57be94` |
| **AMX Mod X** (base) | 1.10.0.5476 | [`amxmodx-1.10.0-git5476-base-linux.tar.gz`](https://github.com/alliedmodders/amxmodx/releases/download/1.10.0.5476/amxmodx-1.10.0-git5476-base-linux.tar.gz) | `cd99e956b02b4818324f3ed5a624d7cea8f00ef6593974bb97d912ae7591ec73` |
| **AMX Mod X** (cstrike) | 1.10.0.5476 | [`amxmodx-1.10.0-git5476-cstrike-linux.tar.gz`](https://github.com/alliedmodders/amxmodx/releases/download/1.10.0.5476/amxmodx-1.10.0-git5476-cstrike-linux.tar.gz) | `4af2ce169be4ffdd9a33be89d25f18967395b72433333aa900549d5bf0b4d508` |
| **ReAPI** | 5.26.0.338 | [`reapi-bin-5.26.0.338.zip`](https://github.com/rehlds/ReAPI/releases/download/5.26.0.338/reapi-bin-5.26.0.338.zip) | `0f39de7428aacd0fc6890eab0af62c616b592408dd7ab8e91aa53787fba9e08d` |
| **YaPB** | 4.8.1311 | [`yapb-4.8.1311-linux.tar.xz`](https://github.com/yapb/yapb/releases/download/continuous/yapb-4.8.1311-linux.tar.xz) (the `continuous` release; URL valid only until upstream's next push, see Changes) | `085653b21f9a395f2a443d35c65aa155a86618a3f67926dc3933ca527aa0aebb` |
| **Reunion** | 0.2.0.25 | [`reunion-0.2.0.25.zip`](https://github.com/rehlds/ReUnion/releases/download/0.2.0.25/reunion-0.2.0.25.zip) | `0f238276719274216bd169c578eac2db4e041946b8b9f0e407e41ef9d85efdf5` |

URLs confirmed reachable (HTTP 200); the ReHLDS-stack assets were resolved on
2026-05-15, AMX Mod X `1.10.0.5476` on 2026-05-31 and YaPB `4.8.1311` on
2026-10-15. These map to `ARG`s in the
`Dockerfile`.

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
  on every push. Its assets are versioned by build number
  (`yapb-<version>-linux.tar.xz`) and carry a GitHub SHA256 digest, so the
  Dockerfile pins `YAPB_VERSION` + `YAPB_SHA256` and uses `YAPB_TAG` only for
  the URL. To resolve the current build: open the `continuous` release, read
  the version from the Linux asset's file name and the SHA256 from its digest.
  The assets are GPG-signed (key `FC03F18A5E7DCE282A4B9D48194F2DA6C5F2FA24`),
  but that key is not published on keys.openpgp.org or the maintainer's GitHub
  keys, so YaPB is SHA256-only, as before.
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
  `ca-certificates`

### Architecture

- Multi-stage `Dockerfile`: stage 1 installs CS 1.6 and applies the ReHLDS
  stack; stage 2 is a lean runtime with the finished server baked in.
- `build-server.sh` — build-time SteamCMD install loop + component
  download/verify + assembly. Also patches `liblist.gam`, appends `reapi` to
  `modules.ini`, and rewrites the YaPB performance-cvar *values* in the stock
  `yapb.cfg` in place (bot tuning is left at YaPB's stock defaults, tuned in the
  live volume copy).
- `entrypoint.sh` — runtime: seed the volume on first run, render env-driven
  config, run HLDS as an unprivileged user. Set `OWNER` to the server owner's
  SteamID and it bootstraps that SteamID into AMX Mod X as a full admin via a
  container-managed marked block in `users.ini`; hand-added admins elsewhere are
  left untouched.
- `healthcheck.sh` — A2S-query healthcheck.
- `rcon` — minimal GoldSrc RCON client for admin commands.
- ReHLDS flood-protection defaults in `config/server.cfg`.
