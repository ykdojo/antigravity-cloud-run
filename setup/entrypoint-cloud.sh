#!/bin/bash
# Cloud Run entrypoint. Local containers don't use this - run.sh overrides
# the command with `sleep infinity` and starts ttyd via docker exec.
#
# The session bucket is mounted at /gcs-session but agy runs against local
# disk: gcsfuse can't back SQLite's locking/mmap (stale file handle errors),
# so the entrypoint restores bucket -> local on boot and syncs local -> bucket
# every 60s and on shutdown. Scale-to-zero loses at most ~1 minute of state.

MOUNT=/gcs-session
GEMINI=/home/agrun/.gemini

mkdir -p "$GEMINI"

# Restore session state from the bucket
if [ -d "$MOUNT" ] && [ -n "$(ls -A "$MOUNT" 2>/dev/null)" ]; then
    rsync -a "$MOUNT/" "$GEMINI/"
fi

# Seed baked defaults (no clobber)
cp -r --update=none /home/agrun/.gemini-defaults/. "$GEMINI/" 2>/dev/null || true

# Restore agy login from Secret Manager (AGY_OAUTH_TOKEN) if still missing
TOKEN_FILE="$GEMINI/antigravity-cli/antigravity-oauth-token"
if [ ! -f "$TOKEN_FILE" ] && [ -n "$AGY_OAUTH_TOKEN" ]; then
    mkdir -p "$(dirname "$TOKEN_FILE")"
    printf '%s' "$AGY_OAUTH_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
fi

sync_back() {
    if [ -d "$MOUNT" ]; then
        rsync -a --delete --exclude 'antigravity-cli/log' "$GEMINI/" "$MOUNT/" 2>/dev/null
    fi
}

# Periodic backup sync
( while sleep 60; do sync_back; done ) &
SYNC_LOOP=$!

TITLE="Antigravity on Cloud Run - ${SESSION_NAME:-cloud}"
ttyd -W -t titleFixed="$TITLE" -p "${PORT:-7681}" /home/agrun/ttyd-wrapper.sh &
TTYD=$!

# Cloud Run sends SIGTERM with a short grace period: final sync, then exit
on_term() {
    kill "$SYNC_LOOP" 2>/dev/null
    sync_back
    kill "$TTYD" 2>/dev/null
}
trap on_term TERM INT

wait "$TTYD"
on_term
