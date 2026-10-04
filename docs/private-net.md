# Create an internal network

This playbook creates an internal XAPI network named `private-net` on each
selected host, with an explicit bridge name of `private-net`. It uses `xe` without attaching a physical interface or changing
the management network. See the [XCP-ng networking documentation](https://docs.xcp-ng.org/networking/)
and the [xe command reference](https://docs.xcp-ng.org/appendix/cli_reference/).

An internal network provides Layer 2 connectivity. This step assigns no subnet,
IP address, gateway, or NAT rule. Guest addressing comes in later steps.

Remote commands use Ansible's `raw` module over SSH, so no compatible Python
interpreter is required on the host. Read-only queries explicitly run in check
mode; creation is explicitly disabled in check mode.

## Prepare the workstation

Install Ansible and copy the inventory example:

```sh
mkdir -p private
cp ansible/inventory/hosts.example.yml private/hosts.yml
```

Replace `ansible_host` with your host addresses or SSH aliases. Verify SSH access
using those values, and verify the SSH host keys. Use an SSH agent for encrypted
keys; keep secrets out of the inventory.

## Run the playbook

Start with one inventory host:

```sh
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host01 --check
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host01
```

Check mode queries the host but creates no network. Record the printed UUID and
run the apply command again: no changes should be reported.

Repeat for another inventory host after verifying the first result:

```sh
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host02
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host02
```

The playbook reuses an existing network if its name is unique, its bridge is
`private-net`, and it has no PIF. Ambiguous names and physical interfaces cause the playbook to stop.
If its bridge has another name, the playbook deletes and recreates the network
only if it has no PIF and no VIF, including interfaces of stopped VMs. Its UUID
changes. Check mode runs the required checks without deleting or creating anything.
If recreation fails after deletion, rerun the playbook to create the missing network.
Do not run concurrent executions against the same pool.

## Verify on each host

```sh
xe network-list name-label=private-net params=uuid,name-label,bridge
```

Connectivity can be tested once a VM is attached. The absence of an active bridge
without an attached VM does not by itself indicate failure. Persistence after
reboot has not yet been validated by this project.

## Rollback

Only remove a network created for this deployment, and only when no VM uses it.
Check its VIFs before deleting the network by UUID. Replace `NETWORK_UUID` with
the recorded value:

```sh
xe vif-list network-uuid=NETWORK_UUID
xe network-destroy uuid=NETWORK_UUID
```

Do not delete a pre-existing network reused by the playbook.
