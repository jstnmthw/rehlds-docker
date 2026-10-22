# shellcheck shell=bash
# =============================================================================
#  Game profile — Counter-Strike 1.6   (GAME=cstrike)
# =============================================================================
#  One file per game. It is sourced by scripts/build-server.sh inside the Docker
#  build and by scripts/entrypoint.sh at container start, so it must contain
#  only variable assignments and function definitions — no side effects. The
#  entrypoint reads the GAME_* variables; build-server.sh additionally calls the
#  profile_* hooks, which run with that script's helpers in scope (fetch,
#  reset_tmp, note, and the SF / DL / TMP / VENDOR / GH paths).
#
#  Everything Counter-Strike-specific lives here: the depot mod name, the
#  sentinel files the SteamCMD loop waits for, the AMX Mod X add-on and the
#  modules / plugins to enable in it, the bot, the extra stack components
#  (ReGameDLL_CS, ReAPI) and the YaPB performance cvars baked into yapb.cfg.
# =============================================================================

GAME_TITLE="Counter-Strike 1.6"
GAME_MOD=cstrike                       # SteamCMD mod name == game directory == hlds -game
GAME_BOT="YaPB"                        # the one bot this game ships, behind BOTS_ENABLED
GAME_LIBRARY=cstrike/dlls/cs.so        # the game library Metamod loads (ReGameDLL's cs.so here)
GAME_BOT_LIBRARY=cstrike/addons/yapb/bin/yapb.so
# Only for a bot that is not a Metamod plugin: the HLDS start parameters that
# load it, added by the entrypoint while BOTS_ENABLED=true (dod: Marine Bot).
# YaPB is a plugin (the @bot@ line of config/cstrike/plugins.ini). Optional.
GAME_BOT_START_PARAMS=""

# Entrypoint defaults for the env-driven start parameters.
GAME_DEFAULT_MAP=de_dust2
GAME_DEFAULT_MAXPLAYERS=16
GAME_DEFAULT_START_PARAMS="-pingboost 1 +sys_ticrate 1000"

# Depot sentinels (besides the shared hlds_run / hlds_linux / engine_i486.so /
# gfx.wad): the SteamCMD loop is "complete" only once all of these exist.
GAME_SENTINELS=(cstrike/dlls/cs.so cstrike/liblist.gam cstrike/maps/de_dust2.bsp)

# AMX Mod X: the game add-on tarball (amxmodx-<ver>-git<build>-<addon>-linux.tar.gz,
# pinned by AMXX_CSTRIKE_SHA256), the modules to force-load in modules.ini and
# the stock plugins to enable in plugins.ini (none for CS: statsx is already on).
GAME_AMXX_ADDON=cstrike
GAME_AMXX_MODULES=(cstrike reapi)
GAME_AMXX_PLUGINS=()

# Files that must exist after assembly (on top of the shared engine / Metamod /
# AMX Mod X / Reunion checks in build-server.sh). Relative to the server root.
GAME_REQUIRED=(
  cstrike/dlls/cs.so
  cstrike/delta.lst
  cstrike/addons/amxmodx/modules/reapi_amxx_i386.so
  cstrike/addons/amxmodx/modules/cstrike_amxx_i386.so
  cstrike/addons/yapb/bin/yapb.so
)

# Operator-owned files the image ships but the entrypoint's stack sync never
# overwrites once they are in the volume (seeded on first run only). Relative to
# the game directory; addons/amxmodx/configs/ is excluded for every game by the
# entrypoint itself. Bot tuning lives here (yb_quota, yb_difficulty, ...).
GAME_OPERATOR_FILES=(
  addons/yapb/conf/yapb.cfg
)

# --- build hooks (build-server.sh only) --------------------------------------

