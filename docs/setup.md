# Set up an XCP-ng host

`ansible/playbooks/setup.yml` is the single entry point for the initial setup.
It currently creates the `private-net` internal network, then imports an
unmodified official Debian RAW image as a generic template. Host addressing,
routing, router deployment and XOA deployment will be added incrementally.
The setup also activates the private bridge and assigns the host private address.

## Requirements

- XCP-ng 8.3 hosts accessible over SSH as `root`.
- A mounted ext SR on each host.
- Ansible, Bash, `curl`, OpenSSH, `sha512sum` and `sha256sum` on the workstation.
- Workstation Internet access and space to cache the RAW image.
- SR space for both the staged image and imported disk, plus 1 GiB.

Remote tasks use Ansible's `raw` module, so the host does not need a compatible
Python interpreter. The image is neither converted nor customized.

## Prepare the inventory

Run all commands from the repository root so Ansible loads `ansible.cfg`.

```sh
mkdir -p private
cp ansible/inventory/hosts.example.yml private/hosts.yml
```

Set `ansible_host` to each host's address or SSH alias, and `template_sr_uuid`
to its destination Local storage SR UUID:

```sh
xe sr-list params=uuid,name-label,type,content-type
```

Verify SSH access and host keys before proceeding. Use an SSH agent for encrypted
keys. Transfers use the inventory host address, user and port; configure other
SSH options in your SSH configuration, since Ansible-only SSH arguments are not
forwarded to `scp`. Keep real configuration and secrets in the ignored `private/`
directory.

## Run the setup

Start with one inventory host:

```sh
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host01 --check
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host01
```

Check mode queries the host without creating resources, downloading or importing
an image. It does not validate a real import or boot. Apply runs both implemented
steps and prints their UUIDs. Repeat the apply command: resources should be reused
without reported changes. Verify the first host before repeating for other hosts.
Do not run concurrent setups against the same pool or local image cache.

## Internal network

