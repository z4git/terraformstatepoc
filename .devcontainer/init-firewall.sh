#!/bin/bash
# Allow-by-default egress firewall for the devcontainer.
#
# Everything outbound to the internet is allowed. What is blocked is traffic
# to local/private address space: the LAN, the Docker host, link-local and
# CGNAT ranges. The point is to keep an agent running inside the container
# from reaching other machines on the local network, while leaving normal
# internet access (package registries, APIs, git hosts) unrestricted.
#
# Kept open so the container itself still works: loopback, DNS, and traffic
# within nested docker bridge networks (container-to-container).
#
# Re-apply with: sudo /usr/local/bin/init-firewall.sh
set -euo pipefail
IFS=$'\n\t'

# Private / local ranges that must not be reachable from inside the container.
BLOCKED_RANGES=(
    10.0.0.0/8      # RFC1918
    172.16.0.0/12   # RFC1918 (includes docker bridge nets; intra-bridge traffic is exempted below)
    192.168.0.0/16  # RFC1918
    169.254.0.0/16  # link-local
    100.64.0.0/10   # CGNAT / shared address space
)

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root: sudo /usr/local/bin/init-firewall.sh" >&2
    exit 1
fi

# dockerd owns a pile of chains in filter and nat. Stop it before flushing so
# it isn't left running against rules that no longer exist; it gets started
# again at the end of this script, once the policy below is in place.
if command -v dockerd >/dev/null 2>&1; then
    echo "==> stopping dockerd while rules are rebuilt"
    pkill -x dockerd 2>/dev/null || true
    pkill -x containerd 2>/dev/null || true
fi

echo "==> flushing existing rules"
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true
ipset destroy blocked-local 2>/dev/null || true

ipset create blocked-local hash:net
for cidr in "${BLOCKED_RANGES[@]}"; do
    ipset add blocked-local "$cidr"
done

echo "==> applying allow-by-default policy (local ranges blocked)"
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Loopback stays fully open (also covers Docker's embedded DNS at 127.0.0.11).
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# DNS must keep working even when the resolver sits on a local address.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Replies to connections initiated from outside (host port-forwards into the
# container, e.g. the VS Code server bridge) must not be dropped by the
# local-range block below.
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Block everything addressed to local/private space; all other traffic falls
# through to the ACCEPT policy.
iptables -A OUTPUT -m set --match-set blocked-local dst -j DROP
iptables -A INPUT -m set --match-set blocked-local src -m state --state NEW -j DROP

# --- nested containers (docker-in-docker) ----------------------------------
# Traffic from a nested container is *forwarded* (bridge -> eth0), so it never
# hits the OUTPUT chain above. DOCKER-USER is the one chain dockerd creates
# but never rewrites, and it jumps there first, so the same local-range block
# is repeated here. Container-to-container within a nested docker network is
# exempted — that is bridge-local, not the LAN.
if command -v dockerd >/dev/null 2>&1; then
    echo "==> constraining nested containers via DOCKER-USER"
    iptables -N DOCKER-USER 2>/dev/null || true
    iptables -F DOCKER-USER
    iptables -A DOCKER-USER -m state --state ESTABLISHED,RELATED -j RETURN
    iptables -A DOCKER-USER -p udp --dport 53 -j RETURN
    iptables -A DOCKER-USER -p tcp --dport 53 -j RETURN
    iptables -A DOCKER-USER -i docker0 -o docker0 -j RETURN
    iptables -A DOCKER-USER -i br+ -o br+ -j RETURN
    iptables -A DOCKER-USER -m set --match-set blocked-local dst -j DROP
    iptables -A DOCKER-USER -j RETURN
fi

# Mirror the policy for IPv6: allow by default, block local scopes. ICMPv6 to
# link-local is required for neighbour/router discovery, so it stays open.
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -P INPUT ACCEPT 2>/dev/null || true
    ip6tables -P FORWARD ACCEPT 2>/dev/null || true
    ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    ip6tables -F 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -p ipv6-icmp -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -d fc00::/7 -j DROP 2>/dev/null || true
    ip6tables -A OUTPUT -d fe80::/10 -j DROP 2>/dev/null || true
fi

echo "==> verifying"
if ! curl --connect-timeout 5 -sS https://example.com >/dev/null 2>&1; then
    echo "ERROR: firewall too strict — example.com is unreachable" >&2
    exit 1
fi
# The image has no ping binary, so probe the host gateway with curl instead:
# a DROP shows up as a connect timeout (exit 28); anything else — connected
# (0) or refused (7) — means the packet reached the gateway, i.e. a leak.
HOST_IP=$(ip route | awk '/^default/ {print $3; exit}')
if [ -n "${HOST_IP:-}" ]; then
    curl_rc=0
    curl --connect-timeout 3 -sS "http://${HOST_IP}:80" -o /dev/null 2>/dev/null || curl_rc=$?
    if [ "$curl_rc" -ne 28 ]; then
        echo "ERROR: firewall leaking — host $HOST_IP is reachable (curl exit $curl_rc)" >&2
        exit 1
    fi
fi
echo "==> firewall active (allow by default, local ranges blocked: ${BLOCKED_RANGES[*]})"

# --- start the nested docker daemon ----------------------------------------
# Deliberately last: dockerd installs its chains on startup, and everything
# above flushes filter/nat, so starting it any earlier would just lose them.
if command -v dockerd >/dev/null 2>&1; then
    echo "==> starting dockerd"
    # We are root, so the feature's script starts the daemon directly rather
    # than via the sudo call that `node` is not permitted to make.
    /usr/local/share/docker-init.sh

    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: dockerd did not come up — see /tmp/dockerd.log" >&2
        exit 1
    fi

    # dockerd re-inserts its own jumps into FORWARD on start. Re-seat
    # DOCKER-USER at the top so the local-range block is evaluated before them.
    iptables -D FORWARD -j DOCKER-USER 2>/dev/null || true
    iptables -I FORWARD 1 -j DOCKER-USER

    echo "==> dockerd up (nested containers blocked from local ranges too)"
fi
