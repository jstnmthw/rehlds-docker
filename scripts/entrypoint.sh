#!/usr/bin/env bash
#
# entrypoint.sh — container entrypoint for the ReHLDS CS 1.6 server.
#
# Starts as root. It:
#   1. seeds the /server volume from the baked-in server copy on first run,
#   2. renders the env-driven config (server.cfg, Metamod plugins.ini,
#      reunion.cfg, AMX Mod X users.ini) into the serverfiles,
#   3. drops to the unprivileged "steam" user and execs HLDS.
#
# There is no update machinery: the ReHLDS stack was applied at build time.
#
set -uo pipefail

BASE=/opt/cs16/serverfiles-base     # immutable baked-in server copy
TEMPLATES=/opt/cs16/templates
SERVER=/server                      # working serverfiles (a volume)
GAMEDIR="${SERVER}/cstrike"
SALT_FILE="${SERVER}/.reunion-salt"
RUN_USER=steam

log() { echo "[entrypoint] $*"; }

# --- banner ------------------------------------------------------------------
echo
echo "================================================================================"
echo " ReHLDS Counter-Strike 1.6 server"
echo "================================================================================"
if [[ -f /opt/cs16/VERSIONS ]]; then
  while IFS= read -r line; do [[ -n "${line}" ]] && echo "   ${line}"; done < /opt/cs16/VERSIONS
fi
echo "================================================================================"
echo

if [[ ! -d "${BASE}" ]] || [[ -z "$(ls -A "${BASE}" 2>/dev/null)" ]]; then
  log "FATAL: baked server copy missing (${BASE}) — image built incorrectly"
  exit 1
fi

# --- 1. seed the /server volume on first run --------------------------------
mkdir -p "${SERVER}"
if [[ -z "$(ls -A "${SERVER}" 2>/dev/null)" ]]; then
  log "first run — seeding ${SERVER} from the baked server copy"
  cp -a "${BASE}/." "${SERVER}/"
  log "seeded $(find "${SERVER}" -type f | wc -l) files"
else
  log "existing server volume found — keeping it (delete the volume to reset)"
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
    echo "hostname \"${SERVER_NAME:-ReHLDS Counter-Strike 1.6}\""
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
    if [[ "${BOTS_ENABLED:-true}" == "true" ]]; then
      echo "// YaPB bots enabled"
      echo "yb_quota ${BOT_QUOTA:-6}"
      echo "yb_quota_mode \"${BOT_QUOTA_MODE:-fill}\""
      echo "yb_difficulty ${BOT_DIFFICULTY:-3}"
      echo "yb_autovacate 1"
    else
      echo "// YaPB bots disabled (BOTS_ENABLED=false)"
    fi
    echo
    echo "// User overrides — edit cstrike/serverextra.cfg (persisted, exec'd last)."
    echo "exec serverextra.cfg"
  } >> "${out}"
  log "rendered cstrike/server.cfg"
}

# Metamod plugins.ini — toggle the YaPB / Reunion lines per env.
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
      ';@yapb@ '*)
        [[ "${BOTS_ENABLED:-true}" == "true" ]] && echo "${line#;@yapb@ }" >> "${out}"
        ;;
      *) echo "${line}" >> "${out}" ;;
    esac
  done < "${TEMPLATES}/plugins.ini"
  log "rendered Metamod plugins.ini (bots=${BOTS_ENABLED:-true} reunion=${REUNION_ENABLED:-false})"
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
  log "rendered cstrike/reunion.cfg"
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
    echo "; To change the owner, edit OWNER in .env — do not edit this block."
    echo "\"${OWNER}\" \"\" \"abcdefghijklmnopqrstu\" \"ce\""
    echo "${end}"
  } >> "${out}"
  log "rendered users.ini — OWNER ${OWNER} bootstrapped as full admin"
}

# serverextra.cfg — operator's own cvars; seeded once, never overwritten.
seed_serverextra() {
  local f="${GAMEDIR}/serverextra.cfg"
  [[ -e "${f}" ]] && return 0
  cat > "${f}" <<'EOF'
// serverextra.cfg — your own custom cvars go here.
// This file is exec'd last (after server.cfg) and is never overwritten by the
// container, so values set here win and persist across updates and restarts.
EOF
  log "seeded cstrike/serverextra.cfg"
}

render_server_cfg
render_plugins_ini
render_reunion
render_admins
seed_serverextra

# --- 3. fix ownership/perms and hand off to HLDS ----------------------------
chown -R "${RUN_USER}:${RUN_USER}" "${SERVER}"
# Self-heal modes (defensive): every directory must be owner-traversable, and
# the engine binaries must be executable.
find "${SERVER}" -type d -exec chmod 0755 {} + 2>/dev/null || true
for bin in hlds_run hlds_linux; do
  [[ -f "${SERVER}/${bin}" ]] && chmod 0755 "${SERVER}/${bin}"
done

PORT="${SERVER_PORT:-27015}"
CLIENTPORT="${CLIENT_PORT:-27005}"
MAP="${DEFAULT_MAP:-de_dust2}"
MAXPLAYERS="${MAX_PLAYERS:-16}"
EXTRA="${EXTRA_START_PARAMS:--pingboost 1 +sys_ticrate 1000}"

log "starting HLDS — map ${MAP}, port ${PORT}, ${MAXPLAYERS} slots"
echo

cd "${SERVER}"
# hlds_run -norestart exec()s hlds_linux directly, so HLDS becomes the
# container's main process and receives SIGTERM cleanly on `docker stop`.
# Docker's restart policy replaces hlds_run's auto-restart loop.
exec gosu "${RUN_USER}" ./hlds_run \
  -norestart \
  -game cstrike \
  -strictportbind \
  +ip 0.0.0.0 \
  -port "${PORT}" \
  +clientport "${CLIENTPORT}" \
  +map "${MAP}" \
  +servercfgfile server.cfg \
  -maxplayers "${MAXPLAYERS}" \
  ${EXTRA}
