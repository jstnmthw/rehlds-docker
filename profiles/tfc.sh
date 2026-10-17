# shellcheck shell=bash
# =============================================================================
#  Game profile — Team Fortress Classic   (GAME=tfc)
# =============================================================================
#  Sourced by scripts/build-server.sh (build) and scripts/entrypoint.sh
#  (runtime): variable assignments and function definitions only, no side
#  effects. See profiles/cstrike.sh for the contract.
#
#  TFC keeps Valve's own game library (tfc/dlls/tfc.so; there is no ReGameDLL
#  for it) and runs the stock AMX Mod X tfc add-on (tfcx module + stats
#  plugins). The bot is FoxBot, a Metamod plugin; its archive is vendored.
# =============================================================================

GAME_TITLE="Team Fortress Classic"
GAME_MOD=tfc
GAME_BOT="FoxBot"
GAME_LIBRARY=tfc/dlls/tfc.so            # Valve's, kept
GAME_BOT_LIBRARY=tfc/addons/foxbot/foxbot.so

GAME_DEFAULT_MAP=well
GAME_DEFAULT_MAXPLAYERS=32
GAME_DEFAULT_START_PARAMS=""           # engine defaults; tune after measurement

GAME_SENTINELS=(tfc/dlls/tfc.so tfc/liblist.gam tfc/maps/well.bsp)

# The tfc add-on ships the tfcx module as ";tfcx" and its stats plugins
# commented out ("TFC Module required!"); the build enables both.
GAME_AMXX_ADDON=tfc
GAME_AMXX_MODULES=(tfcx)
GAME_AMXX_PLUGINS=(stats.amxx statssounds.amxx stats_logging.amxx)

GAME_REQUIRED=(
  tfc/dlls/tfc.so
  tfc/addons/amxmodx/modules/tfcx_amxx_i386.so
  tfc/addons/foxbot/foxbot.so
  tfc/addons/foxbot/tfc/foxbot.cfg
  tfc/addons/foxbot/tfc/waypoints
)

# FoxBot tuning: foxbot.cfg (bot count via max_bots, skill, chat), default.cfg
# (the fallback when a map has no config) and the per-map configs/ directory.
# Seeded once, then the operator's; stock max_bots is 10.
GAME_OPERATOR_FILES=(
  addons/foxbot/tfc/foxbot.cfg
  addons/foxbot/tfc/default.cfg
  addons/foxbot/tfc/configs/
)

# --- build hooks (build-server.sh only) --------------------------------------

profile_fetch() {
  fetch "foxbot.zip" "${VENDOR}/${FOXBOT_ARCHIVE}" "${FOXBOT_SHA256}"
}

profile_apply() {
  # FoxBot: the archive is laid out as addons/foxbot/{foxbot.so,foxbot.dll,
  # readmes, documentation/, tfc/} plus a sample addons/metamod/ (an OLD
  # Metamod build and a plugins.ini) — only addons/foxbot is taken, so the
  # sample never touches the Metamod-R install. tfc/ holds foxbot.cfg, the
  # per-map configs/, the stock waypoints/ (597 .fwp), areas/ and scripts/.
  reset_tmp
  unzip -q "${DL}/foxbot.zip" -d "${TMP}"
  mkdir -p "${SF}/tfc/addons/foxbot"
  cp -a "${TMP}"/addons/foxbot/. "${SF}"/tfc/addons/foxbot/
  # Drop the HTML documentation (the .dll goes with the global sweep).
  rm -rf "${SF}/tfc/addons/foxbot/documentation"
  find "${SF}/tfc/addons/foxbot" -maxdepth 1 -type f -iname '*.htm*' -delete

  # The steam_legacy depot bundles an old 32-bit libstdc++.so.6 / libgcc_s.so.1
  # at the server root, and hlds_run puts "." first on LD_LIBRARY_PATH, so they
  # shadow the system ones. Valve's tfc.so needs CXXABI_1.3.8, which the bundled
  # copy predates — the server died with "Failure to load game DLL" (the loader:
  # "version `CXXABI_1.3.8' not found"); cs.so and dod.so do not need it, so
  # those images keep the depot as is. Drop the bundled pair here so the base
  # image's lib32stdc++6 / lib32gcc-s1 (every CXXABI version) are used instead.
  # build-server.sh's loader check below verifies the result.
  rm -f "${SF}/libstdc++.so.6" "${SF}/libgcc_s.so.1"
  note "dropped the depot's bundled libstdc++.so.6 / libgcc_s.so.1 (tfc.so needs the system one)"
  note "applied FoxBot ${FOXBOT_VERSION} (stock waypoints: $(find "${SF}/tfc/addons/foxbot/tfc/waypoints" -name '*.fwp' | wc -l))"
}

profile_versions() {
  cat <<VEOF
FoxBot          ${FOXBOT_VERSION} (vendored)
VEOF
}
