#!/bin/bash
# Create a new session (called from dashboard UI)

# Pass all arguments to run.sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/run.sh" "$@"
