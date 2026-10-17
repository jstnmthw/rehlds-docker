# shellcheck shell=bash
# =============================================================================
#  Game profile — Day of Defeat   (GAME=dod)
# =============================================================================
#  Sourced by scripts/build-server.sh (build) and scripts/entrypoint.sh
#  (runtime): variable assignments and function definitions only, no side
#  effects. See profiles/cstrike.sh for the contract.
#
#  DoD keeps Valve's own game library (dod/dlls/dod.so) and runs the stock
#  AMX Mod X dod add-on (dodx + dodfun modules, stats plugins). The bot is
#  new_bot (Martee), a Metamod plugin that lives in dod/new_bot/ — not under
#  addons/ — plus the Sturmbot waypoint pack it falls back to for maps it has
#  no waypoint of its own for. Both archives are vendored.
#
#  Fallback if new_bot misbehaves under ReHLDS (not shipped): Marine Bot 0.97
#  Beta DoD edition, GPL, https://sourceforge.net/projects/marinebot/ — not a
#  Metamod plugin; its readme leaves liblist.gam on Metamod and starts HLDS
#  with "+localinfo mm_gamedll marinebot/marinebot.so".
# =============================================================================

GAME_TITLE="Day of Defeat"
GAME_MOD=dod
GAME_BOT="new_bot"
GAME_LIBRARY=dod/dlls/dod.so            # Valve's, kept
GAME_BOT_LIBRARY=dod/new_bot/new_bot_mm.so

GAME_DEFAULT_MAP=dod_anzio
GAME_DEFAULT_MAXPLAYERS=32
GAME_DEFAULT_START_PARAMS=""           # engine defaults; tune after measurement

GAME_SENTINELS=(dod/dlls/dod.so dod/liblist.gam dod/maps/dod_anzio.bsp)

# The dod add-on ships ";dodx" / ";dodfun" and its stats plugins commented out
# ("DoD Module required!"); the build enables them.
GAME_AMXX_ADDON=dod
GAME_AMXX_MODULES=(dodx dodfun)
GAME_AMXX_PLUGINS=(stats.amxx statssounds.amxx stats_logging.amxx)

GAME_REQUIRED=(
  dod/dlls/dod.so
  dod/addons/amxmodx/modules/dodx_amxx_i386.so
  dod/addons/amxmodx/modules/dodfun_amxx_i386.so
  dod/new_bot/new_bot_mm.so
  dod/new_bot/new_bot.cfg
  dod/new_bot/maps/default_bot.cfg
  dod/new_bot/waypoints
  dod/sturmbot/waypoints
)

# new_bot tuning: new_bot.cfg (global settings, all commented at stock) and
# maps/ (default_bot.cfg — ships target_players 12, balance teams on — plus any
# per-map <map>_bot.cfg the operator adds). Seeded once, then the operator's.
GAME_OPERATOR_FILES=(
  new_bot/new_bot.cfg
  new_bot/maps/
)

# --- build hooks (build-server.sh only) --------------------------------------

profile_fetch() {
  fetch "new_bot.zip"           "${VENDOR}/${NEWBOT_ARCHIVE}"           "${NEWBOT_SHA256}"
  fetch "new_bot-waypoints.zip" "${VENDOR}/${NEWBOT_WAYPOINTS_ARCHIVE}" "${NEWBOT_WAYPOINTS_SHA256}"
}

profile_apply() {
  # new_bot: everything sits under dod/ in the archive (dod/new_bot/* and a
  # client key-binding file dod/newbotconfig.cfg); it is laid straight onto
  # the game directory. The .dll goes with the global sweep.
  reset_tmp
  unzip -q "${DL}/new_bot.zip" -d "${TMP}"
  cp -a "${TMP}"/dod/. "${SF}"/dod/

  # Sturmbot waypoint pack: <pack>/dod/sturmbot/waypoints/*.wpt (743 files,
  # some with spaces and brackets in their names) -> dod/sturmbot/waypoints/.
  # new_bot checks this directory when it has no waypoint of its own for a map.
  reset_tmp
  unzip -q "${DL}/new_bot-waypoints.zip" -d "${TMP}"
  cp -a "${TMP}"/sturmbot_4_new_bot_waypoints/dod/. "${SF}"/dod/
  note "applied new_bot ${NEWBOT_VERSION} (waypoints: $(find "${SF}/dod/new_bot/waypoints" -name '*.wpt' | wc -l) own, $(find "${SF}/dod/sturmbot/waypoints" -name '*.wpt' | wc -l) Sturmbot)"
}

profile_versions() {
  cat <<VEOF
new_bot         ${NEWBOT_VERSION} (vendored)
Sturmbot wpts   ${NEWBOT_WAYPOINTS_VERSION} (vendored, for new_bot)
VEOF
}
