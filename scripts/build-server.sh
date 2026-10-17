#!/usr/bin/env bash
#
# build-server.sh — runs INSIDE the Docker build (stage: server-builder).
#
# Produces a complete, ReHLDS-ified GoldSrc dedicated server tree for ONE game
# at /build/serverfiles, which the runtime stage bakes into the image. The game
# is the GAME build argument (cstrike, tfc, dod): this script is game-agnostic
# and sources profiles/<GAME>.sh for everything game-specific — the depot mod
# name, the sentinel files, the AMX Mod X add-on and the modules / plugins to
# enable in it, the bot, and the extra stack components the game needs
# (ReGameDLL_CS and ReAPI for Counter-Strike).
#
# Three phases:
#   1. Install the game (HLDS appid 90, mod ${GAME_MOD}) via SteamCMD, from the
#      "steam_legacy" branch — the pre-25th-anniversary HLDS that ReHLDS is
#      compatible with. SteamCMD's appid-90 download is notoriously incremental,
#      so this loops until the install size stabilises and all sentinel files
#      are present.
#   2. Fetch every stack component — a pinned GitHub release download, or a
#      vendored archive from /build/vendor for components with no stable
#      upstream URL — verify it (SHA256 for all, GPG for ReHLDS), and apply it
#      onto the installed serverfiles. The shared stack (ReHLDS, Metamod-R,
#      AMX Mod X base + the game's add-on, Reunion) is applied here; the
#      game-specific parts by the profile's profile_apply hook.
#   3. Record what the build changed: VERSIONS (the pinned set, printed by the
#      entrypoint banner) and STACK-MANIFEST (every file the stack added to or
#      replaced in the bare depot, with its SHA256). The entrypoint uses the
#      manifest to refresh an existing volume when a rebuilt image changes the
#      stack, and VERSIONS to notice that it did.
#
# Because the stack is applied here, at build time, the running container never
# needs to re-apply anything: SteamCMD is never run again.
#
set -euo pipefail

SF=/build/serverfiles          # the server tree being assembled
DL=/build/dl                   # fetched stack component archives
TMP=/build/extract             # scratch extraction dir
CURATED=/build/curated         # repo-provided files baked in
VENDOR=/build/vendor           # repo-vendored archives (vendor/)
GH="https://github.com"
STEAMCMD="${STEAMCMDDIR:-/home/steam/steamcmd}/steamcmd.sh"

mkdir -p "$SF" "$DL"
note() { echo ">>> $*"; }

# --- game profile ------------------------------------------------------------
GAME="${GAME:?GAME build argument not set}"
PROFILE="/build/profiles/${GAME}.sh"
[[ -f "${PROFILE}" ]] || { echo "FATAL: no profile for GAME=${GAME} (${PROFILE})" >&2; exit 1; }
# shellcheck source=/dev/null
source "${PROFILE}"
for v in GAME_TITLE GAME_MOD GAME_BOT GAME_AMXX_ADDON GAME_LIBRARY GAME_BOT_LIBRARY; do
  [[ -n "${!v:-}" ]] || { echo "FATAL: profile ${PROFILE} does not set ${v}" >&2; exit 1; }
done
note "building ${GAME_TITLE} (GAME=${GAME}, mod ${GAME_MOD}, bot ${GAME_BOT})"

# =============================================================================
# Phase 1 — install HLDS appid 90 (steam_legacy branch) via SteamCMD.
# =============================================================================
note "installing ${GAME_TITLE} (appid 90, mod ${GAME_MOD}, branch ${STEAM_BRANCH}) via SteamCMD"

sentinels=(hlds_run hlds_linux engine_i486.so "${GAME_SENTINELS[@]}")
sentinels_present() {
  local f
  for f in "${sentinels[@]}"; do [[ -f "${SF}/${f}" ]] || return 1; done
  [[ -n "$(find "${SF}" -name 'gfx.wad' -print -quit 2>/dev/null)" ]]
}

