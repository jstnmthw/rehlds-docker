# syntax=docker/dockerfile:1.7
#
# ReHLDS GoldSrc dedicated server — one Dockerfile, one image per game.
#
#   docker build --build-arg GAME=cstrike -t rehlds-cstrike:local .   (default)
#   docker build --build-arg GAME=tfc     -t rehlds-tfc:local .
#   docker build --build-arg GAME=dod     -t rehlds-dod:local .
#
#   Stage 1 (server-builder): install the game via SteamCMD (HLDS appid 90,
#                             steam_legacy branch) and apply the ReHLDS stack
#                             onto it, as described by profiles/<GAME>.sh.
#   Stage 2 (runtime):        a lean image with the finished server baked in
#                             and a plain entrypoint that just runs it.
#
# The ReHLDS stack is applied at BUILD time, so the running container never
# re-runs SteamCMD and nothing can ever clobber the engine. Every version is
# pinned via ARG for reproducible builds — see CHANGELOG.md. Components with a
# stable upstream release URL are downloaded at build time; the rest (the bots)
# are vendored under vendor/ and referenced here by file name + SHA256.

# --- Base: a clean SteamCMD image (Debian, 32-bit libs for GoldSrc) ----------
ARG BASE_IMAGE=cm2network/steamcmd
ARG BASE_DIGEST=sha256:45f6515d6c4dcde659c9ad6872bdbeacd1bf5c4e7f241829c4d2f28fb5eda581

###############################################################################
# Stage 1 — server-builder
###############################################################################
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS server-builder

