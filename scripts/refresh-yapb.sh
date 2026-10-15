#!/usr/bin/env bash
# Copy the image's YaPB component into an existing server volume.
#
#   scripts/refresh-yapb.sh <server-name> [image]      (default image: rehlds-csserver:local)
#
# The entrypoint seeds /server from the image once and never refreshes it, so a
# rebuilt image with a newer YaPB does not reach an existing volume: HLDS keeps
# loading the old addons/yapb/bin/yapb.so from the volume. This copies the
# image's addons/yapb tree over the volume's, except conf/yapb.cfg (operator
# tuning; see migrate-yapb-cfg.py) and data/train (learned data, regenerated).
# Files are unlinked and recreated, so a running server keeps its mapped old
# binary until it is restarted: run this, then `docker compose restart <name>`
# while the server is empty. The previous yapb.so is kept as yapb.so.bak-<date>.
set -euo pipefail
name="${1:?usage: $0 <server-name> [image]}"
image="${2:-rehlds-csserver:local}"
vol="$(pwd)/serverdata/${name}/cstrike/addons/yapb"
[[ -d "${vol}/bin" ]] || { echo "no YaPB tree at ${vol}" >&2; exit 1; }
src=/opt/cs16/serverfiles-base/cstrike/addons/yapb
stamp="$(date +%F)"
cp -p "${vol}/bin/yapb.so" "${vol}/bin/yapb.so.bak-${stamp}"
docker run --rm -u "$(id -u):$(id -g)" --entrypoint sh -v "${vol}:/dst" "${image}" -c \
  "cd ${src} && tar --exclude=./conf/yapb.cfg --exclude=./data/train -cf - . | tar -C /dst -xf -"
want="$(docker run --rm --entrypoint sha256sum "${image}" "${src}/bin/yapb.so" | cut -d' ' -f1)"
have="$(sha256sum "${vol}/bin/yapb.so" | cut -d' ' -f1)"
[[ "${want}" == "${have}" ]] || { echo "yapb.so mismatch after copy" >&2; exit 1; }
echo "${name}: addons/yapb refreshed from ${image} (yapb.so ${have:0:12}, backup yapb.so.bak-${stamp}); restart the server to load it"
