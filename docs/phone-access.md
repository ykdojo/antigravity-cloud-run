# Phone access: drive agy from a phone browser via IAP

Working notes from a design conversation on 2026-07-26 (Claude Code session
`3984bd2c-4a84-4129-a9d6-b2d72b65a457` on the yk2 Mac). Status: **working** - the
`run.app` URL now 302s to Google sign-in (fixed later the same day, second session).
Remaining: phone test + the follow-ups at the bottom. This is also source material
for a blog post later.

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

**The 502 and its real fix (resolved 2026-07-26, second session):** requests
returned `502` with body "Empty Google Account OAuth client ID(s)/secret(s)"
(`x-goog-iap-generated-response: true`). The original theory - configure Auth
Platform branding and IAP's Google-managed OAuth client activates - was **wrong**:
branding alone didn't fix it, and neither did toggling IAP off/on. The actual
constraint (per the Cloud Run IAP docs): **IAP's Google-managed OAuth client only
authenticates users inside the project's organization.** This project is on a
personal Gmail with no org, so external users (any Gmail) require a custom OAuth
client handed to IAP. Full working recipe:

1. Auth Platform branding (console, done via browser automation): app name
   "agrun sessions", support email = owner account, audience External, agree to the
   API user-data policy. Console: `/auth/overview` → Get started.
2. Test users (console, `/auth/audience`): while publishing status is Testing, only
   test users can sign in. Added both accessor accounts. (Testing mode also expires
   sign-ins after ~7 days - re-sign-in weekly, accepted; "Publish app" would remove
   that.)
3. Custom OAuth client (console, `/auth/clients`): Web application, name
   `agrun-iap`. Add authorized redirect URI
   `https://iap.googleapis.com/v1/oauth/clientIds/CLIENT_ID:handleRedirect`.
   Note: secrets are shown only at creation (hash-only afterwards); the console
   "copy" icon + `pbpaste` gets it into a file without displaying it.
4. Hand the client to IAP (project-level, so every future IAP'd service inherits
   it):
   ```
   # iap_settings.yaml
   access_settings:
     oauth_settings:
       client_id: CLIENT_ID
       client_secret: CLIENT_SECRET
   gcloud iap settings set iap_settings.yaml --project=agrun-sessions-0709
   ```
   (Delete the yaml after; the secret lives on only as a sha256 in IAP settings.)
5. Verified: `curl -sI https://agrun-default-zozv65cteq-uc.a.run.app/` → 302 to
   accounts.google.com with `client_id=...agrun-iap...`. No IAP re-toggle needed -
   the settings change took effect in seconds.

Housekeeping note: the client `agrun-iap` has an orphaned first secret
(`****Bcek`, unretrievable - the creation dialog was dismissed before capture); the
live one is `****hvm-`. The old one can be disabled/deleted in the console.

## Remaining steps

1. Phone test: open `https://agrun-default-zozv65cteq-uc.a.run.app/?fontSize=16` in
   the phone browser, sign in as a test-user account, drive agy. (ttyd accepts xterm
   client options as URL query args - fontSize is the important one on mobile.)
2. Likely follow-up: a small same-origin wrapper page with a key toolbar (Esc, Ctrl,
   Tab, arrows) - phone keyboards lack them and agy menus need arrows. Must be
   same-origin with ttyd to inject keys into the iframe, so serve wrapper + proxied
   ttyd from one port rather than two.
3. **IAP breaks the dashboard's local proxy for that service** (found 2026-07-26):
   `gcloud run services proxy` (dashboard/server.js) gets 401 on IAP-enabled
   services - it mints ID tokens with audience = service URL, but IAP requires
   audience = the IAP OAuth client ID, and user accounts can't mint those with
   plain gcloud. Not fixable by granting accessor to the gcloud account. So IAP
   vs proxy is per-service either/or right now. Laptop access to an IAP'd service
   still works fine through the browser (same run.app URL, sign in as a test-user
   account) - tmux allows phone + laptop attached simultaneously.
4. Decide per-session defaults: given the above, `deploy-cloud.sh --iap` would mean
   "browser/phone access, no dashboard proxy" for that session. (IAP + IAM invoker
   + accessor grants per service; the OAuth client is already project-level so no
   per-service OAuth work.)
5. Blog post: the layered-stack explanation above + the Option A/B trade-off + the
   no-org OAuth detour is the outline. Angle: "wake your cloud coding agent by
   opening a browser tab; it costs nothing while you're not looking at it."
   Console screenshots from the setup session are in
   `~/agrun-phone-access-screenshots/` on the yk2 Mac (wizard steps, IAP panel,
   client creation); redact project ID / emails / run.app URL before publishing.

## Cost notes

- IAP path: $0 idle (scale-to-zero), normal request-time billing while connected.
- Tailscale fallback: deploy with `-a`, ~$0.15/hr while pinned; tear down after.
