#!/bin/sh
# Reconcile only the project's administration VPN rules.
set -eu
PATH=/opt/xensource/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
router=$1
network=$2
endpoint=$3
client=$4
host_address=$5
enabled=$6
uplink=$(ip -4 route show default | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')
case "$uplink" in ''|*' '*|*'
'*) echo 'Expected one IPv4 default interface' >&2; exit 1;; esac
ip link show private-net >/dev/null

# Reconcile complete owned chains so changing an endpoint removes the old rule.
reconcile_chain() {
    table=$1; chain=$2; desired=$3
    if ! iptables -t "$table" -S "$chain" >/dev/null 2>&1; then
        iptables -t "$table" -N "$chain"
        echo CHANGED
    fi
    current=$(iptables -t "$table" -S "$chain" | sed '1d')
    if [ "$current" != "$desired" ]; then
        iptables -t "$table" -F "$chain"
        printf '%s\n' "$desired" | while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            # Rule text is generated below from validated addresses and an interface.
            set -- $rule
            iptables -t "$table" "$@"
        done
        echo CHANGED
    fi
}
reconcile_chain nat XCPNG-ADMIN-DNAT "-A XCPNG-ADMIN-DNAT -d $endpoint/32 -i $uplink -p udp -m udp --dport 51821 -j DNAT --to-destination $router:51821"
reconcile_chain filter XCPNG-ADMIN-FWD "-A XCPNG-ADMIN-FWD -d $router/32 -i $uplink -o private-net -p udp -m udp --dport 51821 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
-A XCPNG-ADMIN-FWD -s $router/32 -i private-net -o $uplink -p udp -m udp --sport 51821 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
input_rules=''
if [ "$enabled" = true ]; then
    input_rules="-A XCPNG-ADMIN-IN -s $client -d $host_address/32 -i private-net -p tcp -m multiport --dports 22,443 -j ACCEPT
-A XCPNG-ADMIN-IN -s $client -d $host_address/32 -i private-net -p icmp -j ACCEPT"
fi
reconcile_chain filter XCPNG-ADMIN-IN "$input_rules"
if ! iptables -C INPUT -i private-net -j XCPNG-ADMIN-IN 2>/dev/null; then
    iptables -I INPUT 1 -i private-net -j XCPNG-ADMIN-IN
    echo CHANGED
fi
# These jumps precede the existing private-network DROP chain.
if ! iptables -t nat -C PREROUTING -j XCPNG-ADMIN-DNAT 2>/dev/null; then
    iptables -t nat -I PREROUTING 1 -j XCPNG-ADMIN-DNAT
    echo CHANGED
fi
if ! iptables -C FORWARD -j XCPNG-ADMIN-FWD 2>/dev/null; then
    iptables -I FORWARD 1 -j XCPNG-ADMIN-FWD
    echo CHANGED
fi
# Preserve device identities: replies from Dom0 route through the local router.
mkdir -p /var/lib/xcpng-autoconfig
previous_file=/var/lib/xcpng-autoconfig/admin-vpn-route
if [ -f "$previous_file" ]; then
    previous=$(cat "$previous_file")
    if [ "$previous" != "$network" ]; then
        ip route del "$previous" via "$router" dev private-net 2>/dev/null || true
    fi
fi
current=$(ip -4 route show exact "$network")
expected="$network via $router dev private-net"
case "$current" in
    "$expected"|"$expected "*) ;;
    '') ip route add "$network" via "$router" dev private-net; echo CHANGED;;
    *) echo 'Unexpected administration route; refusing to overwrite it' >&2; exit 1;;
esac
printf '%s\n' "$network" > "$previous_file"
