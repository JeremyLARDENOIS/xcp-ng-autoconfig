# Administration VPN

`ansible/playbooks/vpn.yml` deploys administration VPN access after the
[initial infrastructure setup](setup.md). It configures the XCP-ng host, its existing router
VM and, by default, the Ubuntu workstation running Ansible. No intersite tunnel,
DNS service or public XAPI restriction is introduced by this increment.

## Requirements

- Complete `setup.yml` first: the private LAN and router must already work.
- Keep public SSH/bastion access available during deployment.
- The workstation uses Ubuntu and NetworkManager.
- Address validation on the controller requires `ansible.utils` and `netaddr`.

Install missing controller dependencies in the environment running Ansible:

```sh
ansible-galaxy collection install -r ansible/requirements.yml
sudo apt install python3-netaddr
```

On Ubuntu with sudo-rs, this playbook selects the already installed `sudo.ws`
when available to avoid an incompatible password prompt. It does not change
system alternatives. See the [upstream issue](https://github.com/trifectatechfoundation/sudo-rs/issues/1461).

## Inventory

Enable the VPN only on the first host being tested:

```yaml
admin_vpn:
  address: 10.91.1.1/24
  endpoint: 203.0.113.10
  client_address: 10.91.1.10/32
```

Replace the endpoint with the host's public IPv4 address. Use a distinct
administration subnet without overlapping existing workstation routes or the
site LAN. The client gets private LAN access; VPN access does not grant XOA
or SSH credentials. Multiple administrators are not implemented by this increment.

## Run

From the repository root:

```sh
ansible-playbook -i private/hosts.yml ansible/playbooks/vpn.yml --limit host01 --ask-become-pass
```

In order, the playbook prepares the device key, configures UDP 51821 forwarding
and a return route on Dom0, configures the router VPN and its firewall, exports
the gateway public key, then activates the NetworkManager profile locally.
It reuses the shared router firewall role; it does not redeploy the router or XOA.

To configure only the infrastructure and skip all workstation installation,
key generation and profile activation:

```sh
ansible-playbook -i private/hosts.yml ansible/playbooks/vpn.yml --limit host01 -e vpn_configure_workstation=false
```

In that mode, provide the device public key in `private/wireguard/admin.pub`
before execution. No device private key is needed on this controller.
The gateway public key is still exported for later client configuration.
`vpn_configure_workstation` defaults to `true`.

Check mode is available after the device public key has been prepared:

```sh
ansible-playbook -i private/hosts.yml ansible/playbooks/vpn.yml --limit host01 --check --ask-become-pass
```

It does not generate keys. On a first run without a device key, use the normal
command instead; key validation will otherwise fail before infrastructure changes.

## Keys and profile

The workstation key is stored as plaintext in `private/wireguard/admin.key`,
mode `0600`, in a `0700` directory ignored by Git. Existing nonempty keys are
preserved; absent or empty keys are generated with `wg genkey`, captured under
`no_log`, and saved atomically by Ansible. `admin.pub` is derived from that key.
Preserve this cache: replacing the private key changes the device identity.

Activation also stores the private key in a root-owned `0600` NetworkManager
keyfile under `/etc/NetworkManager/system-connections/xa-....nmconnection`.
Deleting the repository copy alone does not remove or revoke that profile.
NetworkManager autoconnects it; only the site LAN and administration subnet are
routed through the VPN. Internet default routes and workstation DNS are unchanged.

The router generates its own private key under `/etc/wireguard/admin.key` and
uses `/etc/wireguard/wg-admin.conf`. Its private key stays inside the VM.
Only its public key is exported to `private/wireguard/sites/INVENTORY_HOST.pub`.
The host forwards UDP 51821 to the router. Private client source addresses are
preserved; return paths use the router, with no private NAT.

## Verification

For the example site LAN, run on the workstation:

```sh
nmcli -f NAME,TYPE,DEVICE connection show --active
ip -4 route get 10.20.1.254
ssh root@10.20.1.254
```

The private route must use an `xa-...` interface. Open `https://10.20.1.2` for
XOA without an SSH tunnel and check ordinary Internet access still works.
On the router, inspect `sudo wg show wg-admin latest-handshakes` and
`sudo nft list table inet xcpng_router`. Do not dump private key configuration.
Repeat the same VPN playbook to verify zero changes.

Local syntax checks and mocked scenarios do not prove real connectivity.
Reboot recovery and restoration after the last VM or toolstack stops remain
unvalidated. This first test covers one site and one device only.

## Revocation and rollback

Set `admin_vpn.client_enabled: false`, then rerun `vpn.yml` through public SSH
with `-e vpn_configure_workstation=false`. This removes the active gateway peer
and its private forwarding/access exceptions. Removing the inventory mapping
alone skips roles and does not uninstall existing resources.

On the workstation, disable autoconnect for the corresponding profile with
`nmcli connection modify NAME connection.autoconnect no`, then
`nmcli connection down NAME`. Do not rerun local activation for a revoked device.
Full server uninstallation is not automated. Public SSH remains the recovery path.

## Sources

- [WireGuard quick start](https://www.wireguard.com/quickstart/)
- [wg-quick documentation](https://git.zx2c4.com/wireguard-tools/about/src/man/wg-quick.8)