prev_size=-1
stable=0
complete=0
for run in $(seq 1 30); do
  echo "--- SteamCMD pass ${run} ---"
  # appid-90 installs are flaky; tolerate a non-zero exit and let the loop retry.
  "${STEAMCMD}" +force_install_dir "${SF}" \
                +login anonymous \
                +app_set_config 90 mod "${GAME_MOD}" \
                +app_update 90 -beta "${STEAM_BRANCH}" validate \
                +quit || echo "(SteamCMD pass ${run} exited non-zero — will re-check)"

  size=$(du -sb "${SF}" 2>/dev/null | cut -f1 || echo 0)
  echo "    install size after pass ${run}: ${size} bytes"

  if [[ "${size}" == "${prev_size}" && "${size}" != "0" ]]; then
    stable=$((stable + 1))
  else
    stable=0
  fi
  prev_size="${size}"

  # "Complete" = size held steady across two passes AND the sentinels exist.
  if [[ "${stable}" -ge 2 ]] && sentinels_present; then
    complete=1
    note "install complete and verified after ${run} pass(es)"
    break
  fi
done

if [[ "${complete}" -ne 1 ]]; then
  echo "FATAL: SteamCMD did not produce a complete ${GAME_TITLE} install." >&2
  echo "       Missing sentinels:" >&2
  for f in "${sentinels[@]}"; do
    [[ -f "${SF}/${f}" ]] || echo "         - ${f}" >&2
  done
  [[ -n "$(find "${SF}" -name 'gfx.wad' -print -quit 2>/dev/null)" ]] \
    || echo "         - gfx.wad (anywhere)" >&2
  exit 1
fi

# Trim the 64-bit HLDS variant — this image runs the 32-bit ReHLDS engine.
rm -rf "${SF}/linux64" 2>/dev/null || true

# Trim the other mods the appid-90 depot drags in: `app_update 90` always
# installs cstrike/ alongside valve/, so a tfc or dod image would carry an
# unused 280 MB Counter-Strike tree (and seed it into every volume). Any mod
# directory (one with a liblist.gam) other than this game's and the shared
# valve/ base goes. A cstrike build has nothing to trim, so its tree is unchanged.
for moddir in "${SF}"/*/; do
  moddir="${moddir%/}"
  name="${moddir##*/}"
  [[ -f "${moddir}/liblist.gam" ]] || continue
  [[ "${name}" == "${GAME_MOD}" || "${name}" == "valve" ]] && continue
  note "trimming unused depot mod ${name}/ ($(du -sh "${moddir}" | cut -f1))"
  rm -rf "${moddir}"
done

# Snapshot the bare depot: the stack manifest (phase 3) is everything that
# differs from this after the stack is applied.
note "snapshotting the bare depot for the stack manifest"
python3 /build/stack-manifest.py snapshot "${SF}" > /build/depot.sha256
echo "    $(wc -l < /build/depot.sha256) depot files"

