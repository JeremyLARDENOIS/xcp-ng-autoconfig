# XCP-ng automation

Automation for independent XCP-ng hosts. The initial goal is to create an
internal network, deploy a router VM, and deploy an XOA appliance.

Technologies:

- Ansible for host and guest configuration.
- Terraform for virtual resources.
- Bash for small utility scripts.
- Rust for substantial decision logic when needed.

The [setup playbook documentation](docs/setup.md) covers the implemented steps:
creating an internal network and importing a generic Debian template.
Clone boot validation is pending. Keep real configuration, secrets and working
notes outside version control.

## Getting started

The setup creates the `private-net` internal network and imports an unmodified
official Debian RAW image as a generic template. Host IP addressing, routing
and router deployment come later.

### Requirements

- XCP-ng 8.3 hosts accessible over SSH as `root`.
- Ansible, `curl`, OpenSSH and checksum utilities installed on the workstation.
- An SSH key available on that workstation; use an SSH agent for encrypted keys.

Run the following commands from the repository root.

### Prepare the inventory

```sh
mkdir -p private
cp ansible/inventory/hosts.example.yml private/hosts.yml
```

Replace the example `ansible_host` values with your addresses or SSH aliases.
The `private/` directory is ignored by Git. Set `template_sr_uuid` to the destination
Local storage SR UUID on each host. Verify SSH connectivity and host keys before
running Ansible.

### Run the setup

Start with one inventory host, such as `host01`:

```sh
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host01 --check
ansible-playbook -i private/hosts.yml ansible/playbooks/setup.yml --limit host01
```

Check mode queries the host without creating a network. The next command creates
`private-net` and the Debian template if missing, and prints their UUIDs. Run it again: no changes should
be reported. Repeat for other inventory hosts after verifying the first result.

See the [setup procedure](docs/setup.md) for verification and rollback.

## Project layout

- `ansible/playbooks/`: entry points; `setup.yml` runs the implemented setup steps.
- `ansible/roles/`: implementation of each step; `private_net`, `host_network` and `debian_template`.
- `ansible/inventory/`: generic inventory examples.
- `docs/`: user documentation.

Run Ansible from the repository root so it loads `ansible.cfg` and finds the roles.
