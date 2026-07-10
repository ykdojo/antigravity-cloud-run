# Antigravity on Cloud Run

Sandboxed Docker container running the Antigravity CLI (`agy`), accessible via a web terminal.

See [architecture.md](architecture.md) for full design details.

## Testing end to end

After making changes, rebuild and test:

```bash
./scripts/build.sh
./scripts/run.sh
```

This opens http://localhost:7681 in the browser. Verify:
1. agy launches automatically with bypass permissions
2. Confirm it doesn't ask for login (after the one-time Google sign-in per session)
3. Send a message and confirm it gets a response

## Multiple sessions

Run multiple isolated sessions with `-s`:

```bash
./scripts/run.sh -n                    # default on port 7681
./scripts/run.sh -s work -n            # agrun-work on next available port
./scripts/run.sh -s research -n        # agrun-research on next available port
```

## Mounting local projects

Use `-v` to mount a local directory into the container. Keep the same folder name inside the container for clarity:

```bash
./scripts/run.sh -s myproject -n -v /path/to/myproject:/home/agrun/myproject
```

This mounts the project at `/home/agrun/myproject` inside the container. Use the same folder name (not a generic "project") so it's clear which project you're working with. If the container already exists, it will be recreated with the new mount.

## Research sessions

For web research or any task requiring URL fetching, use a container session instead of doing it directly on the host. The `-q` option sends a query directly to agy inside the container:

```bash
./scripts/run.sh -s research -n -q "Research Inngest and explain how durable execution works"
```

This starts the container (or reuses an existing one) and sends the query to agy running inside it.

## Dashboard

Start the dashboard to manage all sessions:

```bash
npx nodemon dashboard/server.js
```

Always use nodemon during development for auto-restart on changes.

Opens at http://localhost:7680. Shows all sessions with:
- Start/stop/delete buttons
- Live iframes of active sessions
- Auto-refreshes via Docker events (SSE)

## Session persistence

Each session's data persists at `~/.config/agrun/sessions/<session-name>/` on the host, mounted to `/home/agrun/.gemini/` in the container.

This includes:
- **Auth:** agy's Google sign-in credentials (one-time login per session)
- **Conversations:** agy conversation history
- **Settings:** `antigravity-cli/settings.json`, MCP config, statusline

Rebuilding containers or restarting sessions won't affect any of these. Baked defaults live in `/home/agrun/.gemini-defaults` in the image and are seeded into the mount by `run.sh` with a no-clobber copy.

## Starting and stopping containers

Always use these methods (they handle ttyd startup):
- `./scripts/run.sh -s name -n` - create or start a session
- Dashboard start/stop buttons - manage running sessions

`run.sh` refreshes env vars from `~/.config/agrun/.secrets/` into the container's `/home/agrun/.env`.

**Don't use raw `docker start`** - it won't start ttyd inside the container.

## Sending commands to the container via tmux

When sending commands to the container's tmux session with `tmux send-keys`, the message may not go through on the first Enter. If `tmux capture-pane` shows the prompt is still empty (the prompt line has no text after it, or the text is there but hasn't been submitted), send additional Enter keys:

```bash
docker exec agrun-default tmux send-keys -t main Enter
docker exec agrun-default tmux send-keys -t main 'your command' Enter
docker exec agrun-default tmux capture-pane -t main -p
```

For other sessions, replace `default` with the session name (e.g., `agrun-work`).

Always verify with `tmux capture-pane -t main -p` that the command was actually submitted.
