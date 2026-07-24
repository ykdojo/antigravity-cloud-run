# Tailscale: reaching arbitrary ports inside the Cloud Run dev env

Design note - not implemented yet. Captures the plan and threat model for
exposing dev servers running inside the container (e.g. `localhost:3000`)
to my own machines, privately.

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

Stored in Secret Manager and injected as `TS_AUTHKEY`, same pattern as
`AGY_OAUTH_TOKEN`. Never in this repo (it's public), never in build args
(they persist in image layers).

## Naming

The node hostname reuses the service name: `agrun-${SESSION_NAME}`.
MagicDNS then resolves it on every tailnet device, so a dev server is
just `http://agrun-<session>:3000` from my machine. Full form:
`agrun-<session>.<tailnet>.ts.net`.

## ACL: inbound-only containers

Tailscale ACLs are a pure allow-list - anything not explicitly granted
is denied. A tag by itself denies nothing (the default allow-all policy
would still let tagged nodes reach everything); the confinement comes
from never listing `tag:agrun` as a `src`.

```json
{
  "tagOwners": { "tag:agrun": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:member:*"] },
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:agrun:*"] }
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

- [ ] Dockerfile: install `tailscale` (apt repo, same pattern as gh CLI)
- [ ] `setup/entrypoint-cloud.sh`: if `TS_AUTHKEY` is set, start
      `tailscaled --tun=userspace-networking --state=mem:` then
      `tailscale up --auth-key=$TS_AUTHKEY --hostname=agrun-${SESSION_NAME}`
- [ ] `scripts/deploy-cloud.sh`: inject `TS_AUTHKEY` from Secret Manager;
      confirm gen2 execution environment
- [ ] Admin console (manual): create tagged ephemeral key, install ACL
- [ ] README: usage section
