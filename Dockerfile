# syntax=docker/dockerfile:1.7
#
# ReHLDS Counter-Strike 1.6 server image.
#
#   Stage 1 (server-builder): install CS 1.6 via SteamCMD (steam_legacy branch)
#                             and apply the ReHLDS stack onto it.
#   Stage 2 (runtime):        a lean image with the finished server baked in
#                             and a plain entrypoint that just runs it.
#
# The ReHLDS stack is applied at BUILD time, so the running container never
# re-runs SteamCMD and nothing can ever clobber the engine. Every version is
# pinned via ARG for reproducible builds — see CHANGELOG.md.

# --- Base: a clean SteamCMD image (Debian, 32-bit libs for GoldSrc) ----------
ARG BASE_IMAGE=cm2network/steamcmd
ARG BASE_DIGEST=sha256:45f6515d6c4dcde659c9ad6872bdbeacd1bf5c4e7f241829c4d2f28fb5eda581

###############################################################################
# Stage 1 — server-builder
###############################################################################
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS server-builder

# SteamCMD branch for HLDS appid 90. "steam_legacy" is the pre-25th-anniversary
# HLDS that the ReHLDS engine is compatible with — do not change without reason.
ARG STEAM_BRANCH=steam_legacy

# --- Pinned component versions ----------------------------------------------
ARG REHLDS_VERSION=3.14.0.857
ARG REGAMEDLL_VERSION=5.28.0.756
ARG METAMOD_VERSION=1.3.0.149
ARG AMXX_VERSION=1.9.0
ARG AMXX_BUILD=5303
ARG REAPI_VERSION=5.26.0.338
ARG YAPB_VERSION=4.4.957
ARG REUNION_VERSION=0.2.0.25

# --- Pinned SHA256 checksums of the release assets --------------------------
ARG REHLDS_SHA256=8e0bb2b36c70896f94f1ab642eeed17dcc1b345045cf076aabd64a0a67a4b733
ARG REGAMEDLL_SHA256=e9197ada843de6df4ed74cfe7b22bf5d93ba9e0c7b66490ca682120761978732
ARG METAMOD_SHA256=ede7f59c4e0220afe8c02aa348a130cce527f87d36ffdb674e37a501ce57be94
ARG AMXX_BASE_SHA256=1ed6898ced2c1fcf225c288b94effc19917e987b284e42911587738ee3c93699
ARG AMXX_CSTRIKE_SHA256=a2a5ef44bb366a90adf432c708ac49eb63b4b44d7b0de123e8cd52395d27b8e9
ARG REAPI_SHA256=0f39de7428aacd0fc6890eab0af62c616b592408dd7ab8e91aa53787fba9e08d
ARG YAPB_SHA256=8c095ac89b9b2ccc70a66a71d608e1a570b5268c57c6083ced8c06161533a4b1
ARG REUNION_SHA256=0f238276719274216bd169c578eac2db4e041946b8b9f0e407e41ef9d85efdf5

# --- GPG verification of the ReHLDS signature -------------------------------
ARG GPG_VERIFY=true
ARG REHLDS_GPG_FINGERPRINT=63547829004F07716F7BE4856C32C4282E60FB67

