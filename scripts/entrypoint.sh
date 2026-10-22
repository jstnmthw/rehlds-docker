#!/usr/bin/env bash
#
# entrypoint.sh — container entrypoint for the ReHLDS GoldSrc server image.
#
# Game-agnostic: everything game-specific (game directory, defaults, the
# operator-owned bot files) comes from the profile baked into the image at
# /opt/hlds/profile.sh (profiles/<GAME>.sh in the repository).
#
# Starts as root or as the unprivileged user. It:
#   1. seeds the /server volume from the baked-in server copy on first run, and
#      on later starts refreshes the stack-owned files in it when the image's
#      stack changed (VERSIONS differs from the copy kept in the volume),
#   2. renders the env-driven config (server.cfg, Metamod plugins.ini,
#      reunion.cfg, AMX Mod X users.ini) into the serverfiles,
#   3. drops to the unprivileged "steam" user (when started as root) and
#      execs HLDS. Started as a non-root user (compose `user:`), it skips the
#      ownership fix and the drop: no root process exists at any point.
#
# There is no update machinery: the ReHLDS stack was applied at build time.
#
set -uo pipefail

HLDS_HOME=/opt/hlds
BASE="${HLDS_HOME}/serverfiles-base"   # immutable baked-in server copy
TEMPLATES="${HLDS_HOME}/templates"
PROFILE="${HLDS_HOME}/profile.sh"
IMAGE_VERSIONS="${HLDS_HOME}/VERSIONS"
MANIFEST="${HLDS_HOME}/STACK-MANIFEST"
SERVER=/server                         # working serverfiles (a volume)
VOLUME_VERSIONS="${SERVER}/VERSIONS"   # the stack this volume was last synced to
SALT_FILE="${SERVER}/.reunion-salt"
RUN_USER=steam

log() { echo "[entrypoint] $*"; }

# --- game profile ------------------------------------------------------------
if [[ ! -f "${PROFILE}" ]]; then
  log "FATAL: game profile missing (${PROFILE}) — image built incorrectly"
  exit 1
fi
# shellcheck source=/dev/null
source "${PROFILE}"
GAMEDIR="${SERVER}/${GAME_MOD}"

# --- banner ------------------------------------------------------------------
echo
echo "================================================================================"
echo " ReHLDS ${GAME_TITLE} server"
echo "================================================================================"
if [[ -f "${IMAGE_VERSIONS}" ]]; then
  while IFS= read -r line; do [[ -n "${line}" ]] && echo "   ${line}"; done < "${IMAGE_VERSIONS}"
fi
echo "================================================================================"
echo

if [[ ! -d "${BASE}" ]] || [[ -z "$(ls -A "${BASE}" 2>/dev/null)" ]]; then
  log "FATAL: baked server copy missing (${BASE}) — image built incorrectly"
  exit 1
fi

# --- 1. seed the /server volume on first run, refresh the stack afterwards --
# Files the image ships but never overwrites once they are in the volume: the
# operator's. AMX Mod X's configs/ (amxx.cfg, users.ini, plugins.ini, ...) for
# every game, plus the game's bot tuning files from the profile.
OPERATOR_OWNED=("${GAME_MOD}/addons/amxmodx/configs/")
for f in "${GAME_OPERATOR_FILES[@]}"; do OPERATOR_OWNED+=("${GAME_MOD}/${f}"); done
is_operator_owned() {  # <path relative to the server root>
  local rel="$1" p
  for p in "${OPERATOR_OWNED[@]}"; do
    if [[ "${p}" == */ ]]; then
      [[ "${rel}" == "${p}"* ]] && return 0
    else
      [[ "${rel}" == "${p}" ]] && return 0
    fi
  done
  return 1
}

# Re-copy the stack-owned files (STACK-MANIFEST: everything the build added to
# or changed in the bare depot — engine binaries, game library, Metamod,
# AMX Mod X, the bot, patched files) from the image into the volume, leaving
# operator-owned files and everything the image does not ship (maps you added,
# logs, bans, learned bot data) alone. Nothing is deleted.
sync_stack() {
  local list n=0 kept=0
  list="$(mktemp)"
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    if is_operator_owned "${rel}" && [[ -e "${SERVER}/${rel}" ]]; then
      kept=$((kept + 1)); continue
    fi
    printf '%s\0' "${rel}" >> "${list}"
    n=$((n + 1))
  done < <(cut -c67- "${MANIFEST}")
  if [[ "${n}" -gt 0 ]]; then
    if ! tar -C "${BASE}" --null --files-from="${list}" -cf - | tar -C "${SERVER}" -xf -; then
      log "FATAL: refreshing the stack in ${SERVER} failed — volume left as is"
      rm -f "${list}"
      exit 1
    fi
  fi
  rm -f "${list}"
  cp "${IMAGE_VERSIONS}" "${VOLUME_VERSIONS}"
  log "refreshed ${n} stack-owned file(s) from the image; ${kept} operator-owned file(s) kept"
}

