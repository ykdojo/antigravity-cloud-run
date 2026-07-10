# Antigravity on Cloud Run architecture

## Overview

Antigravity on Cloud Run runs the Antigravity CLI (`agy`) inside a sandboxed Docker container, accessible via a web terminal. Works the same locally (Docker) and in the cloud (Cloud Run), managed from one dashboard.

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

agy has no env var for token-based auth (API-key auth is an open feature request: [google-antigravity/antigravity-cli#78](https://github.com/google-antigravity/antigravity-cli/issues/78)). But its OAuth credential is a plain JSON file: `~/.gemini/antigravity-cli/antigravity-oauth-token`. So `run.sh` copies the host's token file into each new session's mount: log in on the host once, and every session starts already authenticated. The copy only happens when the session has no token yet - agy refreshes its own copy afterwards, and overwriting it with a stale host token could break auth.

Without a host login, agy falls back to interactive Google sign-in: in a headless container it prints an authorization URL, you complete it in a browser on the host and paste the code back. Either way, credentials live under `~/.gemini`, which is volume-mounted to `~/.config/agrun/sessions/<session-name>/` on the host, so they survive container rebuilds.

Onboarding is fully pre-answered so fresh sessions go straight to the prompt: the baked `settings.json` sets `enableTelemetry: false` (opt out of data collection) and `trustedWorkspaces: ["/home/agrun"]`, and the baked `cache/onboarding.json` (`onboardingComplete: true`) skips the first-run wizard.

### Other secrets

All other secrets are stored on the host in `~/.config/agrun/.secrets/`. Each file becomes an environment variable (filename = env var name).

Scripts manage these for you: `npm run manage-env` (`scripts/manage-env.js`) lists, adds, and deletes keys interactively; `scripts/setup-slack.sh` walks through creating a Slack app and stores `SLACK_TOKEN`; and `run.sh` offers to set up `GH_TOKEN` on first run.

How env vars are passed:

1. `run.sh` reads all files in `.secrets/` and writes them to `/home/agrun/.env` inside the container
2. `BASH_ENV=/home/agrun/.env` (set in the Dockerfile) ensures every bash invocation sources it
3. `.bashrc` also sources `.env` for interactive shells

This means env vars are available everywhere - interactive shells, the agent's bash commands, and `docker exec bash -c` commands.

### GitHub CLI

`GH_TOKEN` is used for GitHub CLI authentication. On container start, `run.sh` also auto-configures git user (name and email) from the GitHub account.

We recommend creating a separate GitHub account for this so you can scope its permissions independently.

## Config seeding

`~/.gemini` is a volume mount, so baked-in defaults can't live there directly in the image. Instead the Dockerfile stages them in `/home/agrun/.gemini-defaults` (AGENTS.md, `antigravity-cli/settings.json`, statusline script, Playwright MCP config), and `run.sh` seeds them into `~/.gemini` on every start with a no-clobber copy - existing files are never overwritten, so user changes and credentials win.

## Dashboard

`dashboard/server.js` is a small Node server (localhost:7680) with no state of its own: buttons call HTTP endpoints, and the server shells out to the same scripts and CLIs you would run by hand.

- **Local sessions:** listed via `docker ps`, created via `run.sh`, auto-refreshed by streaming `docker events` to the page (SSE). Running sessions render as live terminal iframes.
- **Cloud sessions:** listed via `gcloud run services list` (filtered by the `agrun=session` label; project/region come from `~/.config/agrun/cloud.json`, written by the deploy script). Create runs `deploy-cloud.sh`; delete removes the service but keeps its bucket. Connect makes the server spawn `gcloud run services proxy` on a local port and iframe it - IAM is still enforced on every request; only the raw `run.app` URL can't be embedded. A cold-start overlay covers the iframe until the server (watching the ttyd WebSocket) confirms agy has painted.

## Cloud Run

One Cloud Run service per session (`agrun-<session>`), deployed by `scripts/deploy-cloud.sh`. Instances of a single service can't act as sessions: Cloud Run treats them as interchangeable replicas, so sessions map to services.

- **Access:** IAM-gated (`--no-allow-unauthenticated`), reached via `gcloud run services proxy`, which gives the same localhost experience as local Docker. Never expose ttyd publicly - it's a remote shell.
- **Auth:** the host's agy OAuth token file is stored once in Secret Manager (`agy-oauth-token`) and injected as the `AGY_OAUTH_TOKEN` env var; the entrypoint writes it into `~/.gemini` if the restored session state doesn't already have one.
- **Persistence:** a GCS bucket per session, mounted at `/gcs-session` (gen2 execution environment). agy runs against the container's local disk - its SQLite state can't live on gcsfuse directly (no POSIX locking; stale-file-handle errors) - and the entrypoint restores bucket -> local on boot, then syncs local -> bucket every 60 seconds and on SIGTERM. A restart loses at most about a minute of state.
- **Entrypoint:** the image's default command is `entrypoint-cloud.sh`: restore session state from the bucket, seed baked defaults, write the token if missing, start ttyd on `$PORT`, run the background sync loop. Local containers are unaffected: `run.sh` overrides the command with `sleep infinity` and manages ttyd itself.
- **Scaling:** scale-to-zero by default (the live terminal dies on idle but conversations resume with `agy -c` from the synced bucket); `-a` deploys always-on (min-instances=1, a warm instance 24/7). ttyd WebSocket connections drop at Cloud Run's 60-minute request cap; tmux absorbs reconnects.
- **Statusline note:** files restored from the bucket lose their executable bit, so settings invoke the statusline as `bash .../statusline.sh`.
