# Set up an XCP-ng host

`ansible/playbooks/setup.yml` is the single entry point for the initial setup.
It creates the `private-net` internal network and imports an
unmodified official Debian RAW image as a generic template. Host addressing,
routing, router deployment and XOA deployment are included in the initial setup.
Administration VPN deployment belongs to [vpn.yml](vpn.md), not this playbook.
The setup also activates the private bridge and assigns the host private address.

## Requirements

- XCP-ng 8.3 hosts accessible over SSH as `root`.
- A mounted ext SR on each host.
- Ansible, Bash, `curl`, OpenSSH, `genisoimage`, `sha512sum` and `sha256sum` on the workstation.
- Workstation Internet access and space to cache the RAW image.
- SR space for both the staged image and imported disk, plus 1 GiB.

Remote tasks use Ansible's `raw` module, so the host does not need a compatible
Python interpreter. The image is neither converted nor customized.

## Prepare the inventory

Run all commands from the repository root so Ansible loads `ansible.cfg`.

If the inventory has encrypted variables, also pass `--ask-vault-pass` when
running this playbook. See [inventory secrets with Vault](xoa.md#prepare-credentials).

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

## Execution order and concurrency

The host roles run sequentially: `private_net`, `host_network`, `debian_template`,
then `router_vm`. A second play runs `router_access` and `router_network` in the guests.
Hosts run in parallel within Ansible's fork limit. The linear strategy ensures
that downloading and verifying the shared image runs once for all selected hosts.
The template role owns preparation, transfer and import; each host imports its
own template after successful preparation. Check mode does not download an image.
Do not run multiple setup processes against the same pool or shared image cache.

## Deploy the router VM

Install `genisoimage` on the workstation (for example, `sudo apt install genisoimage` on Debian or Ubuntu). It creates a small CIDATA ISO containing
NoCloud user data, metadata and network configuration. The ISO is imported as a
read-only seed disk on the existing ext SR; no ISO SR or image customization is
required. See [cloud-init NoCloud documentation](https://cloudinit.readthedocs.io/en/26.1/reference/datasources/nocloud.html).

Set `router_address` to `.1` in the host's subnet, `router_ssh_public_key_file`
to your public key file and `router_dns_servers` to external DNS resolver
addresses. The private key stays on your workstation. The router uses the same
SR as the Debian template. Existing experimental VMs are preserved; the new
project VM is named `router-v1`.

The setup installs a VM from the generic template with `xe vm-install`, grows its root disk to 8 GiB, creates one
private interface and attaches its seed before first boot. It inherits 1 vCPU,
1 GiB RAM and UEFI firmware from the template. Cloud-init creates the `debian`
SSH user with passwordless sudo, static `.1`, Dom0 `.254` as gateway, and external
DNS. Root SSH and password authentication are disabled. Ansible then installs
nftables and configures forwarding in the guest through the host bastion.

Local seed files are stored in `private/routers/INVENTORY_HOST/`. Keep this cache:
changing the seed after first boot is rejected rather than silently reconfiguring
a guest. Unowned VMs named `router-v1` are rejected. Interrupted creation before
an ownership marker may require manual review. The pool auto-power-on flag is
also enabled; other VMs already marked for auto-power-on may therefore start on
future host boots.

Start on one host with the usual check and apply commands. The second play in
the same setup checks guest SSH via the host as ProxyJump, waits for cloud-init,
and verifies DNS plus an HTTP request to `deb.debian.org`. Limiting the setup by
the original inventory host name also limits these guest checks. New guest SSH
host keys are accepted on first contact; changed host keys are rejected.

If bootstrap verification fails, the VM is retained for inspection through its
console. Do not rerun creation with a new name to hide a failed boot. After success,
repeat setup to verify idempotence. Guest routing, reboot connectivity and recovery
when the last VIF stops remain to be validated during integration.

If an earlier setup created a project-owned template named `router-v1` with
`vm-copy`, it is renamed to `router-v1-failed-copy` and retained with its disks.
The corrected setup creates a real VM from the original Debian template.
Nothing is deleted during this recovery. Review and remove the retained failed
copy separately after successful guest validation.

## Configure guest routing

The `router_network` role supports private /24 networks. Other VMs use `.1` as
their gateway and external DNS resolvers until DNS services are deployed.
The router keeps `.254` as its default gateway. Both traffic directions use
`eth0`; guest masquerading makes Dom0 see the router's `.1` source address,
matching its existing forwarding and NAT rules. Replies return through the
router. This is double NAT; private client addresses are hidden from Dom0.

The role manages only the `inet xcpng_router` nftables table and a dedicated
startup service. It permits outbound IPv4 forwarding and established return
traffic, drops other forwarded traffic, and leaves guest INPUT and OUTPUT
unchanged. It disables IPv6 forwarding and ICMP redirects, which would otherwise
allow clients to learn a direct route through `.254`. Same-subnet traffic travels
directly between VMs and does not pass through this router firewall.

Apply setup on one host, then rerun to check for zero changes. From the router:

```sh
sudo nft list table inet xcpng_router
sysctl net.ipv4.ip_forward net.ipv4.conf.eth0.send_redirects
systemctl status xcpng-router-firewall.service --no-pager
```

The existing router Internet check does not validate forwarding for another VM.
Use a separate test VM on `private-net` with an unused static address (for example
`10.20.1.10/24`), gateway `10.20.1.1`, and an external DNS resolver. Check an HTTP
request to `http://deb.debian.org/debian/` from that guest and confirm that the
router's forwarding and NAT counters increase. Repeat after a host reboot.
Guest forwarding and reboot persistence remain unvalidated until those tests pass.

To undo guest routing, set `net.ipv4.ip_forward=0` in the project's sysctl file
and apply it with `sudo sysctl -p /etc/sysctl.d/90-xcpng-router.conf`. Disable the
service with `sudo systemctl disable --now xcpng-router-firewall.service`, then
remove only its table with `sudo nft delete table inet xcpng_router`. Restore
redirect settings to their previous values if needed. The next setup reapplies
the project configuration.

## Deploy the official XOA appliance

Set `xoa_address` only on the host that will run XOA, using an unused private
/24 address such as `.2`. Omit it on other hosts. Setup runs the `xoa` role after
guest routing configuration. It uses the existing template SR, keeps the official
appliance resources and firmware, attaches its interface to `private-net`, and
sets static networking through the documented `xenstore-data` parameters before
boot. The gateway is the router `.1`, and DNS is the first external router resolver.
See the [official deployment documentation](https://docs.xen-orchestra.com/xoa/).

The official `https://xoa.io/xva` endpoint is mutable. The first downloaded image
is retained in `private/xoa/`, and a local SHA-256 verifies cache and transfer
integrity; it does not authenticate the image against a publisher signature.
Staging uses the ext SR mount, not Dom0 system storage. Keep sufficient space on
the workstation and SR for the downloaded XVA and imported disks. No appliance
update or replacement occurs automatically.

The VM is named `xoa-v1` and marked as project-owned. Setup rejects an existing
unowned VM with that name. If interrupted between import and ownership marking,
inspect the imported VM before retrying: this small window is not automatically
recovered. Changes to configured addressing require the appliance to be halted.
Imported staging files are retained for inspection. Auto power-on uses the pool
flag already enabled by the router deployment.

Setup checks private HTTPS availability from Dom0. That check accepts the
appliance self-signed certificate and verifies availability only, not TLS
identity or outbound routing. Open the UI using the displayed SSH tunnel:

```sh
ssh -N -L 8443:10.20.1.2:443 root@host01.example.com
```

Open `https://localhost:8443`. Verify the appliance certificate through a trusted
path before entering credentials. The initial web account is `admin@admin.net`
with password `admin`; create your own administrator and remove the default
account immediately. Do not expose the tunnel listener or XOA publicly.
Registration, updates, pool connections and account automation are deferred.

To validate routing, use XOA's Updates view to check access to its update service
and confirm that the router forwarding/NAT counters increase. A successful UI
page load alone proves only private reachability. For shell-level DNS/HTTP
checks, the appliance system account must first be enabled using the official
procedure; setup does not inject a password or enable SSH login. Record actual
results and check access again after a host reboot.

## Optional public HTTPS forwarding

Set `https_forward_address` on a host to publish a local application VM:

```yaml
host01:
  # Other inventory settings remain unchanged.
  https_forward_address: 10.20.1.10
```

The destination must be in that host's private /24, with an address from `.2`
to `.253`, excluding XOA. The router (`.1`) and Dom0 (`.254`) cannot be targets.
Omit the option or set it to an empty string to disable publication.

Run the usual setup command for the selected host:

```sh
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host01 --check --ask-vault-pass
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host01 --ask-vault-pass
```

Check mode validates the destination but does not apply or simulate live
iptables rules. Omit `--ask-vault-pass` if the inventory has no encrypted files.

Dom0 redirects incoming public IPv4 TCP 443 to the VM's TCP 443 and applies SNAT
to its own private address, keeping return traffic on Dom0. The VM sees Dom0 as
the client, not the original Internet address. This does not require a route
through the router VM. HTTPS is passed through unchanged: certificates, domains,
reverse proxies and the application itself belong to the destination's owner.

The public IPv4 TCP 443 endpoint now serves the target application instead of
Dom0's HTTPS service. Private host and XOA administration addresses remain
available. UDP 443, IPv6 publication, other ports, remote-site targets and
hairpin access from the LAN or VPN are not provided by this option. Existing
IPv6 policy is unchanged.

The startup helper persists the setting through `xcpng-private-net.service`.
It manages only `XCPNG-HTTPS-DNAT`, `XCPNG-HTTPS-SNAT`, `XCPNG-HTTPS-FWD` and their
jumps; it preserves other project and foreign rules. Empty owned chains and
inert jumps remain after disabling. The destination VM must already exist,
listen on TCP 443, and accept connections from Dom0's private address.

### Verify or disable

1. From an external network, connect to the public address using the domain
   and certificate served by the target. For example, with your actual values:

   ```sh
   curl --connect-timeout 5 --max-time 10 \
     --resolve app.example.com:443:203.0.113.10 https://app.example.com/
   ```

2. Check private administration access still works and rerun setup: expect no
   changes once the setting is applied.
3. Change the destination and rerun to replace the owned rules. New connections
   should reach the new VM.
4. Remove the setting or use `https_forward_address: ""` and rerun to empty the
   publication rules. This does not modify or stop the application VM.
5. Validate reboot recovery separately, without rerunning Ansible first.

Use fresh connections for these checks: existing NAT mappings can remain in
conntrack until they expire. This playbook does not flush connection tracking.
Do not enable publication to XOA as a substitute for private VPN access.
