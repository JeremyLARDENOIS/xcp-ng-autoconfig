# XCP-ng automation

Automation for independent XCP-ng hosts. The initial goal is to create an
internal network, deploy a router VM, and deploy an XOA appliance.

Technologies:

- Ansible for host and guest configuration.
- Terraform for virtual resources.
- Bash for small utility scripts.
- Rust for substantial decision logic when needed.

The first step is available: [create an internal network](docs/private-net.md)
with Ansible. Deployment validation is pending.
Keep real configuration, secrets, and working notes outside version control.

## Getting started

This step creates only the `private-net` internal network, with a bridge also
named `private-net`. IP addressing,
routing, and VM deployment come later.

### Requirements

- XCP-ng 8.3 hosts accessible over SSH as `root`.
- Ansible installed on the administration workstation.
- An SSH key available on that workstation; use an SSH agent for encrypted keys.

Run the following commands from the repository root.

### Prepare the inventory

```sh
mkdir -p private
cp ansible/inventory/hosts.example.yml private/hosts.yml
```

Replace the example `ansible_host` values with your addresses or SSH aliases.
The `private/` directory is ignored by Git. Verify SSH connectivity and host
keys before running Ansible.

### Check and create the network

Start with one inventory host, such as `host01`:

```sh
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host01 --check
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host01
```

Check mode queries the host without creating a network. The next command creates
`private-net` if missing and prints its UUID. Run it again: no changes should
be reported. Repeat for other inventory hosts after verifying the first result.

See the [detailed procedure](docs/private-net.md) for verification and rollback.

## Project layout

- `ansible/playbooks/`: entry points; `setup.yml` runs the implemented setup steps.
- `ansible/roles/`: implementation of each step; currently `private_net`.
- `ansible/inventory/`: generic inventory examples.
- `docs/`: user documentation.

Run Ansible from the repository root so it loads `ansible.cfg` and finds the roles.
To select only the network step, add `--tags private_net` to the setup command.
