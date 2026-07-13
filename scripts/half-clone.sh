#!/bin/bash
# Half-clone an agy conversation: copy the later half into a new conversation
# so you can keep working with a smaller context. The original is untouched.
#
# Usage: half-clone.sh [-s session] [conversation-id]
#   -s session        agrun session name (host only; default: default)
#   conversation-id   source conversation uuid (default: most recently modified)
#
# Works on the host (against the session mount) and inside containers - local
# or Cloud Run - where it uses ~/.gemini directly. Only needs bash + python3.
# The clone appears in agy's /resume picker. Quit agy (or at least the source
# conversation) first so the copy is consistent.
set -euo pipefail

SESSION_NAME="default"
while getopts "s:" opt; do
    case $opt in
        s) SESSION_NAME="$OPTARG" ;;
        *) echo "Usage: $0 [-s session] [conversation-id]"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# On the host, sessions live under ~/.config/agrun/sessions/<name>/ - prefer
# that (the host may also have its own agy install at ~/.gemini). Inside a
# container, ~/.gemini is the live config dir.
HOST_CONV="${XDG_CONFIG_HOME:-$HOME/.config}/agrun/sessions/${SESSION_NAME}/antigravity-cli/conversations"
GEMINI_CONV="$HOME/.gemini/antigravity-cli/conversations"
if [ -d "$HOST_CONV" ]; then
    CONV_DIR="$HOST_CONV"
elif [ -d "$GEMINI_CONV" ]; then
    CONV_DIR="$GEMINI_CONV"
else
    echo "Error: no conversations directory found ($HOST_CONV or $GEMINI_CONV)" >&2
    exit 1
fi

CONV_ID="${1:-}" python3 - "$CONV_DIR" <<'PYEOF'
import datetime, glob, os, re, sqlite3, sys, uuid

conv_dir = sys.argv[1]
conv_id = os.environ.get("CONV_ID", "")

def step_count(path):
    try:
        c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        n = c.execute("SELECT COUNT(*) FROM steps").fetchone()[0]
        c.close()
        return n
    except sqlite3.Error:
        return 0

if conv_id:
    src = os.path.join(conv_dir, conv_id + ".db")
    if not os.path.isfile(src):
        sys.exit(f"Error: {src} not found")
else:
    # Newest conversation that actually has steps - agy leaves empty
    # placeholder dbs around, which are never what you want to clone
    dbs = sorted(glob.glob(os.path.join(conv_dir, "*.db")),
                 key=os.path.getmtime, reverse=True)
    src = next((db for db in dbs if step_count(db) > 0), None)
    if not src:
        sys.exit(f"Error: no conversations with steps found in {conv_dir}")

# step_type 14 marks the start of a user turn; cut at the middle user turn so
# the clone begins on a clean user-message boundary
con = sqlite3.connect(src)
user_steps = [r[0] for r in con.execute(
    "SELECT idx FROM steps WHERE step_type = 14 ORDER BY idx")]
total = con.execute("SELECT COUNT(*) FROM steps").fetchone()[0]
if len(user_steps) < 2:
    sys.exit("Error: conversation has fewer than 2 user messages, nothing to half-clone")
cut = user_steps[len(user_steps) // 2]

new_id = str(uuid.uuid4())
dst = os.path.join(conv_dir, new_id + ".db")

# sqlite backup is WAL-safe, unlike copying the file
dst_con = sqlite3.connect(dst)
con.backup(dst_con)
con.close()

dst_con.execute("UPDATE trajectory_meta SET cascade_id = ?", (new_id,))
for table in ("steps", "gen_metadata", "executor_metadata",
              "parent_references", "battle_mode_infos"):
    dst_con.execute(f"DELETE FROM {table} WHERE idx < ?", (cut,))
    dst_con.execute(f"UPDATE {table} SET idx = idx - ?", (cut,))
dst_con.commit()
kept = dst_con.execute("SELECT COUNT(*) FROM steps").fetchone()[0]

src_id = os.path.basename(src)[:-3]

# Tag the clone in the /resume picker (annotations/<id>.pbtxt holds the title,
# same file agy's f2-rename writes). Reuse the original's title if it has one,
# else fall back to text pulled from the first kept user step.
ann_dir = os.path.join(os.path.dirname(conv_dir), "annotations")
base_title = ""
src_ann = os.path.join(ann_dir, src_id + ".pbtxt")
if os.path.isfile(src_ann):
    m = re.search(r'title:"(.*?)"', open(src_ann).read())
    if m:
        base_title = m.group(1)
if not base_title:
    # First human-looking string in the first kept user step: skip uuids,
    # paths, and tool names; strip the leading protobuf length byte
    row = dst_con.execute(
        "SELECT step_payload FROM steps WHERE step_type = 14 ORDER BY idx LIMIT 1"
    ).fetchone()
    for s in re.findall(rb"[\x20-\x7e]{8,}", (row and row[0]) or b""):
        t = re.sub(r"^[^A-Za-z0-9]+", "", s.decode())
        if re.fullmatch(r"[0-9a-f-]{20,}", t) or t.startswith("/") or t.endswith("(*)"):
            continue
        if " " in t:
            base_title = t[:60]
            break
stamp = datetime.datetime.now().strftime("%b %d %H:%M")
title = f"[HALF-CLONE {stamp}] {base_title}".strip().replace('"', "'")
os.makedirs(ann_dir, exist_ok=True)
with open(os.path.join(ann_dir, new_id + ".pbtxt"), "w") as f:
    f.write(f'title:"{title}"')

dst_con.close()
print(f"Half-cloned {src_id}")
print(f"  New conversation: {new_id}")
print(f"  Title: {title}")
print(f"  Kept {kept} of {total} steps (cut at step {cut}, a user-message boundary)")
print(f"  Kept {len(user_steps) - len(user_steps) // 2} of {len(user_steps)} user turns")
print()
print("Open it with /resume in agy.")
PYEOF
