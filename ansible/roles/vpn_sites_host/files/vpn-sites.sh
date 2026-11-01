#!/bin/sh
# Inputs are validated by the controller before this Dom0 helper is installed.
set -eu
PATH=/opt/xensource/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
router=$1
host_address=$2
endpoint=$3
peer_endpoint=$4
remote_lan=$5
remote_admin=$6
remote_xoa=$7
uplink=$(ip -4 route show default | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')
case "$uplink" in ''|*' '*|*'
'*) echo 'Expected one IPv4 default interface' >&2; exit 1;; esac
test "$uplink" != private-net
ip link show dev private-net >/dev/null

state_dir=/var/lib/xcpng-autoconfig
routes_file=$state_dir/sites-vpn-routes
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Each saved line records a route actually created by this project. Matching
# routes that predate this role stay foreign and are never claimed or removed.
if [ -f "$routes_file" ]; then cat "$routes_file" > "$work/previous"; else : > "$work/previous"; fi
printf '%s via %s dev private-net\n' "$remote_lan" "$router" > "$work/desired"
if [ -n "$remote_admin" ]; then
    printf '%s via %s dev private-net\n' "${remote_admin%/32}" "$router" >> "$work/desired"
fi
: > "$work/owned"

# Reject conflicting foreign routes before touching routes or firewall chains.
while IFS= read -r desired; do
    prefix=${desired%% *}
    current=$(ip -4 route show exact "$prefix")
    case "$current" in ''|"$desired"|"$desired "*) continue;; esac
    old=$(awk -v prefix="$prefix" '$1 == prefix {print}' "$work/previous")
    case "$current" in
        "$old"|"$old "*) [ -n "$old" ] && continue;;
    esac
    echo 'Conflicting foreign intersite route; refusing to overwrite it' >&2
    exit 1
done < "$work/desired"

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
            # Generated rule fields contain validated IPv4 addresses/interfaces.
            set -- $rule
            iptables -t "$table" "$@"
        done
        echo CHANGED
    fi
}
reconcile_chain nat XCPNG-SITES-DNAT "-A XCPNG-SITES-DNAT -s $peer_endpoint/32 -d $endpoint/32 -i $uplink -p udp -m udp --dport 51820 -j DNAT --to-destination $router:51820"
reconcile_chain filter XCPNG-SITES-FWD "-A XCPNG-SITES-FWD -s $peer_endpoint/32 -d $router/32 -i $uplink -o private-net -p udp -m udp --dport 51820 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
-A XCPNG-SITES-FWD -s $router/32 -d $peer_endpoint/32 -i private-net -o $uplink -p udp -m udp --sport 51820 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT"
# A missing private route must not send Dom0's private traffic to the uplink.
output_rules="-A XCPNG-SITES-OUT -d $remote_lan -o $uplink -j DROP"
if [ -n "$remote_admin" ]; then
    output_rules="$output_rules
-A XCPNG-SITES-OUT -d $remote_admin -o $uplink -j DROP"
fi
reconcile_chain filter XCPNG-SITES-OUT "$output_rules"
input_rules="-A XCPNG-SITES-IN -s $remote_lan -d $host_address/32 -i private-net -p tcp -j ACCEPT
-A XCPNG-SITES-IN -s $remote_lan -d $host_address/32 -i private-net -p udp -j ACCEPT"
if [ -n "$remote_admin" ]; then
    input_rules="$input_rules
-A XCPNG-SITES-IN -s $remote_admin -d $host_address/32 -i private-net -p tcp -m multiport --dports 22,443 -j ACCEPT
-A XCPNG-SITES-IN -s $remote_admin -d $host_address/32 -i private-net -p icmp -j ACCEPT"
fi
if [ -n "$remote_xoa" ]; then
    [ -z "$input_rules" ] || input_rules="$input_rules
"
    input_rules="${input_rules}-A XCPNG-SITES-IN -s $remote_xoa/32 -d $host_address/32 -i private-net -p tcp -m tcp --dport 443 -j ACCEPT
-A XCPNG-SITES-IN -s $remote_xoa/32 -d $host_address/32 -i private-net -p icmp -j ACCEPT"
fi
reconcile_chain filter XCPNG-SITES-IN "$input_rules"
if ! iptables -t nat -C PREROUTING -j XCPNG-SITES-DNAT 2>/dev/null; then
    iptables -t nat -I PREROUTING 1 -j XCPNG-SITES-DNAT
    echo CHANGED
fi
if ! iptables -C FORWARD -j XCPNG-SITES-FWD 2>/dev/null; then
    iptables -I FORWARD 1 -j XCPNG-SITES-FWD
    echo CHANGED
fi
if ! iptables -C OUTPUT -j XCPNG-SITES-OUT 2>/dev/null; then
    iptables -I OUTPUT 1 -j XCPNG-SITES-OUT
    echo CHANGED
fi
if ! iptables -C INPUT -i private-net -j XCPNG-SITES-IN 2>/dev/null; then
    iptables -I INPUT 1 -i private-net -j XCPNG-SITES-IN
    echo CHANGED
fi

# Remove only recorded routes whose live next hop still matches our record.
while IFS= read -r previous; do
    if ! awk -v route="$previous" '$0 == route {found=1} END {exit !found}' "$work/desired"; then
        prefix=${previous%% *}
        current=$(ip -4 route show exact "$prefix")
        case "$current" in
            "$previous"|"$previous "*)
                set -- $previous
                ip route del "$@"
                echo CHANGED;;
        esac
    fi
done < "$work/previous"
while IFS= read -r desired; do
    prefix=${desired%% *}
    current=$(ip -4 route show exact "$prefix")
    if [ -z "$current" ]; then
        set -- $desired
        ip route add "$@"
        printf '%s\n' "$desired" >> "$work/owned"
        echo CHANGED
    elif awk -v route="$desired" '$0 == route {found=1} END {exit !found}' "$work/previous"; then
        printf '%s\n' "$desired" >> "$work/owned"
    fi
done < "$work/desired"
mkdir -p "$state_dir"
if ! cmp -s "$work/owned" "$routes_file"; then
    install -m 0600 "$work/owned" "$routes_file"
    echo CHANGED
fi
