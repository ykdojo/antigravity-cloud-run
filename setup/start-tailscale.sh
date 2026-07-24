#!/bin/bash
# Join the tailnet as an inbound-only node; no-op unless TS_AUTHKEY is set.
# Usage: start-tailscale.sh <node-hostname>
#
# Userspace mode + in-memory state: no TUN device or root needed (works in
# plain Docker and Cloud Run gen2), and nodes self-remove when the instance
# dies. Inbound tailnet connections are proxied to the same local port;
# outbound into the tailnet is impossible (and the ACL forbids it anyway).

AGENTS=/home/agrun/.gemini/AGENTS.md

# Tailscale appends -1, -2 ... when a name is taken, so the assigned name is
# the only one worth reporting
assigned_name() {
    tailscale status --json | grep -m1 '"DNSName"' | cut -d'"' -f4 | cut -d. -f1
}

# Tell the agent where it lives, so it can hand the user working URLs. Rewritten
# on every start: the name changes, and a session that stops using tailscale
# shouldn't keep stale instructions.
write_agents_block() {
    [ -f "$AGENTS" ] || return 0
    sed -i '/<!-- tailscale -->/,/<!-- \/tailscale -->/d' "$AGENTS"
    [ -n "$1" ] || return 0
    cat >> "$AGENTS" <<EOF

<!-- tailscale -->
# Tailscale

This session is on the user's private Tailscale network as \`$1\`. Any port you
listen on is reachable from their own machines at \`http://$1:<port>\` - tell
them that address when you start a server. Nothing is exposed publicly, and you
cannot reach their machines from here (inbound only).
<!-- /tailscale -->
EOF
}

if [ -z "$TS_AUTHKEY" ]; then
    write_agents_block ""
    exit 0
fi
NODE_HOSTNAME="${1:?usage: start-tailscale.sh <node-hostname>}"

# Already joined (restarted session reusing a running container)
if pgrep -x tailscaled >/dev/null; then
    write_agents_block "$(assigned_name)"
    exit 0
fi

tailscaled --tun=userspace-networking --state=mem: \
    >> /home/agrun/.tailscaled.log 2>&1 &

for _ in $(seq 1 20); do
    [ -S /var/run/tailscale/tailscaled.sock ] && break
    sleep 0.5
done

if ! tailscale up --auth-key="$TS_AUTHKEY" --hostname="$NODE_HOSTNAME" --timeout=30s; then
    echo "tailscale: failed to join (see /home/agrun/.tailscaled.log)" >&2
    exit 0
fi

NAME=$(assigned_name)
echo "tailscale: joined as $NAME"
write_agents_block "$NAME"