This playbook creates an internal XAPI network named `private-net` on each
selected host, with an explicit bridge name of `private-net`. It uses `xe` without attaching a physical interface or changing
the management network. See the [XCP-ng networking documentation](https://docs.xcp-ng.org/networking/)
and the [xe command reference](https://docs.xcp-ng.org/appendix/cli_reference/).

An internal network provides Layer 2 connectivity. This step assigns no subnet,
IP address, gateway, or NAT rule. Guest addressing comes in later steps.

The playbook reuses an existing network if its name is unique, its bridge is
`private-net`, and it has no PIF. Ambiguous names and physical interfaces cause the playbook to stop.
If its bridge has another name, the playbook deletes and recreates the network
only if it has no PIF and no VIF, including interfaces of stopped VMs. Its UUID
changes. Check mode runs the required checks without deleting or creating anything.
If recreation fails after deletion, rerun the playbook to create the missing network.

### Verify the network

```sh
xe network-list name-label=private-net params=uuid,name-label,bridge
```

Connectivity can be tested once a VM is attached. The absence of an active bridge
without an attached VM does not by itself indicate failure. Persistence after
reboot has not yet been validated by this project.

## Debian template

Step 2 imports an unmodified Debian 13 cloud image into an existing ext SR.
No packages are installed in the image. It is not resized, converted or booted.
The template has no VIF, site address, injected account, key or cloud-init seed.
Guest configuration and additional packages come later.

The source is `debian-13-generic-amd64-20250811-2201.raw` from the official
Debian cloud image directory. Its SHA512 is verified against the manifest fetched
over HTTPS; detached signatures are not verified. The file is imported directly
with `xe vdi-import format=raw`, without altering its contents.

The source and checksums are cached under
`private/templates/debian-13-cloud-20250811-2201-raw-v1/`.
The XAPI template is named `debian-13-cloud-20250811-2201-raw-v1`, with 1 vCPU,
1 GiB RAM and UEFI firmware without Secure Boot. Its virtual disk retains the
source RAW image size. The future router's 8 GiB disk will be handled at deployment.

A distinct template identity separates this unmodified RAW source from any
previous customized template. Existing templates and experimental VMs are not
deleted or overwritten.

### Verify the template and test a clone

Repeat the setup: the disk must not be reimported or duplicated. On the host:

```sh
xe template-list name-label=debian-13-cloud-20250811-2201-raw-v1 params=uuid,name-label
xe vif-list vm-name-label=debian-13-cloud-20250811-2201-raw-v1
```

The VIF list should be empty. Successful import is not proof of successful boot.
To test, replace `TEMPLATE_UUID` with the reported UUID:

```sh
xe vm-clone uuid=TEMPLATE_UUID new-name-label=debian-template-test
```

Record the returned clone UUID:

```sh
xe vm-start uuid=CLONE_UUID
xe vm-list uuid=CLONE_UUID params=power-state,dom-id
```

Inspect the console in XO Lite. Check that Debian reaches the login prompt and
stays running. This clone has no network or account seed; no guest credentials
are supplied. Site-specific cloud-init configuration, SSH and guest identity
regeneration will be tested when a seeded clone is introduced.
Do not start the template itself. Record console output if boot fails.

After validation, remove only the disposable clone:

```sh
xe vm-shutdown uuid=CLONE_UUID force=true
xe vm-uninstall uuid=CLONE_UUID
```

Skip shutdown if it already stopped. Verify the clone identity and disks before
confirming removal. Keep the source template intact.

## Retry and staging files

The role records completed imports and checks template conversion on every run. An
interruption before conversion can be resumed without creating another object.
Unowned objects and changed source checksums cause failure rather than overwrite.
An interruption between creation and ownership recording may require inspection.
Remote staging files remain under
`/var/run/sr-mount/SR_UUID/.xcpng-autoconfig-template/` for retry. Remove them only
after validation, with no import running; preserve the cached source and checksums.

References: [Debian cloud images](https://wiki.debian.org/Cloud) and
[XCP-ng xe commands](https://docs.xcp-ng.org/appendix/cli_reference/).

## Remove the deployment network

Only remove a network created for this deployment, and only when no VM uses it.
Check its VIFs before deleting the network by UUID. Replace `NETWORK_UUID` with
the recorded value:

```sh
xe vif-list network-uuid=NETWORK_UUID
xe network-destroy uuid=NETWORK_UUID
```

Do not delete a pre-existing network reused by the playbook.

## Private host address

Set `bootstrap_host_address` in each inventory host to its private `.254` address
with a CIDR prefix. Use distinct private subnets for each site.

The `host_network` role activates `private-net` through `xe network-attach`, then
assigns the address without changing the public interface, default route or
firewall. It refuses multiple-host pools, physical interfaces on this network,
and conflicting private addresses. Check mode only validates and reads state.

A oneshot service, `xcpng-private-net.service`, repeats this configuration after
`xapi.service` at host boot. The script sets an explicit command search path
and waits for XAPI to answer, with bounded retries. It does not continuously
monitor the bridge.
Recovery after the last VM stops or a toolstack restart remains to be tested;
this boot service alone does not demonstrate that behavior.

Run the setup twice and check for zero changes on the second run. Reboot one
host manually, then check on the host before rerunning the setup:

```sh
systemctl status xcpng-private-net.service --no-pager
journalctl -b -u xcpng-private-net.service --no-pager
ip -4 -br address show private-net
ip -4 route show dev private-net
```

A successful oneshot service can show as inactive after completion. Verify its
exit status and the address itself. Bridge activation and private addressing at host boot have been validated.
IPv4 forwarding and outbound NAT are configured for the router address `.1`
only. Other VMs will use the router rather than bypassing it through Dom0.
Guest connectivity remains to be tested.

To undo only this step, disable the service and remove the configured address:

```sh
systemctl disable --now xcpng-private-net.service
ip address del PRIVATE_HOST_CIDR dev private-net
```

Replace `PRIVATE_HOST_CIDR` with your configured address. The internal network
and public host configuration are preserved.

### Router Internet access

The startup script enables IPv4 forwarding and detects the single default-route
interface. It adds a project-owned `XCPNG-PRIVATE-FWD` chain, scoped jumps for
traffic entering or leaving `private-net`, and a marked MASQUERADE rule for `.1`.
Only outbound router traffic and its established or related responses are
accepted. Other forwarded private traffic is dropped, including IPv6.
No inbound port forwarding is added. INPUT and OUTPUT rules are preserved.

The existing SSH access and host management exposure are unchanged. This step
does not yet restrict public management services. Reboot persistence of the new
forwarding rules and Internet connectivity from a guest still require validation.
The script runs at boot after the firewall services; if another service reloads
firewall rules later, rerun `systemctl restart xcpng-private-net.service`.

After applying twice, verify zero changes on the second run. Reboot one host
and inspect before running setup again:

```sh
sysctl net.ipv4.ip_forward
iptables -S XCPNG-PRIVATE-FWD
iptables -S FORWARD
iptables -t nat -S POSTROUTING
ip6tables -S FORWARD
```

Expect forwarding to be `1`, scoped jumps to the project chain and a single
marked NAT rule. A guest test follows when deploying the router.

Disabling the startup service alone does not remove live firewall rules. To undo
this routing step, first disable the service, then remove the two FORWARD jumps,
the marked NAT rule and the two marked IPv6 rules shown above by repeating their
specifications with `-D` instead of `-A`. After removing the jumps, delete only
the project chain with `iptables -F XCPNG-PRIVATE-FWD` and
`iptables -X XCPNG-PRIVATE-FWD`. Restore IPv4 forwarding to its previous value
(`0` on a fresh host) only if no other service needs it. Never flush built-in
chains or save the entire live firewall as the project's configuration.