# Promote build-args to env so build-server.sh can read them.
ENV STEAM_BRANCH=${STEAM_BRANCH} \
    REHLDS_VERSION=${REHLDS_VERSION} \
    REGAMEDLL_VERSION=${REGAMEDLL_VERSION} \
    METAMOD_VERSION=${METAMOD_VERSION} \
    AMXX_VERSION=${AMXX_VERSION} \
    AMXX_BUILD=${AMXX_BUILD} \
    REAPI_VERSION=${REAPI_VERSION} \
    YAPB_VERSION=${YAPB_VERSION} \
    REUNION_VERSION=${REUNION_VERSION} \
    REHLDS_SHA256=${REHLDS_SHA256} \
    REGAMEDLL_SHA256=${REGAMEDLL_SHA256} \
    METAMOD_SHA256=${METAMOD_SHA256} \
    AMXX_BASE_SHA256=${AMXX_BASE_SHA256} \
    AMXX_CSTRIKE_SHA256=${AMXX_CSTRIKE_SHA256} \
    REAPI_SHA256=${REAPI_SHA256} \
    YAPB_SHA256=${YAPB_SHA256} \
    REUNION_SHA256=${REUNION_SHA256} \
    GPG_VERIFY=${GPG_VERIFY} \
    REHLDS_GPG_FINGERPRINT=${REHLDS_GPG_FINGERPRINT}

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         curl ca-certificates unzip xz-utils gnupg python3 \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /build/curated && chown -R steam:steam /build
COPY --chown=steam:steam scripts/build-server.sh        /build/build-server.sh
COPY --chown=steam:steam scripts/clear-execstack.py     /build/clear-execstack.py
COPY --chown=steam:steam config/rehlds-signing-key.asc  /build/curated/rehlds-signing-key.asc
COPY --chown=steam:steam config/amxx.cfg                /build/curated/amxx.cfg
COPY --chown=steam:steam config/yapb-overlay.cfg        /build/curated/yapb-overlay.cfg

# SteamCMD must not run as root.
USER steam
RUN bash /build/build-server.sh

###############################################################################
# Stage 2 — runtime
###############################################################################
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS runtime

ARG REHLDS_VERSION=3.14.0.857
ARG REGAMEDLL_VERSION=5.28.0.756
ARG METAMOD_VERSION=1.3.0.149
ARG AMXX_VERSION=1.9.0
ARG AMXX_BUILD=5303
ARG REAPI_VERSION=5.26.0.338
ARG YAPB_VERSION=4.4.957
ARG REUNION_VERSION=0.2.0.25

LABEL org.opencontainers.image.title="rehlds-csserver" \
      org.opencontainers.image.description="Counter-Strike 1.6 dedicated server on the ReHLDS engine stack" \
      rehlds.version="${REHLDS_VERSION}" \
      regamedll.version="${REGAMEDLL_VERSION}" \
      metamod.version="${METAMOD_VERSION}" \
      amxmodx.version="${AMXX_VERSION}.${AMXX_BUILD}" \
      reapi.version="${REAPI_VERSION}" \
      yapb.version="${YAPB_VERSION}" \
      reunion.version="${REUNION_VERSION}"

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         python3 gosu ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The finished server, baked in as an immutable reference copy.
COPY --from=server-builder /build/serverfiles /opt/cs16/serverfiles-base
COPY --from=server-builder /build/VERSIONS    /opt/cs16/VERSIONS

# Runtime scripts and env-rendered config templates.
COPY scripts/entrypoint.sh   /opt/cs16/entrypoint.sh
COPY scripts/healthcheck.sh  /opt/cs16/healthcheck.sh
COPY scripts/rcon            /opt/cs16/rcon
COPY config/server.cfg       /opt/cs16/templates/server.cfg
COPY config/plugins.ini      /opt/cs16/templates/plugins.ini
COPY config/reunion.cfg      /opt/cs16/templates/reunion.cfg

RUN chmod +x /opt/cs16/entrypoint.sh /opt/cs16/healthcheck.sh /opt/cs16/rcon \
    && ln -sf /opt/cs16/rcon /usr/local/bin/rcon

# A2S-query healthcheck — confirms the server answers Steam queries.
HEALTHCHECK --interval=60s --timeout=15s --start-period=90s --retries=3 \
  CMD /opt/cs16/healthcheck.sh

# The server runs out of /server (a volume; seeded from the baked copy on
# first start). The entrypoint starts as root to fix volume ownership, then
# drops to the unprivileged "steam" user.
WORKDIR /server
ENTRYPOINT ["/opt/cs16/entrypoint.sh"]
