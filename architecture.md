# Antigravity on Cloud Run architecture

## Overview

Antigravity on Cloud Run runs the Antigravity CLI (`agy`) inside a sandboxed Docker container, accessible via a web terminal. Designed to work the same locally (Docker) and in the cloud (Cloud Run, planned).

## Web terminal

The user interacts with agy through a browser, not a local terminal. This gives full access to the native agy TUI rather than building a custom one on top of an SDK.

### Current approach: ttyd + tmux

- **ttyd** serves a web terminal over HTTP/WebSocket on port 7681
- **tmux** manages the agy session inside the container
- One port, one ttyd process, one tmux session per container
- Full agy TUI - status line, colors, interactive prompts, everything
- No custom UI code needed

## Authentication

### Antigravity CLI

agy uses Google sign-in. In a headless container it detects the remote session and prints an authorization URL plus a one-time code; you complete the login in a browser on the host. This is a one-time step per session: credentials are stored under `~/.gemini`, which is volume-mounted to `~/.config/agrun/sessions/<session-name>/` on the host, so they survive container rebuilds.

Notes:
- OAuth persistence on headless Linux requires agy >= 1.0.1 ([google-antigravity/antigravity-cli#57](https://github.com/google-antigravity/antigravity-cli/issues/57))
- Plain Gemini API keys are not supported by the CLI ([#78](https://github.com/google-antigravity/antigravity-cli/issues/78))
- The agy installer has no version pinning and the binary self-updates in the background

### Other secrets

All other secrets are stored on the host in `~/.config/agrun/.secrets/`. Each file becomes an environment variable (filename = env var name).

How env vars are passed:

1. `run.sh` reads all files in `.secrets/` and writes them to `/home/agrun/.env` inside the container
2. `BASH_ENV=/home/agrun/.env` (set in the Dockerfile) ensures every bash invocation sources it
3. `.bashrc` also sources `.env` for interactive shells

This means env vars are available everywhere - interactive shells, the agent's bash commands, and `docker exec bash -c` commands.

### GitHub CLI

`GH_TOKEN` is used for GitHub CLI authentication. On container start, `run.sh` also auto-configures git user (name and email) from the GitHub account.

We recommend creating a separate GitHub account for this so you can scope its permissions independently.

## Config seeding

`~/.gemini` is a volume mount, so baked-in defaults can't live there directly in the image. Instead the Dockerfile stages them in `/home/agrun/.gemini-defaults` (AGENTS.md, `antigravity-cli/settings.json`, statusline script, Playwright MCP config), and `run.sh` seeds them into `~/.gemini` on every start with `cp -an` - existing files are never overwritten, so user changes and credentials win.

## Cloud Run (planned)

- Require IAM auth; access via `gcloud run services proxy` (or IAP for browser sharing). Never `--allow-unauthenticated` - ttyd is a remote shell.
- Secret Manager for tokens, mounted as env vars
- GCS FUSE volume for `~/.gemini` session persistence
- min/max instances = 1; ttyd WebSocket connections drop at Cloud Run's 60-minute cap, tmux absorbs reconnects
