#!/bin/bash
# Join the tailnet as an inbound-only node (design: tailscale-plan.md).
# No-op unless TS_AUTHKEY is set. Usage: start-tailscale.sh <node-hostname>
#
# Userspace mode: no TUN device or root needed, so the same script works in
# plain Docker and Cloud Run gen2. Inbound connections from the tailnet are
# proxied to the same port on localhost; outbound into the tailnet doesn't
# work in this mode (and the ACL forbids it anyway). --state=mem: because
# the key is ephemeral: nodes self-remove when the instance dies.

[ -n "$TS_AUTHKEY" ] || exit 0
NODE_HOSTNAME="${1:?usage: start-tailscale.sh <node-hostname>}"

# Already joined (restarted session reusing a running container)
pgrep -x tailscaled >/dev/null && exit 0

SOCKET=/home/agrun/.tailscaled.sock

tailscaled --tun=userspace-networking --state=mem: --socket="$SOCKET" \
    >> /home/agrun/.tailscaled.log 2>&1 &

for _ in $(seq 1 20); do
    [ -S "$SOCKET" ] && break
    sleep 0.5
done

if tailscale --socket="$SOCKET" up --auth-key="$TS_AUTHKEY" \
        --hostname="$NODE_HOSTNAME" --timeout=30s; then
    echo "tailscale: joined as $NODE_HOSTNAME"
else
    echo "tailscale: failed to join (see /home/agrun/.tailscaled.log)" >&2
fi