mkdir -p "${SERVER}"
if [[ -z "$(ls -A "${SERVER}" 2>/dev/null)" ]]; then
  log "first run — seeding ${SERVER} from the baked server copy"
  cp -a "${BASE}/." "${SERVER}/"
  cp "${IMAGE_VERSIONS}" "${VOLUME_VERSIONS}"
  log "seeded $(find "${SERVER}" -type f | wc -l) files"
else
  # Refuse to run one game's image on another game's volume.
  if [[ -f "${VOLUME_VERSIONS}" ]]; then
    volume_game="$(awk '$1 == "Game" { print $2; exit }' "${VOLUME_VERSIONS}")"
    if [[ -n "${volume_game}" && "${volume_game}" != "${GAME_MOD}" ]]; then
      log "FATAL: ${SERVER} holds a '${volume_game}' install but this image is '${GAME_MOD}' — wrong volume?"
      exit 1
    fi
  elif [[ ! -f "${GAMEDIR}/liblist.gam" ]]; then
    log "FATAL: ${SERVER} is not empty but has no ${GAME_MOD}/ install — wrong volume?"
    exit 1
  fi
  if [[ -f "${VOLUME_VERSIONS}" ]] && cmp -s "${IMAGE_VERSIONS}" "${VOLUME_VERSIONS}"; then
    log "existing server volume found — stack matches the image, keeping it"
  else
    log "existing server volume found — image stack differs, refreshing the stack-owned files"
    sync_stack
  fi
fi

# --- 2. render env-driven config --------------------------------------------
# server.cfg — template + a generated env-override block (last wins in HLDS).
render_server_cfg() {
  local out="${GAMEDIR}/server.cfg"
  cat "${TEMPLATES}/server.cfg" > "${out}"
  {
    echo
    echo "// ============================================================="
    echo "//  Container environment overrides — generated on every start."
    echo "//  These run last, so they win over the values above."
    echo "// ============================================================="
    echo "hostname \"${SERVER_NAME:-ReHLDS ${GAME_TITLE}}\""
    echo "rcon_password \"${RCON_PASSWORD:-}\""
    echo "sv_password \"${SERVER_PASSWORD:-}\""
    echo "sv_contact \"${SV_CONTACT:-}\""
    echo "sv_lan ${SV_LAN:-0}"
    echo "sv_region ${SV_REGION:-255}"
    [[ -n "${SV_DOWNLOADURL:-}" ]] && echo "sv_downloadurl \"${SV_DOWNLOADURL}\""
    if [[ -n "${LOG_ADDRESS:-}" ]]; then
      echo "log on"
      echo "logaddress_add ${LOG_ADDRESS/:/ }"
    fi
    # Bot tuning is NOT set here — BOTS_ENABLED only gates whether the game's
    # bot loads (via plugins.ini). Bot count/difficulty stay at the bot's stock
    # defaults; tune them by editing the bot's own config in the volume.
    echo
    echo "// User overrides — edit ${GAME_MOD}/server-custom.cfg (persisted, exec'd last)."
    echo "exec server-custom.cfg"
  } >> "${out}"
  log "rendered ${GAME_MOD}/server.cfg"
}

# Metamod plugins.ini — toggle the bot / Reunion lines per env.
render_plugins_ini() {
  local out="${GAMEDIR}/addons/metamod/plugins.ini"
  local line
  mkdir -p "$(dirname "${out}")"
  : > "${out}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      ';@reunion@ '*)
        [[ "${REUNION_ENABLED:-false}" == "true" ]] && echo "${line#;@reunion@ }" >> "${out}"
        ;;
      ';@bot@ '*)
        [[ "${BOTS_ENABLED:-true}" == "true" ]] && echo "${line#;@bot@ }" >> "${out}"
        ;;
      *) echo "${line}" >> "${out}" ;;
    esac
  done < "${TEMPLATES}/plugins.ini"
  log "rendered Metamod plugins.ini (bots=${BOTS_ENABLED:-true} [${GAME_BOT}${GAME_BOT_START_PARAMS:+, by start parameter}] reunion=${REUNION_ENABLED:-false})"
}

