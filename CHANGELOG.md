# Changelog

All component versions are pinned for reproducible builds. Floating tags
(`latest`, `master`, `continuous`) are deliberately not used.

## [1.0.0] — 2026-05-15

Initial release: a Counter-Strike 1.6 dedicated server on the ReHLDS engine
stack, assembled and pinned at build time.

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
| **AMX Mod X** (base) | 1.9.0.5303 | [`amxmodx-1.9.0-git5303-base-linux.tar.gz`](https://github.com/alliedmodders/amxmodx/releases/download/1.9.0.5303/amxmodx-1.9.0-git5303-base-linux.tar.gz) | `1ed6898ced2c1fcf225c288b94effc19917e987b284e42911587738ee3c93699` |
| **AMX Mod X** (cstrike) | 1.9.0.5303 | [`amxmodx-1.9.0-git5303-cstrike-linux.tar.gz`](https://github.com/alliedmodders/amxmodx/releases/download/1.9.0.5303/amxmodx-1.9.0-git5303-cstrike-linux.tar.gz) | `a2a5ef44bb366a90adf432c708ac49eb63b4b44d7b0de123e8cd52395d27b8e9` |
| **ReAPI** | 5.26.0.338 | [`reapi-bin-5.26.0.338.zip`](https://github.com/rehlds/ReAPI/releases/download/5.26.0.338/reapi-bin-5.26.0.338.zip) | `0f39de7428aacd0fc6890eab0af62c616b592408dd7ab8e91aa53787fba9e08d` |
| **YaPB** | 4.4.957 | [`yapb-4.4.957-linux.tar.xz`](https://github.com/yapb/yapb/releases/download/4.4.957/yapb-4.4.957-linux.tar.xz) | `8c095ac89b9b2ccc70a66a71d608e1a570b5268c57c6083ced8c06161533a4b1` |
| **Reunion** | 0.2.0.25 | [`reunion-0.2.0.25.zip`](https://github.com/rehlds/ReUnion/releases/download/0.2.0.25/reunion-0.2.0.25.zip) | `0f238276719274216bd169c578eac2db4e041946b8b9f0e407e41ef9d85efdf5` |

All versions resolved and the URLs confirmed reachable (HTTP 200) on
2026-05-15. These map to `ARG`s in the `Dockerfile`.

### Version resolution notes

- **ReAPI** repository moved from `s1lentq/reapi` to
  [`rehlds/ReAPI`](https://github.com/rehlds/ReAPI).
- **Reunion** repository is [`rehlds/ReUnion`](https://github.com/rehlds/ReUnion).
  `0.2.0.25` is the latest *stable* release (`0.2.0.34` is a pre-release).
- **AMX Mod X**: `1.9.0.5303` is the latest *stable* (non-prerelease) build.
- **YaPB**: `4.4.957` is the latest stable release (the rolling `continuous`
  pre-release tag is avoided).
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
  download/verify + assembly.
- `entrypoint.sh` — runtime: seed the volume on first run, render env-driven
  config, run HLDS as an unprivileged user.
- `healthcheck.sh` — A2S-query healthcheck.
- `rcon` — minimal GoldSrc RCON client for admin commands.
- ReHLDS flood-protection defaults in `config/server.cfg`.
