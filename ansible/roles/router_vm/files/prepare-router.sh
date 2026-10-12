set -eu
sr=$1
template=$2
network=$(xe network-list name-label=private-net --minimal)
case "$network" in ''|*,*) echo 'Expected one private network' >&2; exit 1;; esac
vm=$(xe vm-list name-label=router-v1 is-a-template=false is-control-domain=false --minimal)
case "$vm" in *,*) echo 'Multiple router VMs' >&2; exit 1;; esac
# A previous vm-copy could have copied the template flag as well.
failed_template=$(xe template-list name-label=router-v1 --minimal)
case "$failed_template" in *,*) echo 'Multiple router templates' >&2; exit 1;; esac
if [ -n "$failed_template" ]; then
    test -z "$vm"
    test "$(xe vm-param-get uuid="$failed_template" param-name=other-config param-key=xcpng-autoconfig-router)" = v1
    test "$(xe vm-param-get uuid="$failed_template" param-name=power-state)" = halted
    test -z "$(xe template-list name-label=router-v1-failed-copy --minimal)"
    xe vm-param-set uuid="$failed_template" name-label=router-v1-failed-copy other-config:auto_poweron=false
    echo CHANGED
fi
if [ -z "$vm" ]; then
    vm=$(xe vm-install template-uuid="$template" sr-uuid="$sr" new-name-label=router-v1)
    xe vm-param-set uuid="$vm" other-config:xcpng-autoconfig-router=v1
    echo CHANGED
fi
test "$(xe vm-param-get uuid="$vm" param-name=other-config param-key=xcpng-autoconfig-router)" = v1
test "$(xe vm-param-get uuid="$vm" param-name=is-a-template)" = false
if [ "$(xe vm-param-get uuid="$vm" param-name=HVM-boot-params param-key=firmware 2>/dev/null || true)" != uefi ] ||
   [ "$(xe vm-param-get uuid="$vm" param-name=platform param-key=device-model 2>/dev/null || true)" != qemu-upstream-uefi ]; then
    test "$(xe vm-param-get uuid="$vm" param-name=power-state)" = halted
    xe vm-param-set uuid="$vm" HVM-boot-params:firmware=uefi platform:device-model=qemu-upstream-uefi
    echo CHANGED
fi
if xe vm-param-get uuid="$vm" param-name=platform param-key=firmware >/dev/null 2>&1; then
    xe vm-param-remove uuid="$vm" param-name=platform param-key=firmware
    echo CHANGED
fi
# Match the hardware defaults of XCP-ng's Debian UEFI template.
for setting in pae=true nx=true apic=true acpi=1 hpet=true viridian=false vga=std videoram=8 device_id=0001; do
    key=${setting%%=*}
    value=${setting#*=}
    if [ "$(xe vm-param-get uuid="$vm" param-name=platform param-key="$key" 2>/dev/null || true)" != "$value" ]; then
        test "$(xe vm-param-get uuid="$vm" param-name=power-state)" = halted
        xe vm-param-set uuid="$vm" "platform:$key=$value"
        echo CHANGED
    fi
done
root_vbd=$(xe vbd-list vm-uuid="$vm" userdevice=0 --minimal)
case "$root_vbd" in ''|*,*) echo 'Expected one root disk' >&2; exit 1;; esac
root=$(xe vbd-param-get uuid="$root_vbd" param-name=vdi-uuid)
test "$(xe vdi-param-get uuid="$root" param-name=sr-uuid)" = "$sr"
size=$(xe vdi-param-get uuid="$root" param-name=virtual-size)
if [ "$size" -lt 8589934592 ]; then
    test "$(xe vm-param-get uuid="$vm" param-name=power-state)" = halted
    xe vdi-resize uuid="$root" disk-size=8589934592
    echo CHANGED
fi
vif=$(xe vif-list vm-uuid="$vm" --minimal)
case "$vif" in *,*) echo 'Expected one router interface' >&2; exit 1;; esac
if [ -z "$vif" ]; then
    test "$(xe vm-param-get uuid="$vm" param-name=power-state)" = halted
    vif=$(xe vif-create vm-uuid="$vm" network-uuid="$network" device=0 mac=random)
    echo CHANGED
fi
test "$(xe vif-param-get uuid="$vif" param-name=network-uuid)" = "$network"
printf 'VM_UUID=%s\n' "$vm"
printf 'VIF_MAC=%s\n' "$(xe vif-param-get uuid="$vif" param-name=MAC)"
