#!/bin/bash
# Half-clone an agy conversation: copy the later half into a new conversation
# so you can keep working with a smaller context. The original is untouched.
#
# Usage: half-clone.sh [-s session] [conversation-id]
#   -s session        agrun session name (default: default)
#   conversation-id   source conversation uuid (default: most recently modified)
#
# The clone appears in agy's /resume picker. Works on the host against the
# session mount; quit agy (or at least the source conversation) first so the
# copy is consistent.
set -euo pipefail

SESSION_NAME="default"
while getopts "s:" opt; do
    case $opt in
        s) SESSION_NAME="$OPTARG" ;;
        *) echo "Usage: $0 [-s session] [conversation-id]"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

CONV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agrun/sessions/${SESSION_NAME}/antigravity-cli/conversations"
if [ ! -d "$CONV_DIR" ]; then
    echo "Error: no conversations directory for session '$SESSION_NAME' ($CONV_DIR)" >&2
    exit 1
fi

# Source conversation: argument, or the most recently modified db
if [ $# -ge 1 ]; then
    SRC="$CONV_DIR/$1.db"
    [ -f "$SRC" ] || { echo "Error: $SRC not found" >&2; exit 1; }
else
    SRC="$(ls -t "$CONV_DIR"/*.db 2>/dev/null | head -1)"
    [ -n "$SRC" ] || { echo "Error: no conversations found in $CONV_DIR" >&2; exit 1; }
fi

# step_type 14 marks the start of a user turn; cut at the middle user step so
# the clone begins on a clean user-message boundary
USER_STEPS="$(sqlite3 "$SRC" 'SELECT idx FROM steps WHERE step_type = 14 ORDER BY idx;')"
USER_COUNT="$(echo "$USER_STEPS" | grep -c . || true)"
if [ "$USER_COUNT" -lt 2 ]; then
    echo "Error: conversation has fewer than 2 user messages, nothing to half-clone" >&2
    exit 1
fi
CUT_IDX="$(echo "$USER_STEPS" | sed -n "$((USER_COUNT / 2 + 1))p")"
TOTAL_STEPS="$(sqlite3 "$SRC" 'SELECT COUNT(*) FROM steps;')"

NEW_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
DST="$CONV_DIR/$NEW_ID.db"

# .backup is WAL-safe, unlike cp
sqlite3 "$SRC" ".backup '$DST'"

sqlite3 "$DST" "
UPDATE trajectory_meta SET cascade_id = '$NEW_ID';
DELETE FROM steps WHERE idx < $CUT_IDX;
UPDATE steps SET idx = idx - $CUT_IDX;
DELETE FROM gen_metadata WHERE idx < $CUT_IDX;
UPDATE gen_metadata SET idx = idx - $CUT_IDX;
DELETE FROM executor_metadata WHERE idx < $CUT_IDX;
UPDATE executor_metadata SET idx = idx - $CUT_IDX;
DELETE FROM parent_references WHERE idx < $CUT_IDX;
UPDATE parent_references SET idx = idx - $CUT_IDX;
DELETE FROM battle_mode_infos WHERE idx < $CUT_IDX;
UPDATE battle_mode_infos SET idx = idx - $CUT_IDX;
"

KEPT="$(sqlite3 "$DST" 'SELECT COUNT(*) FROM steps;')"
echo "Half-cloned $(basename "$SRC" .db)"
echo "  New conversation: $NEW_ID"
echo "  Kept $KEPT of $TOTAL_STEPS steps (cut at step $CUT_IDX, a user-message boundary)"
echo ""
echo "Open it with /resume in agy (session: $SESSION_NAME)."
