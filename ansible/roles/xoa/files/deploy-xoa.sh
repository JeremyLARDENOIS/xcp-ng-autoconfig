set -eu
sr=$1
address=$2
gateway=$3
dns=$4
vm=$(xe vm-list name-label=xoa-v1 is-a-template=false --minimal)
case "$vm" in *,*) echo 'Multiple XOA VMs' >&2; exit 1;; esac
if [ -z "$vm" ]; then
    stage="/var/run/sr-mount/$sr/.xcpng-autoconfig-xoa"
    cd "$stage"
    sha256sum --check xoa.sha256
    vm=$(xe vm-import filename="$stage/xoa.xva" sr-uuid="$sr")
    xe vm-param-set uuid="$vm" name-label=xoa-v1 other-config:xcpng-autoconfig-xoa=v1
    echo CHANGED
fi
test "$(xe vm-param-get uuid="$vm" param-name=other-config param-key=xcpng-autoconfig-xoa)" = v1
network=$(xe network-list name-label=private-net --minimal)
case "$network" in ''|*,*) echo 'Expected one private network' >&2; exit 1;; esac
vif=$(xe vif-list vm-uuid="$vm" --minimal)
case "$vif" in ''|*,*) echo 'Expected one appliance interface' >&2; exit 1;; esac
if [ "$(xe vif-param-get uuid="$vif" param-name=network-uuid)" != "$network" ]; then
    test "$(xe vm-param-get uuid="$vm" param-name=power-state)" = halted
    xe vif-move uuid="$vif" network-uuid="$network"
    echo CHANGED
fi
wanted="$address/24,$gateway,$dns"
configured=$(xe vm-param-get uuid="$vm" param-name=other-config param-key=xcpng-autoconfig-address 2>/dev/null || true)
if [ "$configured" != "$wanted" ]; then
    test "$(xe vm-param-get uuid="$vm" param-name=power-state)" = halted
    xe vm-param-set uuid="$vm" xenstore-data:vm-data/ip="$address" xenstore-data:vm-data/netmask=255.255.255.0 xenstore-data:vm-data/gateway="$gateway" xenstore-data:vm-data/dns="$dns"
    xe vm-param-set uuid="$vm" other-config:xcpng-autoconfig-address="$wanted"
    echo CHANGED
fi
if [ "$(xe vm-param-get uuid="$vm" param-name=other-config param-key=auto_poweron 2>/dev/null || true)" != true ]; then
    xe vm-param-set uuid="$vm" other-config:auto_poweron=true
    echo CHANGED
fi
case "$(xe vm-param-get uuid="$vm" param-name=power-state)" in
    halted) xe vm-start uuid="$vm"; echo CHANGED;;
    running) :;;
    *) echo 'Unexpected XOA power state' >&2; exit 1;;
esac
printf 'XOA_UUID=%s\n' "$vm"
