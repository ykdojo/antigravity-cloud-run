#!/bin/bash
# Cloud Run entrypoint: seed defaults, restore agy login, start ttyd on $PORT.
# Local containers don't use this - run.sh overrides the command with
# `sleep infinity` and starts ttyd via docker exec.

# Seed baked defaults into the GCS-mounted ~/.gemini (no clobber)
cp -r --update=none /home/agrun/.gemini-defaults/. /home/agrun/.gemini/ 2>/dev/null || true

# Restore agy login from Secret Manager (AGY_OAUTH_TOKEN env var) if the
# session volume doesn't have one yet
TOKEN_FILE=/home/agrun/.gemini/antigravity-cli/antigravity-oauth-token
if [ ! -f "$TOKEN_FILE" ] && [ -n "$AGY_OAUTH_TOKEN" ]; then
    mkdir -p "$(dirname "$TOKEN_FILE")"
    printf '%s' "$AGY_OAUTH_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true
fi

TITLE="Antigravity on Cloud Run - ${SESSION_NAME:-cloud}"
exec ttyd -W -t titleFixed="$TITLE" -p "${PORT:-7681}" /home/agrun/ttyd-wrapper.sh
