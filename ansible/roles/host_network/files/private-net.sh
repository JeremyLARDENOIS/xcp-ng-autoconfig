#!/bin/sh
# Activate the project network and assign its private host address.
set -eu
# systemd does not inherit the interactive shell PATH.
PATH=/opt/xensource/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
address=$1
# An active xapi.service does not guarantee that its API is ready.
attempt=0
until host=$(timeout 5 xe host-list --minimal); do
    attempt=$((attempt+1))
    if [ "$attempt" -ge 20 ]; then
        echo 'XAPI did not become available in time' >&2
        exit 1
    fi
    sleep 2
done
network=$(xe network-list name-label=private-net --minimal)
case "$network" in ''|*,*) echo 'Expected one private-net network' >&2; exit 1;; esac
case "$host" in ''|*,*) echo 'Expected a single-host pool' >&2; exit 1;; esac
test "$(xe network-param-get uuid="$network" param-name=bridge)" = private-net
test -z "$(xe pif-list network-uuid="$network" --minimal)"
if ! ip link show dev private-net >/dev/null 2>&1; then
    xe network-attach uuid="$network" host-uuid="$host"
    echo CHANGED
fi
current=$(ip -4 -o address show dev private-net | awk '{print $4}')
if [ -n "$current" ] && [ "$current" != "$address" ]; then
    echo 'Unexpected IPv4 address on private-net; refusing to replace it' >&2
    exit 1
fi
if [ -z "$current" ]; then
    ip address add "$address" dev private-net
    echo CHANGED
fi

# Only the router (.1) may use Dom0 as an Internet gateway.
router="${address%.*}.1"
uplink=$(ip -4 route show default | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')
case "$uplink" in ''|*' '*|*'
'*) echo 'Expected one IPv4 default interface' >&2; exit 1;; esac
test "$uplink" != private-net

ensure_rule() {
    tool=$1; table=$2; chain=$3; placement=$4
    shift 4
    if ! "$tool" -t "$table" -C "$chain" "$@" 2>/dev/null; then
        "$tool" -t "$table" "$placement" "$chain" "$@"
        echo CHANGED
    fi
}

# These chains belong to this project. Never flush the host firewall.
if ! iptables -t filter -S XCPNG-PRIVATE-FWD >/dev/null 2>&1; then
    iptables -t filter -N XCPNG-PRIVATE-FWD
    echo CHANGED
fi
ensure_rule iptables filter XCPNG-PRIVATE-FWD -A -i private-net -s "$router/32" -o "$uplink" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
ensure_rule iptables filter XCPNG-PRIVATE-FWD -A -i "$uplink" -o private-net -d "$router/32" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ensure_rule iptables filter XCPNG-PRIVATE-FWD -A -j DROP
ensure_rule iptables filter FORWARD -I -i private-net -j XCPNG-PRIVATE-FWD
ensure_rule iptables filter FORWARD -I -o private-net -j XCPNG-PRIVATE-FWD
ensure_rule iptables nat POSTROUTING -I -s "$router/32" -o "$uplink" -m comment --comment xcpng-private-net -j MASQUERADE
# No IPv6 forwarding is provided by this project.
ensure_rule ip6tables filter FORWARD -I -i private-net -m comment --comment xcpng-private-net -j DROP
ensure_rule ip6tables filter FORWARD -I -o private-net -m comment --comment xcpng-private-net -j DROP
if [ "$(sysctl -n net.ipv4.ip_forward)" != 1 ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo CHANGED
fi
