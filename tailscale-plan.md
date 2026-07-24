# Tailscale: reaching arbitrary ports inside the dev env sessions

Design note - not implemented yet. Captures the plan and threat model for
exposing dev servers running inside a session container (e.g.
`localhost:3000`) to my own machines, privately. Applies to both cloud
and local sessions - same mechanism, same key, same ACL.

## Problem

Cloud Run exposes exactly one port per service - the `--port` value from
`deploy-cloud.sh` (7681, ttyd). `gcloud run services proxy` only reaches
that port. Any other server started inside the container is unreachable
from outside. Options considered:

1. **Cloudflare quick tunnel** - zero setup, but the URL is public
   (unauthenticated) and per-port, per-session.
2. **Path-based reverse proxy on $PORT** - stays behind IAM, but needs
   image changes and many dev servers misbehave behind a path prefix.
3. **Tailscale** - container joins the tailnet; any port reachable
   privately from my machines. Chosen.

Local sessions have a milder version of the same problem: extra ports
would need Docker port mappings decided at container-creation time, and
even then they only exist on this machine's localhost - the other Mac
can't reach them. Rather than maintain a second mechanism, local
containers join the tailnet the same way (userspace mode needs no TUN
device or container privileges, so it runs in plain Docker too).

## How it works on Cloud Run

- No `/dev/net/tun` in the Cloud Run sandbox, so `tailscaled` runs with
  `--tun=userspace-networking` (netstack). **Inbound connections work
  fine** in this mode - tailscaled accepts them itself and forwards to
  `localhost:<port>`. Outbound from the container into the tailnet would
  need the SOCKS5 proxy, but we don't need that direction (and the ACL
  below forbids it anyway).
- Requires the gen2 execution environment.
- Instances are ephemeral, so no interactive login: `tailscale up` uses a
  pre-generated auth key, and `--state=mem:` keeps node identity in
  memory only.

## Auth key

Generated in the Tailscale admin console (Settings -> Keys):

- **Ephemeral**: nodes self-remove from the tailnet when the instance
  dies - no dead `agrun-*` machines accumulating.
- **Reusable**: every new instance can register with the same key.
- **Tagged** (`tag:agrun`): gives container nodes a distinct identity the
  ACL can confine (see below).
- **Expiry**: pick the shortest workable window; bounds a leak.

Saved as `~/.config/agrun/.secrets/TS_AUTHKEY`, which rides the existing
secrets pipeline with no extra plumbing: `run.sh` injects it into local
containers' `/home/agrun/.env`, and `deploy-cloud.sh` syncs it to Secret
Manager and wires it into every cloud service as an env var. Never in
this repo (it's public), never in build args (they persist in image
layers).

## Naming

The node hostname reuses the session name, with a prefix that tells the
two environments apart so a local and a cloud session with the same name
never collide in MagicDNS (Tailscale would silently rename one to
`...-1`):

- cloud: `agrun-<session>`
- local: `agrun-local-<session>`

MagicDNS resolves these on every tailnet device, so a dev server is just
`http://agrun-<session>:3000` from my machine. Full form:
`agrun-<session>.<tailnet>.ts.net`.

## ACL: inbound-only containers

Tailscale ACLs are a pure allow-list - anything not explicitly granted
is denied. A tag by itself denies nothing (the default allow-all policy
would still let tagged nodes reach everything); the confinement comes
from never listing `tag:agrun` as a `src`. In the current `grants`
syntax (the tailnet's policy file uses it; `"ip": ["*"]` means all ports
and protocols; the default Tailscale SSH block is kept as-is):

```json
{
  "tagOwners": { "tag:agrun": ["autogroup:admin"] },
  "grants": [
    { "src": ["autogroup:member"], "dst": ["autogroup:member"], "ip": ["*"] },
    { "src": ["autogroup:member"], "dst": ["tag:agrun"], "ip": ["*"] }
  ]
}
```

Resulting trust picture:

- **my devices** (`autogroup:member`): full access to each other and to
  the containers, same as today.
- **containers** (`tag:agrun`): can initiate nothing on the tailnet.
  Internet egress (git, npm, Google APIs) is unaffected - ACLs only
  govern tailnet traffic.

Threat model for a leaked auth key: the attacker can join the tailnet as
a `tag:agrun` node, which matches no `src` rule (can reach nothing) and
no `dst` rule (can't be reached). Cleanup is revoke key + delete node in
the admin console. The key can't touch the Tailscale account or GCP.

Claude-in-Chrome cross-machine control rides Anthropic's relay over the
normal internet, not the tailnet - unaffected by this policy.

## Implementation checklist

Manual (admin console, once):

- [x] Install the ACL above (JSON editor on the Access controls page);
      `tagOwners` must exist before a tagged key can be created. Note:
      the tailnet's policy file uses the `grants` syntax; the default
      Tailscale SSH block was commented out (unused on a two-Mac tailnet).
- [x] Create the auth key (reusable, ephemeral, pre-approved, `tag:agrun`,
      90-day expiry) and save it as `~/.config/agrun/.secrets/TS_AUTHKEY`
      (via `npm run manage-env`; done on both Macs)

Code:

- [x] Dockerfile: install `tailscale` (apt repo, same pattern as gh CLI)
- [x] Shared `setup/start-tailscale.sh`: if `TS_AUTHKEY` is set, start
      `tailscaled --tun=userspace-networking --state=mem:` then
      `tailscale up --auth-key=$TS_AUTHKEY --hostname=<node name>`
- [x] `setup/entrypoint-cloud.sh`: call it with `agrun-${SESSION_NAME}`
- [x] Local startup path (`run.sh`): call it with `agrun-local-<session>`,
      sourcing `/home/agrun/.env` first (docker exec doesn't see .secrets)
- [x] `scripts/deploy-cloud.sh`: no injection change needed (`.secrets`
      sync already delivers `TS_AUTHKEY`); gen2 already set
- [x] README: usage section
- [x] Verify both directions (2026-07-24, local + cloud): dev server
      reachable from this Mac; container cannot reach the Mac (curl timeout)
