#!/bin/bash
# Start tmux session with agy

# Attach to existing session, or create new one with agy
if tmux has-session -t main 2>/dev/null; then
    exec tmux attach -t main
else
    # Create session
    tmux -f /dev/null new -d -s main
    tmux set -t main status off
    tmux set -t main mouse on

    # Start agy (env vars are loaded via BASH_ENV -> .bashrc -> .env)
    tmux send-keys -t main 'agy --dangerously-skip-permissions' Enter
    exec tmux attach -t main
fi
