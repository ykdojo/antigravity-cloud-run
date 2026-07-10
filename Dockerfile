FROM ubuntu:noble

ARG DEBIAN_FRONTEND=noninteractive
ARG TZ=America/Los_Angeles
ARG NODE_VERSION=24
ARG PLAYWRIGHT_MCP_VERSION=0.0.62

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# === INSTALL Node.js ===

RUN apt-get update && \
    # Install Node.js
    apt-get install -y curl wget gpg ca-certificates && \
    mkdir -p /etc/apt/keyrings && \
    curl -sL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main" >> /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y nodejs && \
    # Feature-parity with node.js base images.
    # Install GitHub CLI
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y gh && \
    apt-get install -y --no-install-recommends git openssh-client jq tmux ttyd vim python3-pip unzip && \
    npm install -g yarn && \
    # clean apt cache
    rm -rf /var/lib/apt/lists/* && \
    # Create the sclaw user
    adduser sclaw

# === INSTALL Playwright MCP + browsers ===

ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# Install MCP globally, then prefetch the Chromium browser artifacts with curl.
# Playwright's own downloader has no stall timeout: on some networks the CDN
# connection establishes but then stops sending data mid-transfer, and the
# install hangs forever. curl's --speed-time aborts a stalled transfer and
# --retry reconnects until one succeeds. We fetch each artifact (URLs/paths come
# from --dry-run, so this stays version-agnostic) into Playwright's browser dir
# and mark it INSTALLATION_COMPLETE, so `playwright install` finds them already
# present and skips its download. The final install is a fast no-op verification
# (timeout-guarded so a missed artifact fails the build instead of hanging).
RUN npm install -g @playwright/mcp@${PLAYWRIGHT_MCP_VERSION} && \
    mkdir -p /ms-playwright && \
    PW=/usr/lib/node_modules/@playwright/mcp/node_modules/.bin/playwright && \
    "$PW" install-deps chromium && \
    "$PW" install --dry-run chromium | \
        awk '/Install location:/{loc=$3} /Download url:/{print loc, $3}' | \
        sort -u > /tmp/pw-pairs.txt && \
    while read -r loc url; do \
        echo "prefetching $loc"; \
        mkdir -p "$loc" || exit 1; \
        curl -fL --retry 8 --retry-all-errors --retry-delay 2 --connect-timeout 20 \
             --speed-limit 50000 --speed-time 15 -o /tmp/pw.zip "$url" || exit 1; \
        unzip -q -o /tmp/pw.zip -d "$loc" || exit 1; \
        touch "$loc/INSTALLATION_COMPLETE"; \
        rm -f /tmp/pw.zip; \
    done < /tmp/pw-pairs.txt && \
    timeout 300 "$PW" install chromium && \
    rm -f /tmp/pw-pairs.txt && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf ~/.npm/ && \
    chmod -R 777 /ms-playwright

# === INSTALL node-lief and Slack SDK ===

RUN npm install -g node-lief @slack/web-api
ENV NODE_PATH=/usr/lib/node_modules

# === INSTALL Antigravity CLI (agy) ===

USER sclaw
WORKDIR /home/sclaw

ENV PATH="/home/sclaw/.local/bin:${PATH}"
ENV BASH_ENV=/home/sclaw/.env

# Auth: complete the Google sign-in inside the web terminal on first run.
# agy detects the headless environment and prints an authorization URL plus a
# one-time code. Credentials persist in ~/.gemini (session volume mount).
# - GH_TOKEN: run `gh auth token` locally to print current token
# Note: the agy installer has no version pinning and the binary self-updates
# in the background during regular runs.

RUN curl -fsSL https://antigravity.google/cli/install.sh | bash

# === SETUP Antigravity CLI ===

# ~/.gemini is volume-mounted per session (auth, history, settings), so bake
# the default config into a staging dir; run.sh seeds it into ~/.gemini on
# container start with cp -an (no clobber).
COPY --chown=sclaw:sclaw setup/AGENTS.md /home/sclaw/.gemini-defaults/AGENTS.md
COPY --chown=sclaw:sclaw setup/settings.json /home/sclaw/.gemini-defaults/antigravity-cli/settings.json
COPY --chown=sclaw:sclaw setup/mcp_config.json /home/sclaw/.gemini-defaults/config/mcp_config.json

# Context bar status line
RUN curl -sLo /home/sclaw/.gemini-defaults/antigravity-cli/statusline.sh \
      https://raw.githubusercontent.com/ykdojo/antigravity-cli-tips/main/scripts/context-bar.sh && \
    chmod +x /home/sclaw/.gemini-defaults/antigravity-cli/statusline.sh

# Shell aliases and shortcuts
COPY --chown=sclaw:sclaw setup/.bashrc /tmp/.bashrc
RUN cat /tmp/.bashrc >> /home/sclaw/.bashrc && rm /tmp/.bashrc

# ttyd wrapper script
COPY --chown=sclaw:sclaw setup/ttyd-wrapper.sh /home/sclaw/ttyd-wrapper.sh
RUN chmod +x /home/sclaw/ttyd-wrapper.sh

# Tools (skills from setup/skills are not wired up yet - agy's skill/plugin
# directory layout still needs to be confirmed)
COPY --chown=sclaw:sclaw setup/tools /home/sclaw/tools