# Reunion config — only when Reunion is enabled.
render_reunion() {
  [[ "${REUNION_ENABLED:-false}" == "true" ]] || return 0
  local out="${GAMEDIR}/reunion.cfg"
  local salt="${REUNION_HASH_SALT:-}"
  if [[ -z "${salt}" ]]; then
    if [[ -f "${SALT_FILE}" ]]; then
      salt="$(cat "${SALT_FILE}")"
    else
      salt="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
      echo "${salt}" > "${SALT_FILE}"
      log "generated a persistent Reunion hash salt"
    fi
  fi
  local cid="${REUNION_NOSTEAM_CID:-3}"
  sed -e "s#^SteamIdHashSalt .*#SteamIdHashSalt = ${salt}#" \
      -e "s#^cid_NoSteam47 .*#cid_NoSteam47 = ${cid}#" \
      -e "s#^cid_NoSteam48 .*#cid_NoSteam48 = ${cid}#" \
      "${TEMPLATES}/reunion.cfg" > "${out}"
  log "rendered ${GAME_MOD}/reunion.cfg"
}

# AMX Mod X users.ini — bootstrap the OWNER SteamID as a full admin.
# users.ini is a seeded, operator-editable file. We rewrite only a marked block
# in it on every start, so the OWNER tracks the env var while any other admins
# the operator adds to the file persist untouched. Empty OWNER => no block.
render_admins() {
  local out="${GAMEDIR}/addons/amxmodx/configs/users.ini"
  local begin="; >>> OWNER admin — managed by the container (OWNER env var) >>>"
  local end="; <<< OWNER admin — managed by the container <<<"
  mkdir -p "$(dirname "${out}")"
  [[ -e "${out}" ]] || : > "${out}"

  # Strip any previously-managed OWNER block (exact line match, no regex).
  awk -v b="${begin}" -v e="${end}" '
    $0 == b { drop = 1 }
    !drop   { print }
    $0 == e { drop = 0 }
  ' "${out}" > "${out}.tmp" && mv "${out}.tmp" "${out}"

  if [[ -z "${OWNER:-}" ]]; then
    log "rendered users.ini — no OWNER set (env var empty)"
    return 0
  fi
  if [[ "${OWNER}" != STEAM_* ]]; then
    log "WARNING: OWNER='${OWNER}' does not look like a SteamID (STEAM_x:y:z)"
  fi
  {
    echo "${begin}"
    echo "; Full AMX Mod X admin (all command flags + immunity), SteamID auth."
    echo "; To change the owner, edit OWNER in the env file — do not edit this block."
    echo "\"${OWNER}\" \"\" \"abcdefghijklmnopqrstu\" \"ce\""
    echo "${end}"
  } >> "${out}"
  log "rendered users.ini — OWNER ${OWNER} bootstrapped as full admin"
}

# server-custom.cfg — operator's own server cvars; seeded once, never overwritten.
seed_server_custom() {
  local f="${GAMEDIR}/server-custom.cfg"
  local legacy="${GAMEDIR}/serverextra.cfg"
  # Migrate the pre-rename file if an older volume still has serverextra.cfg,
  # so operator cvars are not orphaned across the rename.
  if [[ -e "${legacy}" && ! -e "${f}" ]]; then
    mv "${legacy}" "${f}"
    log "migrated ${GAME_MOD}/serverextra.cfg -> server-custom.cfg"
    return 0
  fi
  [[ -e "${f}" ]] && return 0
  cat > "${f}" <<'CEOF'
// server-custom.cfg — your own custom server cvars go here.
// This file is exec'd last (after server.cfg) and is never overwritten by the
// container, so values set here win and persist across updates and restarts.
CEOF
  log "seeded ${GAME_MOD}/server-custom.cfg"
}

