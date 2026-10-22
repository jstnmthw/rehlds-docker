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
#  Marine Bot 0.97 Beta, DoD edition (GPL), plus Martee's waypoint pack for the
#  official maps (Marine Bot ships none). Both archives are vendored, and so is
#  the bot's source (vendor/mb097b-dod-source.zip, not used by the build).
#
#  Marine Bot is not a Metamod plugin but a game-library wrapper: liblist.gam
#  stays on Metamod and HLDS starts with "+localinfo mm_gamedll
#  marinebot/marinebot.so", so Metamod loads marinebot.so as the game library
#  and Marine Bot loads dod.so. The entrypoint adds that parameter only while
#  BOTS_ENABLED=true (GAME_BOT_START_PARAMS below).
#
#  new_bot 0.3.0, the bot this image shipped first, leaked resident memory at
#  every map change (0.24 MiB per change on the first pass through an 18-map
#  rotation, 2.85 MiB on the second); Marine Bot ran flat across 182 changes.
# =============================================================================

GAME_TITLE="Day of Defeat"
GAME_MOD=dod
GAME_BOT="Marine Bot"
GAME_LIBRARY=dod/dlls/dod.so            # Valve's, kept (loaded by Marine Bot)
GAME_BOT_LIBRARY=dod/marinebot/marinebot.so
GAME_BOT_START_PARAMS="+localinfo mm_gamedll marinebot/marinebot.so"

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
  dod/marinebot/marinebot.so
  dod/marinebot/marine.cfg
  dod/marinebot/marine_dog-tags.txt
  dod/marinebot/defaultwpts/dod_anzio.wpt
  dod/marinebot/defaultwpts/dod_anzio.pth
)

# Marine Bot tuning: marine.cfg (max_bots, stock 6, and the "recruit" block of
# bots added at start), marine_dog-tags.txt (bot names), mapcfgs/ (per-map
# settings) and customwpts/ (the operator's own waypoints). Seeded once, then
# the operator's. defaultwpts/ stays image-owned so a newer waypoint pack
# reaches existing volumes; waypoints edited in game belong in customwpts/
# (Marine Bot saves to the directory it loads from).
GAME_OPERATOR_FILES=(
  marinebot/marine.cfg
  marinebot/marine_dog-tags.txt
  marinebot/mapcfgs/
  marinebot/customwpts/
)

# --- build hooks (build-server.sh only) --------------------------------------

profile_fetch() {
  fetch "marinebot.zip"           "${VENDOR}/${MARINEBOT_ARCHIVE}"           "${MARINEBOT_SHA256}"
  fetch "marinebot-waypoints.zip" "${VENDOR}/${MARINEBOT_WAYPOINTS_ARCHIVE}" "${MARINEBOT_WAYPOINTS_SHA256}"
}

profile_apply() {
  # Marine Bot: the archive holds marinebot/ (marinebot.so, marine_bot.dll,
  # marine.cfg + its stock copy marine_backup.cfg, marine_dog-tags.txt,
  # defaultwpts/ and customwpts/ with only a placeholder each, mapcfgs/,
  # weapons/, readmes, HTML help and two icons) plus two Windows liblist
  # installers at the top level. Only marinebot/ is taken, laid onto the game
  # directory; the HTML help and the icons are dropped here, the .dll and .exe
  # files go with the global sweep.
  reset_tmp
  unzip -q "${DL}/marinebot.zip" -d "${TMP}"
  mkdir -p "${SF}/dod/marinebot"
  cp -a "${TMP}"/marinebot/. "${SF}"/dod/marinebot/
  find "${SF}/dod/marinebot" -maxdepth 1 -type f \( -iname '*.htm*' -o -iname '*.ico' \) -delete

  # Martee's waypoint pack: <pack>/dod/marinebot/defaultwpts/<map>.{wpt,pth}
  # for the official maps (a .wpt and a .pth each) and one custom map under
  # customwpts/. Laid onto the game directory next to the bot.
  reset_tmp
  unzip -q "${DL}/marinebot-waypoints.zip" -d "${TMP}"
  cp -a "${TMP}"/martee_dod_waypoint_pack_v2/dod/. "${SF}"/dod/

  # marinebot.so is built with a modern toolchain and needs CXXABI_1.3.9, which
  # the depot's bundled 32-bit libstdc++.so.6 predates; the base image's
  # libstdc++ in turn needs GCC_7.0.0 from libgcc_s. Drop the bundled pair, as
  # the tfc profile does, so the base image's lib32stdc++6 / lib32gcc-s1 are
  # used. build-server.sh's loader check below verifies the result.
  rm -f "${SF}/libstdc++.so.6" "${SF}/libgcc_s.so.1"
  note "dropped the depot's bundled libstdc++.so.6 / libgcc_s.so.1 (marinebot.so needs the system one)"
  note "applied Marine Bot ${MARINEBOT_VERSION} (waypoints: $(find "${SF}/dod/marinebot/defaultwpts" -name '*.wpt' | wc -l) default, $(find "${SF}/dod/marinebot/customwpts" -name '*.wpt' | wc -l) custom)"
}

profile_versions() {
  cat <<VEOF
Marine Bot      ${MARINEBOT_VERSION} (vendored)
MB waypoints    ${MARINEBOT_WAYPOINTS_VERSION} (vendored, Martee)
VEOF
}
