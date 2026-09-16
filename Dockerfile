# syntax=docker/dockerfile:1
#
# MCP::Hub as a container: mount a .mcp.json, expose the HTTP port, done.
# Batteries included — the stdio upstreams the hub spawns run *inside* this
# image, so it carries the runtimes they need: Node (+ npx), Python (uv/uvx),
# Deno, Bun, and the Docker CLI (for "command: docker run ..." upstreams, when
# the socket is mounted). Alternate Node versions are fetched on demand by
# `with-node` into the /cache volume.

ARG PERL_IMAGE=perl:5.40-slim

########################################
# Stage 1: build the Perl dependencies
########################################
FROM ${PERL_IMAGE} AS perl-build

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
    && rm -rf /var/lib/apt/lists/*

# Resolve the hub's CPAN deps into a relocatable local::lib we copy into the
# runtime image. Only the cpanfile is needed for this.
WORKDIR /src
COPY cpanfile ./
RUN cpanm --notest --local-lib=/opt/perl5 --installdeps .

########################################
# Stage 2: the runtime image
########################################
FROM ${PERL_IMAGE} AS runtime

ARG NODE_VERSION=22
ARG DOCKER_CLI_VERSION=27.3.1

# Base tooling + a system Python (uv layers its own managed Pythons on top).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils unzip git tini python3 \
    && rm -rf /var/lib/apt/lists/*

# --- Node: the baked default (with-node fetches other majors on demand) ------
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64|amd64)  arch=x64 ;; \
      aarch64|arm64) arch=arm64 ;; \
      *) echo "unsupported arch $(uname -m)"; exit 1 ;; \
    esac; \
    base="https://nodejs.org/dist/latest-v${NODE_VERSION}.x"; \
    file="$(curl -fsSL "$base/SHASUMS256.txt" | grep "linux-${arch}.tar.xz" | grep -v musl | awk '{print $2}' | head -1)"; \
    mkdir -p /opt/node; \
    curl -fsSL "$base/$file" | tar -xJ -C /opt/node --strip-components=1

# --- Bun + Deno: single binaries, baked in ------------------------------------
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64|amd64)  bun=bun-linux-x64;     deno=deno-x86_64-unknown-linux-gnu ;; \
      aarch64|arm64) bun=bun-linux-aarch64; deno=deno-aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported arch $(uname -m)"; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/bun.zip "https://github.com/oven-sh/bun/releases/latest/download/${bun}.zip"; \
    unzip -q /tmp/bun.zip -d /tmp/bun; \
    install -m 0755 "/tmp/bun/${bun}/bun" /usr/local/bin/bun; \
    ln -s bun /usr/local/bin/bunx; \
    curl -fsSL -o /tmp/deno.zip "https://github.com/denoland/deno/releases/latest/download/${deno}.zip"; \
    unzip -q /tmp/deno.zip -d /usr/local/bin; \
    chmod 0755 /usr/local/bin/deno; \
    rm -rf /tmp/bun.zip /tmp/bun /tmp/deno.zip

# --- Docker CLI: client only; only useful when the socket is mounted ----------
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64|amd64)  arch=x86_64 ;; \
      aarch64|arm64) arch=aarch64 ;; \
      *) echo "unsupported arch $(uname -m)"; exit 1 ;; \
    esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${arch}/docker-${DOCKER_CLI_VERSION}.tgz" \
      | tar -xz -C /usr/local/bin --strip-components=1 docker/docker

# --- uv / uvx: manages Python versions on demand ------------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# --- the hub itself -----------------------------------------------------------
COPY --from=perl-build /opt/perl5 /opt/perl5
COPY lib /app/lib
COPY bin /app/bin
COPY docker/with-node /usr/local/bin/with-node
RUN chmod 0755 /usr/local/bin/with-node /app/bin/mcp-hub

ENV PERL5LIB=/opt/perl5/lib/perl5:/app/lib \
    PATH=/app/bin:/opt/node/bin:/usr/local/bin:/usr/bin:/bin \
    XDG_CACHE_HOME=/cache \
    MCP_HUB_CONFIG=/config/mcp.json \
    MCP_HUB_NODE_CACHE=/cache/node \
    npm_config_cache=/cache/npm \
    UV_CACHE_DIR=/cache/uv \
    DENO_DIR=/cache/deno \
    BUN_INSTALL_CACHE_DIR=/cache/bun

# Run non-root. uid 1000 lines up with the common host user, so a bind-mounted
# ./cache stays writable without extra chowning. The slim base has no useradd,
# so create the account directly (no extra package needed).
RUN printf 'mcp:x:1000:1000::/home/mcp:/usr/sbin/nologin\n' >> /etc/passwd \
    && printf 'mcp:x:1000:\n' >> /etc/group \
    && mkdir -p /home/mcp /cache /config \
    && chown -R 1000:1000 /home/mcp /cache /config
USER mcp
WORKDIR /app

EXPOSE 3080

# The setup page at GET / renders (200) with or without a token.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:3080/ >/dev/null || exit 1

# tini (as PID 1, registered as a subreaper with -s so it works even behind a
# stray `docker run --init`) reaps the stdio upstream children the hub stops on
# idle_timeout. CMD binds 0.0.0.0 (not the 127.0.0.1 config default), so -p works.
ENTRYPOINT ["tini", "-s", "--", "mcp-hub"]
CMD ["daemon", "-l", "http://0.0.0.0:3080"]