# =============================================================================
# Phase 2 — fetch, verify and apply the ReHLDS stack.
# =============================================================================
# fetch <name> <source> <sha256>: <source> is an https:// release URL, or the
# absolute path of a vendored archive under ${VENDOR} (copied instead of
# downloaded). Either way the SHA256 is checked the same way and a mismatch
# fails the build.
fetch() {
  local name="$1" src="$2" sha="$3"
  if [[ "${src}" == /* ]]; then
    [[ -f "${src}" ]] || { echo "FATAL: vendored archive missing: ${src}" >&2; exit 1; }
    note "using vendored ${name} (${src#"${VENDOR}"/})"
    cp "${src}" "${DL}/${name}"
  else
    note "downloading ${name}"
    curl --fail --silent --show-error --location \
         --retry 4 --retry-delay 3 --connect-timeout 30 \
         -o "${DL}/${name}" "${src}"
  fi
  echo "${sha}  ${DL}/${name}" | sha256sum --check --strict
  echo "    sha256 OK  ${name}"
}
reset_tmp() { rm -rf "${TMP}"; mkdir -p "${TMP}"; }

# --- ReHLDS — engine. SHA256 + GPG. -----------------------------------------
fetch "rehlds.zip" \
  "${GH}/rehlds/ReHLDS/releases/download/${REHLDS_VERSION}/rehlds-bin-${REHLDS_VERSION}.zip" \
  "${REHLDS_SHA256}"

if [[ "${GPG_VERIFY,,}" == "true" ]]; then
  note "GPG-verifying the ReHLDS release signature"
  curl --fail --silent --show-error --location --retry 4 --connect-timeout 30 \
       -o "${DL}/rehlds.zip.asc" \
       "${GH}/rehlds/ReHLDS/releases/download/${REHLDS_VERSION}/rehlds-bin-${REHLDS_VERSION}.zip.asc"
  GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
  gpg --batch --quiet --import "${CURATED}/rehlds-signing-key.asc"
  if ! gpg --batch --with-colons --fingerprint \
       | grep -Eq "^fpr:+${REHLDS_GPG_FINGERPRINT}:"; then
    echo "FATAL: vendored signing key is not the expected ReHLDS key" >&2
    exit 1
  fi
  gpg --batch --verify "${DL}/rehlds.zip.asc" "${DL}/rehlds.zip"
  echo "    GPG signature OK  ReHLDS"
else
  note "GPG verification DISABLED (GPG_VERIFY=${GPG_VERIFY})"
fi

# --- the shared stack — SHA256 only. ----------------------------------------
fetch "metamod.zip" \
  "${GH}/rehlds/Metamod-R/releases/download/${METAMOD_VERSION}/metamod-bin-${METAMOD_VERSION}.zip" \
  "${METAMOD_SHA256}"
fetch "amxx-base.tar.gz" \
  "${GH}/alliedmodders/amxmodx/releases/download/${AMXX_VERSION}.${AMXX_BUILD}/amxmodx-${AMXX_VERSION}-git${AMXX_BUILD}-base-linux.tar.gz" \
  "${AMXX_BASE_SHA256}"
# The game add-on (cstrike / tfc / dod) is pinned by its own AMXX_<ADDON>_SHA256.
amxx_addon_sha_var="AMXX_${GAME_AMXX_ADDON^^}_SHA256"
fetch "amxx-${GAME_AMXX_ADDON}.tar.gz" \
  "${GH}/alliedmodders/amxmodx/releases/download/${AMXX_VERSION}.${AMXX_BUILD}/amxmodx-${AMXX_VERSION}-git${AMXX_BUILD}-${GAME_AMXX_ADDON}-linux.tar.gz" \
  "${!amxx_addon_sha_var}"
fetch "reunion.zip" \
  "${GH}/rehlds/ReUnion/releases/download/${REUNION_VERSION}/reunion-${REUNION_VERSION}.zip" \
  "${REUNION_SHA256}"

# --- the game's own components (profile) -----------------------------------
profile_fetch

# --- apply onto the serverfiles ---------------------------------------------
note "applying the ReHLDS stack onto the serverfiles"
GAMEDIR="${SF}/${GAME_MOD}"

# ReHLDS: bin/linux32/* -> server root (engine_i486.so, hlds_linux, support libs).
reset_tmp
unzip -q "${DL}/rehlds.zip" -d "${TMP}"
cp -a "${TMP}"/bin/linux32/. "${SF}"/

# Metamod-R: addons/metamod/* -> <game>/addons/metamod/
reset_tmp
unzip -q "${DL}/metamod.zip" -d "${TMP}"
mkdir -p "${GAMEDIR}/addons/metamod"
cp -a "${TMP}"/addons/metamod/. "${GAMEDIR}"/addons/metamod/

# AMX Mod X: base then the game add-on (its configs/*.ini overwrite the base ones).
tar -xzf "${DL}/amxx-base.tar.gz"                -C "${GAMEDIR}/"
tar -xzf "${DL}/amxx-${GAME_AMXX_ADDON}.tar.gz"  -C "${GAMEDIR}/"

# Reunion: the Linux Metamod plugin -> <game>/addons/reunion/
reset_tmp
unzip -q "${DL}/reunion.zip" -d "${TMP}"
mkdir -p "${GAMEDIR}/addons/reunion"
cp -a "${TMP}"/bin/Linux/reunion_mm_i386.so "${GAMEDIR}"/addons/reunion/

# The game's own components: game library replacement, extra AMXX modules, bot.
profile_apply

# --- patch liblist.gam so HLDS loads Metamod --------------------------------
LIBLIST="${GAMEDIR}/liblist.gam"
MM='addons/metamod/metamod_i386.so'
if grep -q '^gamedll_linux' "${LIBLIST}"; then
  sed -i "s#^gamedll_linux .*#gamedll_linux \"${MM}\"#" "${LIBLIST}"
else
  printf 'gamedll_linux "%s"\n' "${MM}" >> "${LIBLIST}"
fi
note "patched liblist.gam: gamedll_linux -> ${MM}"

# --- enable required AMX Mod X modules --------------------------------------
# Most modules (fun, engine, fakemeta, hamsandwich, …) auto-load only when a
# loaded plugin calls their natives. The game module (cstrike / tfcx / dodx …)
# is shipped but no stock plugin that is enabled by default uses it, so it never
# auto-loads — enable it explicitly. Third-party modules (reapi) are likewise
# not auto-listed. A module is appended as its own line unless an uncommented
# line already enables it (the stock ";name" entries stay as they are).
MODULES_INI="${GAMEDIR}/addons/amxmodx/configs/modules.ini"
if [[ -f "${MODULES_INI}" ]]; then
  for mod in "${GAME_AMXX_MODULES[@]}"; do
    if ! grep -Eqx "[[:space:]]*${mod}[[:space:]]*" "${MODULES_INI}"; then
      printf '%s\n' "${mod}" >> "${MODULES_INI}"
      note "enabled the ${mod} module in modules.ini"
    fi
  done
fi

# --- enable stock AMX Mod X plugins the add-on ships commented out ----------
# The tfc / dod add-ons list their stats plugins as ";stats.amxx  ; ... Module
# required!" — uncomment the stock line (keeping its comment), or append the
# plugin if there is no such line. Nothing to do for games with an empty list.
PLUGINS_INI="${GAMEDIR}/addons/amxmodx/configs/plugins.ini"
if [[ -f "${PLUGINS_INI}" && "${#GAME_AMXX_PLUGINS[@]}" -gt 0 ]]; then
  for plugin in "${GAME_AMXX_PLUGINS[@]}"; do
    re="${plugin//./\\.}"
    if grep -Eq "^[[:space:]]*${re}([[:space:]]|$)" "${PLUGINS_INI}"; then
      continue                                   # already enabled
    elif grep -Eq "^;[[:space:]]*${re}([[:space:]]|$)" "${PLUGINS_INI}"; then
      sed -i -E "s/^;[[:space:]]*(${re})([[:space:]]|$)/\1\2/" "${PLUGINS_INI}"
    else
      printf '%s\n' "${plugin}" >> "${PLUGINS_INI}"
    fi
    note "enabled the ${plugin} plugin in plugins.ini"
  done
fi

# --- ensure the engine binaries are executable ------------------------------
# unzip does not always preserve the executable bit from a release archive.
for bin in hlds_linux hlds_run hltv; do
  [[ -f "${SF}/${bin}" ]] && chmod 0755 "${SF}/${bin}"
done

# --- clear the executable-stack flag ----------------------------------------
# GoldSrc .so files are marked exec-stack; Debian 13+ loaders reject them.
note "clearing executable-stack flag on ELF binaries"
python3 /build/clear-execstack.py "${SF}"

# --- normalise directory modes ----------------------------------------------
# Some release archives (e.g. YaPB) store directories without the execute bit,
# which makes them untraversable and unwritable even for their owner.
find "${SF}" -type d -exec chmod 0755 {} +

# --- strip Windows binaries that ride along in some archives ----------------
find "${SF}" -type f \( -name '*.dll' -o -name '*.exe' \) -delete

# =============================================================================
# Sanity check — fail the build if a required artifact is missing.
# =============================================================================
required=(
  "hlds_run" "hlds_linux" "engine_i486.so" "libsteam_api.so"
  "${GAME_MOD}/liblist.gam"
  "${GAME_MOD}/addons/metamod/metamod_i386.so"
  "${GAME_MOD}/addons/amxmodx/dlls/amxmodx_mm_i386.so"
  "${GAME_MOD}/addons/reunion/reunion_mm_i386.so"
  "${GAME_SENTINELS[@]}"
  "${GAME_REQUIRED[@]}"
)
for rel in "${required[@]}"; do
  if [[ ! -e "${SF}/${rel}" ]]; then
    echo "FATAL: required server file missing after assembly: ${rel}" >&2
    exit 1
  fi
done
grep -q "^gamedll_linux \"${MM}\"" "${LIBLIST}" \
  || { echo "FATAL: liblist.gam not pointing at Metamod" >&2; exit 1; }

# --- loader check: every library HLDS/Metamod will dlopen must resolve -----
# Emulates hlds_run (LD_LIBRARY_PATH=. from the server root) with the 32-bit
# dynamic loader in trace mode. Catches a missing or too-old dependency at
# build time — e.g. the depot's bundled libstdc++.so.6 shadowing the system one
# while the game library needs a newer CXXABI — instead of a "Failure to load
# game DLL" at the first start. Checked: the game library, Metamod, AMX Mod X,
# the enabled AMX Mod X modules, Reunion and the bot.
note "checking that the game library, Metamod, AMX Mod X, its modules and the bot resolve"
loader_check=(
  "${GAME_LIBRARY}"
  "${GAME_MOD}/addons/metamod/metamod_i386.so"
  "${GAME_MOD}/addons/amxmodx/dlls/amxmodx_mm_i386.so"
  "${GAME_MOD}/addons/reunion/reunion_mm_i386.so"
  "${GAME_BOT_LIBRARY}"
)
for mod in "${GAME_AMXX_MODULES[@]}"; do
  loader_check+=("${GAME_MOD}/addons/amxmodx/modules/${mod}_amxx_i386.so")
done
loader_failed=0
for lib in "${loader_check[@]}"; do
  trace="$(cd "${SF}" && LD_LIBRARY_PATH=. LD_TRACE_LOADED_OBJECTS=1 /lib/ld-linux.so.2 "./${lib}" 2>&1)" || true
  if grep -qE 'not found|cannot|error' <<< "${trace}"; then
    echo "FATAL: ${lib} does not resolve with the server root first on the library path:" >&2
    grep -E 'not found|cannot|error' <<< "${trace}" | sed 's/^/         /' >&2
    loader_failed=1
  else
    echo "    resolves OK  ${lib}"
  fi
done
[[ "${loader_failed}" -eq 0 ]] || exit 1
# Informational: Windows binaries are swept above; HTML is only expected from
# the depot's own game manual (<game>/manual/), which is depot content and left
# as installed. Anything else listed here came from an archive and should not be.
leftovers=$(find "${SF}" -type f \( -iname '*.dll' -o -iname '*.exe' -o -iname '*.htm' -o -iname '*.html' \) -printf '%P\n' | sort)
if [[ -n "${leftovers}" ]]; then
  note ".dll/.exe/.htm(l) files in the tree (expected: the depot's <game>/manual/ only):"
  echo "${leftovers}" | sed 's/^/      /'
fi

# =============================================================================
# Phase 3 — record the pinned set and the stack manifest.
# =============================================================================
note "writing the stack manifest"
python3 /build/stack-manifest.py snapshot "${SF}" > /build/final.sha256
python3 /build/stack-manifest.py diff /build/depot.sha256 /build/final.sha256 > /build/STACK-MANIFEST
rm -f /build/depot.sha256 /build/final.sha256
stack_digest="$(sha256sum /build/STACK-MANIFEST | cut -c1-16)"
echo "    $(wc -l < /build/STACK-MANIFEST) stack-owned files, digest ${stack_digest}"

cat > /build/VERSIONS <<VEOF
Game            ${GAME} (${GAME_TITLE})
HLDS branch     ${STEAM_BRANCH}
ReHLDS          ${REHLDS_VERSION}
Metamod-R       ${METAMOD_VERSION}
AMXModX         ${AMXX_VERSION}.${AMXX_BUILD} (base + ${GAME_AMXX_ADDON} add-on)
Reunion         ${REUNION_VERSION}
$(profile_versions)
Stack digest    ${stack_digest}
VEOF

note "server assembled OK"
du -sh "${SF}"
echo "    $(find "${SF}" -type f | wc -l) files"
