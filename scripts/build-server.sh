#!/usr/bin/env bash
#
# build-server.sh — runs INSIDE the Docker build (stage: server-builder).
#
# Produces a complete, ReHLDS-ified Counter-Strike 1.6 server tree at
# /build/serverfiles, which the runtime stage bakes into the image.
#
# Two phases:
#   1. Install CS 1.6 (HLDS appid 90) via SteamCMD, from the "steam_legacy"
#      branch — the pre-25th-anniversary HLDS that ReHLDS is compatible with.
#      SteamCMD's appid-90 download is notoriously incremental, so this loops
#      until the install size stabilises and all sentinel files are present.
#   2. Download every ReHLDS-stack release asset, verify it (SHA256 for all,
#      GPG for ReHLDS), and apply it onto the installed serverfiles.
#
# Because the ReHLDS stack is applied here, at build time, the running
# container never needs to re-apply anything: SteamCMD is never run again.
#
set -euo pipefail

SF=/build/serverfiles          # the server tree being assembled
DL=/build/dl                   # downloaded ReHLDS component archives
TMP=/build/extract             # scratch extraction dir
CURATED=/build/curated         # repo-provided files baked in
GH="https://github.com"
STEAMCMD="${STEAMCMDDIR:-/home/steam/steamcmd}/steamcmd.sh"

mkdir -p "$SF" "$DL"
note() { echo ">>> $*"; }

# =============================================================================
# Phase 1 — install HLDS appid 90 (steam_legacy branch) via SteamCMD.
# =============================================================================
note "installing Counter-Strike 1.6 (appid 90, branch ${STEAM_BRANCH}) via SteamCMD"

prev_size=-1
stable=0
complete=0
for run in $(seq 1 30); do
  echo "--- SteamCMD pass ${run} ---"
  # appid-90 installs are flaky; tolerate a non-zero exit and let the loop retry.
  "${STEAMCMD}" +force_install_dir "${SF}" \
                +login anonymous \
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
  if [[ "${stable}" -ge 2 ]] \
     && [[ -f "${SF}/hlds_run" ]] \
     && [[ -f "${SF}/hlds_linux" ]] \
     && [[ -f "${SF}/engine_i486.so" ]] \
     && [[ -f "${SF}/cstrike/dlls/cs.so" ]] \
     && [[ -f "${SF}/cstrike/liblist.gam" ]] \
     && [[ -f "${SF}/cstrike/maps/de_dust2.bsp" ]] \
     && [[ -n "$(find "${SF}" -name 'gfx.wad' -print -quit 2>/dev/null)" ]]; then
    complete=1
    note "install complete and verified after ${run} pass(es)"
    break
  fi
done

if [[ "${complete}" -ne 1 ]]; then
  echo "FATAL: SteamCMD did not produce a complete CS 1.6 install." >&2
  echo "       Missing sentinels:" >&2
  for f in hlds_run hlds_linux engine_i486.so cstrike/dlls/cs.so \
           cstrike/liblist.gam cstrike/maps/de_dust2.bsp; do
    [[ -f "${SF}/${f}" ]] || echo "         - ${f}" >&2
  done
  [[ -n "$(find "${SF}" -name 'gfx.wad' -print -quit 2>/dev/null)" ]] \
    || echo "         - gfx.wad (anywhere)" >&2
  exit 1
fi

# Trim the 64-bit HLDS variant — this image runs the 32-bit ReHLDS engine.
rm -rf "${SF}/linux64" 2>/dev/null || true

