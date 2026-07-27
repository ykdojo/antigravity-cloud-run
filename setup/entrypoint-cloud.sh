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
        # gcsfuse doesn't support rsync's default temp-file+rename strategy or
        # chmod/chown, so write files in place and skip permission bits. Errors
        # go to the container log (visible in Cloud Run) instead of /dev/null.
        rsync -rlt --inplace --no-perms --no-owner --no-group \
            --delete --exclude 'antigravity-cli/log' "$GEMINI/" "$MOUNT/" \
            || echo "sync_back: rsync failed with exit $?" >&2
    fi
}

# Periodic backup sync
( while sleep 60; do sync_back; done ) &
SYNC_LOOP=$!

# Join the tailnet BEFORE ttyd listens - after readiness Cloud Run throttles
# CPU and the join would time out (no-op without TS_AUTHKEY)
/home/agrun/start-tailscale.sh "agrun-${SESSION_NAME:-cloud}"

TITLE="Antigravity on Cloud Run - ${SESSION_NAME:-cloud}"

# ttyd's own index.html has no <meta name="viewport">, so mobile browsers lay
# the page out at a desktop width and scale it down - the terminal ends up
# unreadably small on a phone no matter what fontSize is set to. ttyd can
# serve a custom index (-I), so grab its page once and inject the tag. Done at
# runtime rather than build time so it always matches the installed ttyd.
INDEX=/home/agrun/ttyd-index.html
ttyd -W -p 7690 /bin/true >/dev/null 2>&1 &
BOOTSTRAP=$!
for _ in $(seq 1 20); do
    curl -sf localhost:7690/ -o "$INDEX" && break
    sleep 0.25
done
kill "$BOOTSTRAP" 2>/dev/null
INDEX_ARG=""
if [ -s "$INDEX" ] && grep -q '<meta charset' "$INDEX"; then
    sed -i 's|<meta charset="UTF-8">|<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">|' "$INDEX"
    # The viewport tag isn't enough on its own: a browser set to "request
    # desktop site" ignores it, lays the page out at desktop width and scales
    # the result down, which shrinks the terminal past readability. Detect that
    # (layout wider than the physical screen) and scale fontSize by the same
    # ratio, so the on-screen size is what was asked for either way.
    sed -i 's@</body>@<script>(function(){var i=setInterval(function(){var T=window.term;if(!T)return;clearInterval(i);var sw=screen.width?screen.width:innerWidth;if(innerWidth>sw*1.2){var b=T.options.fontSize?T.options.fontSize:16;T.options.fontSize=Math.round(b*innerWidth/sw);if(T.fit)T.fit();}},100);setTimeout(function(){clearInterval(i)},15000);})();</script></body>@' "$INDEX"
    grep -q 'name="viewport"' "$INDEX" && INDEX_ARG="-I $INDEX"
fi

# ttyd only takes xterm options server-side (-t); URL query args don't work,
# so the font size is baked in at deploy time (TTYD_FONT_SIZE / deploy -f).
ttyd -W $INDEX_ARG -t titleFixed="$TITLE" -t fontSize="${TTYD_FONT_SIZE:-16}" -t disableLeaveAlert=true -p "${PORT:-7681}" /home/agrun/ttyd-wrapper.sh &
TTYD=$!

# Cloud Run's SIGTERM grace period is ~10s: log out first (fast, and an
# ephemeral node left behind lingers for hours), then sync with the rest.
on_term() {
    kill "$SYNC_LOOP" 2>/dev/null
    pgrep -x tailscaled >/dev/null && tailscale logout 2>/dev/null
    sync_back
    kill "$TTYD" 2>/dev/null
}
trap on_term TERM INT

wait "$TTYD"
on_term
