# XCP-ng automation

Automation for independent XCP-ng hosts. The initial goal is to create an
internal network, deploy a router VM, and deploy an XOA appliance.

Technologies:

- Ansible for host and guest configuration.
- Terraform for virtual resources.
- Bash for small utility scripts.
- Rust for substantial decision logic when needed.

The [setup playbook documentation](docs/setup.md) covers the implemented steps:
creating an internal network, importing a generic Debian template and configuring
a router VM. Keep real configuration, secrets and working
notes outside version control.

## Planned deployment change

The current VM preparation from the official Debian cloud image is a temporary
approach for validating the initial infrastructure. It should eventually be
replaced by deploying from a prebuilt, versioned XCP-ng template with the common
packages and guest tools already installed. That template may be built separately
with Packer. Cloud-init will still supply instance-specific settings, and Ansible
will configure services after deployment.

## Getting started

The setup creates the `private-net` internal network and imports an unmodified
official Debian RAW image as a generic template. It configures private host
addressing and outbound NAT, then deploys a router VM and verifies its bootstrap
access. It then configures IPv4 forwarding and guest NAT for the private /24 LAN,
and deploys official XOA on the host with `xoa_address` configured.

### Requirements

- XCP-ng 8.3 hosts accessible over SSH as `root`.
- Ansible, `curl`, OpenSSH, `genisoimage` and checksum utilities installed on the workstation.
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

Set `xoa_address` to an unused private address on the single host that will run
XOA; omit it elsewhere. See the setup documentation for private UI access and
initial account configuration.

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

The separate [VPN playbook](docs/vpn.md) connects one Ubuntu NetworkManager
workstation to the first site. It configures the VPN infrastructure and optionally
the workstation; `setup.yml` remains the minimal infrastructure setup entry point.
Reciprocal `site_vpn` settings optionally connect a pair of sites through their
existing router VMs, using the same administrator profile on the workstation.

## Project layout

- `ansible/playbooks/`: entry points; `setup.yml` runs the implemented setup steps.
- `ansible/roles/`: implementation of each setup step.
- `ansible/inventory/`: generic inventory examples.
- `docs/`: user documentation.

Run Ansible from the repository root so it loads `ansible.cfg` and finds the roles.