# =============================================================================
# Phase 2 — download, verify and apply the ReHLDS stack.
# =============================================================================
fetch() {  # name url sha256
  local name="$1" url="$2" sha="$3"
  note "downloading ${name}"
  curl --fail --silent --show-error --location \
       --retry 4 --retry-delay 3 --connect-timeout 30 \
       -o "${DL}/${name}" "${url}"
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

# --- the rest — SHA256 only. ------------------------------------------------
fetch "regamedll.zip" \
  "${GH}/rehlds/ReGameDLL_CS/releases/download/${REGAMEDLL_VERSION}/regamedll-bin-${REGAMEDLL_VERSION}.zip" \
  "${REGAMEDLL_SHA256}"
fetch "metamod.zip" \
  "${GH}/rehlds/Metamod-R/releases/download/${METAMOD_VERSION}/metamod-bin-${METAMOD_VERSION}.zip" \
  "${METAMOD_SHA256}"
fetch "amxx-base.tar.gz" \
  "${GH}/alliedmodders/amxmodx/releases/download/${AMXX_VERSION}.${AMXX_BUILD}/amxmodx-${AMXX_VERSION}-git${AMXX_BUILD}-base-linux.tar.gz" \
  "${AMXX_BASE_SHA256}"
fetch "amxx-cstrike.tar.gz" \
  "${GH}/alliedmodders/amxmodx/releases/download/${AMXX_VERSION}.${AMXX_BUILD}/amxmodx-${AMXX_VERSION}-git${AMXX_BUILD}-cstrike-linux.tar.gz" \
  "${AMXX_CSTRIKE_SHA256}"
fetch "reapi.zip" \
  "${GH}/rehlds/ReAPI/releases/download/${REAPI_VERSION}/reapi-bin-${REAPI_VERSION}.zip" \
  "${REAPI_SHA256}"
fetch "yapb.tar.xz" \
  "${GH}/yapb/yapb/releases/download/${YAPB_VERSION}/yapb-${YAPB_VERSION}-linux.tar.xz" \
  "${YAPB_SHA256}"
fetch "reunion.zip" \
  "${GH}/rehlds/ReUnion/releases/download/${REUNION_VERSION}/reunion-${REUNION_VERSION}.zip" \
  "${REUNION_SHA256}"

# --- apply onto the serverfiles ---------------------------------------------
note "applying the ReHLDS stack onto the serverfiles"

# ReHLDS: bin/linux32/* -> server root (engine_i486.so, hlds_linux, support libs).
reset_tmp
unzip -q "${DL}/rehlds.zip" -d "${TMP}"
cp -a "${TMP}"/bin/linux32/. "${SF}"/

# ReGameDLL_CS: bin/linux32/cstrike/* -> cstrike/ (cs.so + delta.lst + game*.cfg).
reset_tmp
unzip -q "${DL}/regamedll.zip" -d "${TMP}"
cp -a "${TMP}"/bin/linux32/cstrike/. "${SF}"/cstrike/

# Metamod-R: addons/metamod/* -> cstrike/addons/metamod/
reset_tmp
unzip -q "${DL}/metamod.zip" -d "${TMP}"
mkdir -p "${SF}/cstrike/addons/metamod"
cp -a "${TMP}"/addons/metamod/. "${SF}"/cstrike/addons/metamod/

# AMX Mod X: base then the cstrike add-on.
tar -xzf "${DL}/amxx-base.tar.gz"    -C "${SF}/cstrike/"
tar -xzf "${DL}/amxx-cstrike.tar.gz" -C "${SF}/cstrike/"

# ReAPI: merges into the AMX Mod X tree.
reset_tmp
unzip -q "${DL}/reapi.zip" -d "${TMP}"
cp -a "${TMP}"/addons/amxmodx/. "${SF}"/cstrike/addons/amxmodx/

# YaPB: addons/yapb/* -> cstrike/addons/yapb/
tar -xJf "${DL}/yapb.tar.xz" -C "${SF}/cstrike/"

# Reunion: the Linux Metamod plugin -> cstrike/addons/reunion/
reset_tmp
unzip -q "${DL}/reunion.zip" -d "${TMP}"
mkdir -p "${SF}/cstrike/addons/reunion"
cp -a "${TMP}"/bin/Linux/reunion_mm_i386.so "${SF}"/cstrike/addons/reunion/

# Curated AMX Mod X core config.
cp -f "${CURATED}/amxx.cfg" "${SF}/cstrike/addons/amxmodx/configs/amxx.cfg"

# Curated YaPB performance/behaviour overlay, hooked into the stock yapb.cfg.
# yapb.cfg ships inside the YaPB archive and is replaced on every version bump,
# so the tuning lives in a separate file and yapb.cfg just exec's it. YaPB
# re-execs yapb.cfg on every changelevel, so the overlay re-applies each map.
YAPB_CONF="${SF}/cstrike/addons/yapb/conf"
cp -f "${CURATED}/yapb-overlay.cfg" "${YAPB_CONF}/yapb-overlay.cfg"
if ! grep -q 'yapb-overlay.cfg' "${YAPB_CONF}/yapb.cfg"; then
  printf '\nexec addons/yapb/conf/yapb-overlay.cfg\n' >> "${YAPB_CONF}/yapb.cfg"
  note "hooked yapb-overlay.cfg into yapb.cfg"
fi

# --- patch liblist.gam so HLDS loads Metamod --------------------------------
LIBLIST="${SF}/cstrike/liblist.gam"
MM='addons/metamod/metamod_i386.so'
if grep -q '^gamedll_linux' "${LIBLIST}"; then
  sed -i "s#^gamedll_linux .*#gamedll_linux \"${MM}\"#" "${LIBLIST}"
else
  printf 'gamedll_linux "%s"\n' "${MM}" >> "${LIBLIST}"
fi
note "patched liblist.gam: gamedll_linux -> ${MM}"

# --- enable ReAPI in the AMX Mod X module list ------------------------------
MODULES_INI="${SF}/cstrike/addons/amxmodx/configs/modules.ini"
if [[ -f "${MODULES_INI}" ]] && ! grep -Eqx '[[:space:]]*reapi[[:space:]]*' "${MODULES_INI}"; then
  printf 'reapi\n' >> "${MODULES_INI}"
  note "enabled the reapi module in modules.ini"
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
  "cstrike/dlls/cs.so" "cstrike/delta.lst" "cstrike/liblist.gam"
  "cstrike/maps/de_dust2.bsp"
  "cstrike/addons/metamod/metamod_i386.so"
  "cstrike/addons/amxmodx/dlls/amxmodx_mm_i386.so"
  "cstrike/addons/amxmodx/modules/reapi_amxx_i386.so"
  "cstrike/addons/amxmodx/modules/cstrike_amxx_i386.so"
  "cstrike/addons/yapb/bin/yapb.so"
  "cstrike/addons/reunion/reunion_mm_i386.so"
)
for rel in "${required[@]}"; do
  if [[ ! -f "${SF}/${rel}" ]]; then
    echo "FATAL: required server file missing after assembly: ${rel}" >&2
    exit 1
  fi
done
grep -q "^gamedll_linux \"${MM}\"" "${LIBLIST}" \
  || { echo "FATAL: liblist.gam not pointing at Metamod" >&2; exit 1; }

# --- record pinned versions for the runtime banner --------------------------
cat > /build/VERSIONS <<EOF
ReHLDS          ${REHLDS_VERSION}
ReGameDLL_CS    ${REGAMEDLL_VERSION}
Metamod-R       ${METAMOD_VERSION}
AMXModX         ${AMXX_VERSION}.${AMXX_BUILD}
ReAPI           ${REAPI_VERSION}
YaPB            ${YAPB_VERSION}
Reunion         ${REUNION_VERSION}
HLDS branch     ${STEAM_BRANCH}
EOF

note "server assembled OK"
du -sh "${SF}"
echo "    $(find "${SF}" -type f | wc -l) files"
