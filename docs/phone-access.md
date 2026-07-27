# Phone access: drive agy from a phone browser via IAP

Working notes from a design conversation on 2026-07-26 (Claude Code session
`3984bd2c-4a84-4129-a9d6-b2d72b65a457` on the yk2 Mac). Status: IAP is enabled and
partially configured; one console step remains. A future agent with fresh context
should be able to pick this up from here. This is also source material for a blog
post later.

## Goal

Drive an agy session interactively from a phone - plain mobile browser, no laptop in
the loop, no extra apps.

## The design conversation (summary + the reasoning)

Two candidate architectures for reaching a session from a phone:

### Option A: Tailscale (rejected for this use case, but fully built on main)

Sessions already join the tailnet as inbound-only nodes (`start-tailscale.sh`), so a
phone with the Tailscale app can open `http://agrun-<session>:7681`. Problem: tailnet
traffic bypasses Cloud Run's front end entirely, so the autoscaler sees an idle
service. Even with `--no-cpu-throttling` (already set in `deploy-cloud.sh` for exactly
this reason), an instance with no ingress requests is reclaimed after ~15 min - the
session dies mid-use unless deployed with `-a` (min-instances=1, ~$0.15/hr at
2 CPU / 2Gi, instance-based billing). Fine as a fallback; costs money while pinned.

### Option B: IAP through Cloud Run ingress (chosen)

Enable IAP on the session service and open the `run.app` URL directly from the phone
browser: Google sign-in page → ttyd terminal. Why it wins:

- The open ttyd WebSocket is a real ingress request, so it wakes the instance
  (scale-to-zero friendly), keeps it alive while connected, and lets it scale back to
  zero when the tab closes. Pay only while looking at it. No `-a` needed.
- No app install on the phone; any Google account can be allowlisted (Gmail included,
  no Cloud account needed).
- Trade-off vs Tailscale+`-a`: fire-and-forget (kick off a task, pocket the phone)
  dies ~15 min after disconnect. For interactive use - the stated goal - that's fine.
  tmux + the GCS sync/restore means a reclaimed instance resumes on the next visit.

### Why each layer of the stack is necessary (good blog material)

**IAP decides who gets in, ttyd turns the browser into a terminal, tmux makes the
session immortal, agy does the work.**

- ttyd: agy is a TUI; the browser speaks HTTP/WebSocket. ttyd is the ~2MB bridge
  (serves xterm.js, pipes to the terminal). Alternatives are all worse: sshd needs a
  client app + keys; code-server is a full IDE for its terminal panel; a custom UI
  needs an agy API that doesn't exist (API-key auth is open feature request
  google-antigravity/antigravity-cli#78).
- tmux: without it the terminal process belongs to the connection, and phones drop
  connections constantly (screen lock, app switch). tmux decouples session lifetime
  from connection lifetime: reattach after any drop, attach from laptop and phone
  simultaneously.
- IAP mechanics: Cloud Run terminates TLS and IAP fronts the service with a Google
  sign-in; the container keeps speaking plain HTTP. Grantees need only
  `roles/iap.httpsResourceAccessor` - any Google account works.

## State as of 2026-07-26 (project agrun-sessions-0709, us-central1)

Done, live on the `agrun-default` service:

1. IAP enabled: `gcloud run services update agrun-default --iap`
2. IAP service agent granted invoker:
   `service-1031143759227@gcp-sa-iap.iam.gserviceaccount.com` → `roles/run.invoker`
3. Access granted to both user accounts via
   `gcloud beta iap web add-iam-policy-binding --resource-type=cloud-run
   --service=agrun-default --region=us-central1 --role=roles/iap.httpsResourceAccessor`
4. `iap.googleapis.com` API enabled on the project.

**Blocker (one console step, needs the project owner's Google login):** requests
currently return `502` with body "Empty Google Account OAuth client ID(s)/secret(s)"
(`x-goog-iap-generated-response: true`). The project has no OAuth consent config, and
the old fix (`gcloud iap oauth-brands create`) is shut down as of March 2026 and
required an org anyway. Fix: Google Auth Platform branding in the console -
https://console.cloud.google.com/auth/overview?project=agrun-sessions-0709 -
app name e.g. "agrun sessions", support email = the project owner account, audience
External. (~2 minutes, then IAP's Google-managed OAuth client should activate.)

## Remaining steps

1. Configure Auth Platform branding (console step above).
2. Verify: `curl -sI https://agrun-default-zozv65cteq-uc.a.run.app/` should turn from
   502 into a 302 to accounts.google.com.
3. Phone test: open `https://agrun-default-zozv65cteq-uc.a.run.app/?fontSize=16` in
   the phone browser, sign in, drive agy. (ttyd accepts xterm client options as URL
   query args - fontSize is the important one on mobile.)
4. Likely follow-up: a small same-origin wrapper page with a key toolbar (Esc, Ctrl,
   Tab, arrows) - phone keyboards lack them and agy menus need arrows. Must be
   same-origin with ttyd to inject keys into the iframe, so serve wrapper + proxied
   ttyd from one port rather than two.
5. Decide per-session defaults: should `deploy-cloud.sh` grow an `--iap` flag so new
   sessions come up phone-ready? (IAP + IAM invoker + accessor grants per service.)
6. Blog post: the layered-stack explanation above + the Option A/B trade-off is the
   outline. Angle: "wake your cloud coding agent by opening a browser tab; it costs
   nothing while you're not looking at it."

## Cost notes

- IAP path: $0 idle (scale-to-zero), normal request-time billing while connected.
- Tailscale fallback: deploy with `-a`, ~$0.15/hr while pinned; tear down after.
