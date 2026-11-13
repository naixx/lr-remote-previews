# syntax=docker/dockerfile:1
#
# LR Remote Previews server image. Build from the repository root:
#
#     docker build -f deploy/Dockerfile -t lr-remote-previews .
#
# Adobe DNG Converter is not part of this image; the user installs it into the Wine prefix
# (see docs/converter.md).

# --- Dashboard -------------------------------------------------------------------------------
FROM node:22-bookworm-slim AS web

WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# --- Server ----------------------------------------------------------------------------------
# Debian 12, because its Wine 8.0 (64-bit only) is the version the converter was proven on.
FROM debian:bookworm-slim

ARG LRRP_UID=1000
ARG LRRP_GID=1000
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        python3 \
        python3-venv \
        tini \
        wine \
        wine64 \
        xauth \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

COPY server/ /tmp/server/
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --disable-pip-version-check /tmp/server \
    && rm -rf /tmp/server

COPY --from=web /src/web/dist/ /app/web/

COPY deploy/entrypoint.sh /usr/local/bin/lrrp-entrypoint
# The user's uid:gid can also be changed at run time (compose `user:`); --non-unique allows ids
# that the base image already uses.
RUN sed -i 's/\r$//' /usr/local/bin/lrrp-entrypoint \
    && chmod 0755 /usr/local/bin/lrrp-entrypoint \
    && groupadd --non-unique --gid "$LRRP_GID" lrrp \
    && useradd --non-unique --uid "$LRRP_UID" --gid "$LRRP_GID" \
        --home-dir /data/home --no-create-home --shell /usr/sbin/nologin lrrp \
    && mkdir -p /data /cache /sources \
    && chown "$LRRP_UID:$LRRP_GID" /data /cache

# LANG: Wine converts file names with the Unix locale; without UTF-8, non-ASCII names break.
ENV PATH=/opt/venv/bin:$PATH \
    LANG=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    WINEARCH=win64 \
    WINEDEBUG=-all

USER ${LRRP_UID}:${LRRP_GID}

VOLUME ["/data", "/cache", "/sources"]
EXPOSE 8787

# The first start creates the Wine prefix, which takes a while; hence the long start period.
# No proxy for this request, even if the container has HTTP_PROXY set.
HEALTHCHECK --interval=30s --timeout=5s --start-period=3m --retries=3 \
    CMD ["/opt/venv/bin/python", "-c", "import os, urllib.request as u; port = os.environ.get('LRRP_PORT', '').strip() or '8787'; u.build_opener(u.ProxyHandler({})).open('http://127.0.0.1:' + port + '/healthz', timeout=4)"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/lrrp-entrypoint"]
CMD ["python", "-m", "lrrp"]
