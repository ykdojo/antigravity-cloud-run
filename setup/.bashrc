# Load env vars from tmux session
eval "$(tmux show-environment -s 2>/dev/null)"

# Claude Code aliases
alias c='claude'
alias cs='claude --dangerously-skip-permissions'

# Gemini alias
alias g='gemini'

# Claude --fs shortcut
claude() {
  local args=()
  for arg in "$@"; do
    if [[ "$arg" == "--fs" ]]; then
      args+=("--fork-session")
    else
      args+=("$arg")
    fi
  done
  command claude "${args[@]}"
}