# Build tools first, before any game-specific ARG/ENV, so this layer is shared
# by every game's build.
USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         curl ca-certificates unzip xz-utils gnupg python3 \
    && rm -rf /var/lib/apt/lists/*

# Which game this image is for: cstrike | tfc | dod (one profiles/<GAME>.sh each).
ARG GAME=cstrike

# SteamCMD branch for HLDS appid 90. "steam_legacy" is the pre-25th-anniversary
# HLDS that the ReHLDS engine is compatible with — do not change without reason.
ARG STEAM_BRANCH=steam_legacy

# --- Pinned component versions — shared by every game ----------------------
ARG REHLDS_VERSION=3.14.0.857
ARG METAMOD_VERSION=1.3.0.149
ARG AMXX_VERSION=1.10.0
ARG AMXX_BUILD=5476
ARG REUNION_VERSION=0.2.0.25

# --- Counter-Strike (GAME=cstrike) -----------------------------------------
ARG REGAMEDLL_VERSION=5.28.0.756
ARG REAPI_VERSION=5.26.0.338
# YaPB is vendored (vendor/): upstream stopped tagging after 4.4.957 and its
# rolling `continuous` release deletes the previous assets on every push, so
# the pinned build is kept in the repository and referenced by file name.
ARG YAPB_VERSION=4.8.1311
ARG YAPB_ARCHIVE=yapb-4.8.1311-linux.tar.xz

# --- Team Fortress Classic (GAME=tfc) --------------------------------------
# FoxBot, vendored (upstream: GitHub release v0.911 of APGRoboCop/foxbot).
ARG FOXBOT_VERSION=0.911
ARG FOXBOT_ARCHIVE=foxbot_0911.zip

# --- Day of Defeat (GAME=dod) ----------------------------------------------
# Marine Bot 0.97 Beta, DoD edition (GPL, SourceForge), vendored with its
# source; plus Martee's waypoint pack for it (downloads.sturmbot.org).
ARG MARINEBOT_VERSION=0.97b
ARG MARINEBOT_ARCHIVE=mb097-dod.zip
ARG MARINEBOT_WAYPOINTS_VERSION=v2
ARG MARINEBOT_WAYPOINTS_ARCHIVE=martee_dod_waypoint_pack_v2.zip

# --- Pinned SHA256 checksums of every archive (downloaded or vendored) ------
ARG REHLDS_SHA256=8e0bb2b36c70896f94f1ab642eeed17dcc1b345045cf076aabd64a0a67a4b733
ARG METAMOD_SHA256=ede7f59c4e0220afe8c02aa348a130cce527f87d36ffdb674e37a501ce57be94
ARG AMXX_BASE_SHA256=cd99e956b02b4818324f3ed5a624d7cea8f00ef6593974bb97d912ae7591ec73
ARG AMXX_CSTRIKE_SHA256=4af2ce169be4ffdd9a33be89d25f18967395b72433333aa900549d5bf0b4d508
ARG AMXX_TFC_SHA256=b5a0d30a353e7150ef9ce4d6b8eb416fde98aeefb7ba671924517e3c34b205a4
ARG AMXX_DOD_SHA256=5e1b5b1331a744ab63bf85f33eb343a4e29cdf899cd6e3922ca4aa9237c3061c
ARG REUNION_SHA256=0f238276719274216bd169c578eac2db4e041946b8b9f0e407e41ef9d85efdf5
ARG REGAMEDLL_SHA256=e9197ada843de6df4ed74cfe7b22bf5d93ba9e0c7b66490ca682120761978732
ARG REAPI_SHA256=0f39de7428aacd0fc6890eab0af62c616b592408dd7ab8e91aa53787fba9e08d
ARG YAPB_SHA256=085653b21f9a395f2a443d35c65aa155a86618a3f67926dc3933ca527aa0aebb
ARG FOXBOT_SHA256=eea631c7c1a1ca59af915c8f63cb6fbcd8cc4d7008f490b9a2c0ab175d5cb25a
ARG MARINEBOT_SHA256=783994f80543156eec4872ca67ee473c4c2df9665bac226177d6281d500cb497
ARG MARINEBOT_WAYPOINTS_SHA256=8ac386ac42efdb0be36c1adefa46862ea2b6cdd4b4b0325c37f434f41f5ea71e

# --- GPG verification of the ReHLDS signature -------------------------------
ARG GPG_VERIFY=true
ARG REHLDS_GPG_FINGERPRINT=63547829004F07716F7BE4856C32C4282E60FB67

# Promote build-args to env so build-server.sh and the profile can read them.
ENV GAME=${GAME} \
    STEAM_BRANCH=${STEAM_BRANCH} \
    REHLDS_VERSION=${REHLDS_VERSION} \
    METAMOD_VERSION=${METAMOD_VERSION} \
    AMXX_VERSION=${AMXX_VERSION} \
    AMXX_BUILD=${AMXX_BUILD} \
    REUNION_VERSION=${REUNION_VERSION} \
    REGAMEDLL_VERSION=${REGAMEDLL_VERSION} \
    REAPI_VERSION=${REAPI_VERSION} \
    YAPB_VERSION=${YAPB_VERSION} \
    YAPB_ARCHIVE=${YAPB_ARCHIVE} \
    FOXBOT_VERSION=${FOXBOT_VERSION} \
    FOXBOT_ARCHIVE=${FOXBOT_ARCHIVE} \
    MARINEBOT_VERSION=${MARINEBOT_VERSION} \
    MARINEBOT_ARCHIVE=${MARINEBOT_ARCHIVE} \
    MARINEBOT_WAYPOINTS_VERSION=${MARINEBOT_WAYPOINTS_VERSION} \
    MARINEBOT_WAYPOINTS_ARCHIVE=${MARINEBOT_WAYPOINTS_ARCHIVE} \
    REHLDS_SHA256=${REHLDS_SHA256} \
    METAMOD_SHA256=${METAMOD_SHA256} \
    AMXX_BASE_SHA256=${AMXX_BASE_SHA256} \
    AMXX_CSTRIKE_SHA256=${AMXX_CSTRIKE_SHA256} \
    AMXX_TFC_SHA256=${AMXX_TFC_SHA256} \
    AMXX_DOD_SHA256=${AMXX_DOD_SHA256} \
    REUNION_SHA256=${REUNION_SHA256} \
    REGAMEDLL_SHA256=${REGAMEDLL_SHA256} \
    REAPI_SHA256=${REAPI_SHA256} \
    YAPB_SHA256=${YAPB_SHA256} \
    FOXBOT_SHA256=${FOXBOT_SHA256} \
    MARINEBOT_SHA256=${MARINEBOT_SHA256} \
    MARINEBOT_WAYPOINTS_SHA256=${MARINEBOT_WAYPOINTS_SHA256} \
    GPG_VERIFY=${GPG_VERIFY} \
    REHLDS_GPG_FINGERPRINT=${REHLDS_GPG_FINGERPRINT}

RUN mkdir -p /build/curated && chown -R steam:steam /build
COPY --chown=steam:steam scripts/build-server.sh        /build/build-server.sh
COPY --chown=steam:steam scripts/clear-execstack.py     /build/clear-execstack.py
COPY --chown=steam:steam scripts/stack-manifest.py      /build/stack-manifest.py
COPY --chown=steam:steam config/rehlds-signing-key.asc  /build/curated/rehlds-signing-key.asc
COPY --chown=steam:steam profiles/                      /build/profiles/
COPY --chown=steam:steam vendor/                        /build/vendor/

# SteamCMD must not run as root.
USER steam
RUN bash /build/build-server.sh

###############################################################################
# Stage 2 — runtime
###############################################################################
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS runtime

ARG GAME=cstrike
ARG REHLDS_VERSION=3.14.0.857
ARG METAMOD_VERSION=1.3.0.149
ARG AMXX_VERSION=1.10.0
ARG AMXX_BUILD=5476
ARG REUNION_VERSION=0.2.0.25

# The shared stack is labelled; the per-game components (game library, bot)
# are listed in /opt/hlds/VERSIONS, printed by the entrypoint banner.
LABEL org.opencontainers.image.title="rehlds-${GAME}" \
      org.opencontainers.image.description="GoldSrc ${GAME} dedicated server on the ReHLDS engine stack" \
      hlds.game="${GAME}" \
      rehlds.version="${REHLDS_VERSION}" \
      metamod.version="${METAMOD_VERSION}" \
      amxmodx.version="${AMXX_VERSION}.${AMXX_BUILD}" \
      reunion.version="${REUNION_VERSION}"

# Visible to the entrypoint and to `docker inspect`; the entrypoint takes the
# game itself from the baked profile below, not from this variable.
ENV GAME=${GAME}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         python3 gosu ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The finished server, baked in as an immutable reference copy, plus the record
# of what the build pinned (VERSIONS) and which files the stack owns
# (STACK-MANIFEST — the entrypoint refreshes exactly those in an existing volume).
COPY --from=server-builder /build/serverfiles     /opt/hlds/serverfiles-base
COPY --from=server-builder /build/VERSIONS        /opt/hlds/VERSIONS
COPY --from=server-builder /build/STACK-MANIFEST  /opt/hlds/STACK-MANIFEST

# Runtime scripts, this game's profile, and the env-rendered config templates.
COPY scripts/entrypoint.sh scripts/healthcheck.sh scripts/rcon  /opt/hlds/
COPY profiles/${GAME}.sh                                        /opt/hlds/profile.sh
COPY config/${GAME}/server.cfg config/${GAME}/plugins.ini config/reunion.cfg  /opt/hlds/templates/

# /server is the volume mount point. Creating it owned by the unprivileged user
# lets a fresh named volume inherit that ownership, so a container started as
# uid 1000 (the compose templates) can seed it without a root start.
RUN chmod +x /opt/hlds/entrypoint.sh /opt/hlds/healthcheck.sh /opt/hlds/rcon \
    && ln -sf /opt/hlds/rcon /usr/local/bin/rcon \
    && mkdir -p /server && chown steam:steam /server

# A2S-query healthcheck — confirms the server answers Steam queries.
HEALTHCHECK --interval=60s --timeout=15s --start-period=90s --retries=3 \
  CMD /opt/hlds/healthcheck.sh

# The server runs out of /server (a volume; seeded from the baked copy on
# first start). Started as root, the entrypoint fixes volume ownership and
# drops to the unprivileged "steam" user; started as that user already, it
# runs HLDS directly.
WORKDIR /server
ENTRYPOINT ["/opt/hlds/entrypoint.sh"]
