set -eu
vm=$1
sr=$2
stage=$3
test "$(xe vm-param-get uuid="$vm" param-name=is-a-template)" = false
cd "$stage"
sha256sum --check seed.sha256
wanted=$(awk '{print $1}' seed.sha256)
imported=$(xe vm-param-get uuid="$vm" param-name=other-config param-key=seed-sha256 2>/dev/null || true)
if [ -n "$imported" ] && [ "$imported" != "$wanted" ]; then
    echo 'Cloud-init seed changed; configure an existing guest with Ansible instead' >&2
    exit 1
fi
vbd=$(xe vbd-list vm-uuid="$vm" userdevice=1 --minimal)
case "$vbd" in *,*) echo 'Multiple seed attachments' >&2; exit 1;; esac
if [ -z "$imported" ]; then
    test "$(xe vm-param-get uuid="$vm" param-name=power-state)" = halted
    disk=$(xe vm-param-get uuid="$vm" param-name=other-config param-key=seed-vdi 2>/dev/null || true)
    if [ -z "$disk" ]; then
        disk=$(xe vdi-create sr-uuid="$sr" name-label=router-v1-seed type=user virtual-size="$(stat -c %s seed.iso)")
        xe vm-param-set uuid="$vm" other-config:seed-vdi="$disk"
        echo CHANGED
    fi
    test -z "$vbd"
    xe vdi-import uuid="$disk" filename="$stage/seed.iso" format=raw
    xe vm-param-set uuid="$vm" other-config:seed-sha256="$wanted"
    echo CHANGED
else
    disk=$(xe vm-param-get uuid="$vm" param-name=other-config param-key=seed-vdi)
fi
if [ -z "$vbd" ]; then
    xe vbd-create vm-uuid="$vm" vdi-uuid="$disk" device=1 type=Disk mode=RO bootable=false other-config:owner=true >/dev/null
    echo CHANGED
else
    test "$(xe vbd-param-get uuid="$vbd" param-name=vdi-uuid)" = "$disk"
fi
# The pool and VM flags are both required by XAPI's auto power-on mechanism.
pool=$(xe pool-list --minimal)
if [ "$(xe pool-param-get uuid="$pool" param-name=other-config param-key=auto_poweron 2>/dev/null || true)" != true ]; then
    xe pool-param-set uuid="$pool" other-config:auto_poweron=true
    echo CHANGED
fi
if [ "$(xe vm-param-get uuid="$vm" param-name=other-config param-key=auto_poweron 2>/dev/null || true)" != true ]; then
    xe vm-param-set uuid="$vm" other-config:auto_poweron=true
    echo CHANGED
fi
state=$(xe vm-param-get uuid="$vm" param-name=power-state)
case "$state" in
 halted) xe vm-start uuid="$vm"; echo CHANGED;;
 running) :;;
 *) echo "Unexpected router power state: $state" >&2; exit 1;;
esac
# Starting the first VM may cause XAPI to reconfigure the bridge.
systemctl restart xcpng-private-net.service