# Prune old log files from the volume. Two sinks grow without bound and nothing
# else rotates them: the engine writes a new <game>/logs/L*.log on every map
# change (log on + sv_log_onefile 0), and AMX Mod X writes a new
# addons/amxmodx/logs/*.log every day. Gated by LOG_RETENTION_DAYS: a positive
# integer deletes *.log files older than that many days from those two dirs;
# empty / 0 / unset keeps everything (no pruning). The separate stdout copy of
# the console log is capped by the compose `logging:` json-file block, not here.
prune_logs() {
  local days="${LOG_RETENTION_DAYS:-}"
  if [[ -z "${days}" || "${days}" == "0" ]]; then
    log "log pruning disabled (LOG_RETENTION_DAYS empty/0) — in-volume logs kept"
    return 0
  fi
  if ! [[ "${days}" =~ ^[0-9]+$ ]]; then
    log "WARNING: LOG_RETENTION_DAYS='${days}' is not a non-negative integer — skipping log pruning"
    return 0
  fi
  local dir n total=0
  for dir in "${GAMEDIR}/logs" "${GAMEDIR}/addons/amxmodx/logs"; do
    [[ -d "${dir}" ]] || continue
    n=$(find "${dir}" -type f -name '*.log' -mtime "+${days}" -print -delete 2>/dev/null | wc -l)
    total=$((total + n))
  done
  log "pruned ${total} log file(s) older than ${days}d (LOG_RETENTION_DAYS)"
}

render_server_cfg
render_plugins_ini
render_reunion
render_admins
seed_server_custom
prune_logs

# --- 3. fix ownership/perms and hand off to HLDS ----------------------------
# Two supported starts:
#   * as root (image default): fix volume ownership, then drop to "steam" via
#     gosu so HLDS runs unprivileged;
#   * already as the unprivileged user (compose `user: "1000:1000"`): there is
#     nothing to chown and nothing to drop, and no root process ever exists.
#     The ./serverdata/<name> directory must then already be owned by uid 1000
#     (any volume that has had a root start is; pre-create a brand-new one
#     with that owner, or seed it once without `user:`).
if [[ "$(id -u)" -eq 0 ]]; then
  chown -R "${RUN_USER}:${RUN_USER}" "${SERVER}"
  RUN_AS=(gosu "${RUN_USER}")
else
  RUN_AS=()
  log "started as uid $(id -u): no ownership fix, no privilege drop"
fi
# Self-heal modes (defensive): every directory must be owner-traversable, and
# the engine binaries must be executable.
find "${SERVER}" -type d -exec chmod 0755 {} + 2>/dev/null || true
for bin in hlds_run hlds_linux; do
  [[ -f "${SERVER}/${bin}" ]] && chmod 0755 "${SERVER}/${bin}"
done

PORT="${SERVER_PORT:-27015}"
CLIENTPORT="${CLIENT_PORT:-27005}"
MAP="${DEFAULT_MAP:-${GAME_DEFAULT_MAP}}"
MAXPLAYERS="${MAX_PLAYERS:-${GAME_DEFAULT_MAXPLAYERS}}"
EXTRA="${EXTRA_START_PARAMS:-${GAME_DEFAULT_START_PARAMS}}"
# A bot that is not a Metamod plugin is loaded by a start parameter instead of
# the @bot@ line (Marine Bot for dod: +localinfo mm_gamedll ...). It follows
# BOTS_ENABLED like the plugin line and is kept apart from EXTRA_START_PARAMS,
# so setting those never drops the bot. Empty for games whose bot is a plugin.
BOT_PARAMS=""
[[ "${BOTS_ENABLED:-true}" == "true" ]] && BOT_PARAMS="${GAME_BOT_START_PARAMS:-}"

log "starting HLDS — game ${GAME_MOD}, map ${MAP}, port ${PORT}, ${MAXPLAYERS} slots"
echo

cd "${SERVER}"
# hlds_run -norestart exec()s hlds_linux directly, so HLDS becomes the
# container's main process and receives SIGTERM cleanly on `docker stop`.
# Docker's restart policy replaces hlds_run's auto-restart loop.
#
# +localinfo mm_clientmeta yes re-enables Metamod's client-facing commands
# ('meta list' / 'meta version' typed in a connected player's console). The
# vendored Metamod-R config.ini ships with `clientmeta no`, so without this a
# connected client gets "Unknown command". Set as a localinfo override (not a
# config.ini edit) so it survives Metamod-R version bumps, which replace
# config.ini wholesale. Does not affect the server-console / rcon `meta` path.
exec "${RUN_AS[@]}" ./hlds_run \
  -norestart \
  -game "${GAME_MOD}" \
  -strictportbind \
  +ip 0.0.0.0 \
  -port "${PORT}" \
  +clientport "${CLIENTPORT}" \
  +map "${MAP}" \
  +servercfgfile server.cfg \
  -maxplayers "${MAXPLAYERS}" \
  +localinfo mm_clientmeta yes \
  ${BOT_PARAMS} \
  ${EXTRA}