profile_fetch() {
  fetch "regamedll.zip" \
    "${GH}/rehlds/ReGameDLL_CS/releases/download/${REGAMEDLL_VERSION}/regamedll-bin-${REGAMEDLL_VERSION}.zip" \
    "${REGAMEDLL_SHA256}"
  fetch "reapi.zip" \
    "${GH}/rehlds/ReAPI/releases/download/${REAPI_VERSION}/reapi-bin-${REAPI_VERSION}.zip" \
    "${REAPI_SHA256}"
  # YaPB is vendored: upstream only publishes a rolling `continuous` release
  # whose assets are deleted on every push, so the pinned build lives in vendor/.
  fetch "yapb.tar.xz" "${VENDOR}/${YAPB_ARCHIVE}" "${YAPB_SHA256}"
}

# Replace an existing cvar's value in the stock yapb.cfg (fails the build if
# upstream renamed or removed the cvar, so a version bump cannot silently drop
# a baked default).
yapb_set() {  # cvar value
  local cvar="$1" value="$2"
  grep -Eq "^[[:space:]]*${cvar}[[:space:]]" "${YAPB_CFG}" || {
    echo "FATAL: YaPB cvar '${cvar}' not found in stock yapb.cfg — upstream renamed/removed it?" >&2
    exit 1
  }
  sed -i -E "s#^[[:space:]]*${cvar}[[:space:]].*#${cvar} \"${value}\"#" "${YAPB_CFG}"
}

profile_apply() {
  # ReGameDLL_CS: bin/linux32/cstrike/* -> cstrike/ (cs.so + delta.lst + game*.cfg).
  reset_tmp
  unzip -q "${DL}/regamedll.zip" -d "${TMP}"
  cp -a "${TMP}"/bin/linux32/cstrike/. "${SF}"/cstrike/

  # ReAPI: merges into the AMX Mod X tree.
  reset_tmp
  unzip -q "${DL}/reapi.zip" -d "${TMP}"
  cp -a "${TMP}"/addons/amxmodx/. "${SF}"/cstrike/addons/amxmodx/

  # YaPB: addons/yapb/* -> cstrike/addons/yapb/
  tar -xJf "${DL}/yapb.tar.xz" -C "${SF}/cstrike/"

  # --- tune YaPB performance / behaviour cvars in place ---------------------
  # yapb.cfg ships inside the YaPB archive and is replaced wholesale on every
  # version bump, so we re-apply our handful of perf/behaviour values directly
  # onto the freshly-extracted stock file here — the same in-place-patch
  # approach used for liblist.gam and modules.ini. Because the values live in
  # yapb.cfg itself (which YaPB re-execs on every changelevel) they survive map
  # changes with no runtime overlay. Bot *tuning* — yb_quota / yb_quota_mode /
  # yb_difficulty / yb_autovacate — is deliberately left at YaPB's stock
  # defaults for the operator to set by editing the live yapb.cfg in the volume.
  YAPB_CFG="${SF}/cstrike/addons/yapb/conf/yapb.cfg"
  # AI think rate (stock 26.0): smoother aim/tracking without hitting the 90 cap.
  yapb_set yb_think_fps               60.0
  # Floyd-Warshall pathfinding memory cap, MB (stock 6): keep big maps on the fast
  # precomputed path instead of falling back to slower per-query Dijkstra.
  yapb_set yb_path_floyd_memory_limit 32
  # Post-smooth A* paths (stock 0): de-zig-zag bot routes, trivial CPU cost.
  yapb_set yb_path_astar_post_smooth  1
  # yb_graph_analyze_fps was removed upstream in 4.8 (analysis is now time-sliced
  # by yb_graph_analyze_slice_ms, left at stock). yapb_set would FATAL on it.
  note "tuned YaPB performance cvars in yapb.cfg (bot count/difficulty left at YaPB defaults)"
}

profile_versions() {  # extra lines for /build/VERSIONS
  cat <<VEOF
ReGameDLL_CS    ${REGAMEDLL_VERSION}
ReAPI           ${REAPI_VERSION}
YaPB            ${YAPB_VERSION} (vendored)
VEOF
}
