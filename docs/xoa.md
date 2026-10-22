# Register pools in XOA

`ansible/playbooks/xoa.yml` configures the existing appliance through its REST
API. It registers missing pools from the `xcpng` inventory group and connects
new or disconnected registrations. It does not deploy XOA, create users or
tokens, change existing credentials, or deploy applications.

## Requirements

- Complete [setup](setup.md), then [VPN configuration](vpn.md) when connecting
  separate sites. XOA must reach each host's private HTTPS endpoint.
- The workstation must reach XOA over HTTPS with a trusted certificate matching
  the URL by default. Use a DNS name or IP covered by that certificate. An optional
  `xoa_api_ca_path` supplies a PEM CA bundle on the workstation.
- XOA must expose REST `GET /servers`, `POST /servers`, and
  `POST /servers/{id}/actions/connect`. The playbook checks the installed
  `/rest/v0/docs/swagger.json` before changing anything; it does not upgrade XOA.
- Supply an XOA administrator account and, for each missing registration, the
  host account password used by XAPI. SSH key authentication is separate.
- Use one inventory entry per single-host pool, with `bootstrap_host_address`
  set to its private address. Registration uses `ansible_user`, defaulting to
  `root`, as the XAPI username.

### Certificates

There are two independent TLS connections: workstation to XOA, and XOA to each
XCP-ng host. A workstation CA bundle does not configure XOA's trust store.
New registrations use `xoa_pool_validate_certs: true` by default. Set it to
`false` in the `xcpng` group variables, or override it on a specific host, to
accept that host's self-signed certificate (`allowUnauthorized: true`). HTTPS
remains in use, but XOA does not verify that host's certificate identity.

For example, two independent settings can be placed in your private group variables:

```yaml
xoa_api_validate_certs: false   # Workstation -> XOA
xoa_pool_validate_certs: false  # XOA -> XCP-ng hosts
```

The playbook checks existing registrations against the requested policy. REST
cannot update that setting on an existing registration. If it differs, change
it once in XOA Settings > Servers, then rerun. The playbook preserves existing
registrations rather than deleting and recreating them.

For self-signed host certificates, verify their identity through your trusted
administration access before establishing trust. Configure XOA's trust using
its documented `NODE_EXTRA_CA_CERTS` mechanism, or install certificates trusted
by XOA. Certificate identities must match the private addresses used here.
Do not blindly trust a certificate fetched from an unverified endpoint.
This playbook does not install certificates or change XOA's service environment.

For a private appliance with a self-signed certificate, you can explicitly set
`xoa_api_validate_certs: false` in the inventory group variables. HTTPS remains
in use, but the workstation no longer verifies XOA's certificate identity.
Use this only over your trusted private administration connection. The default
is `true`. This setting affects only workstation-to-XOA requests; it does not
change XOA-to-host certificate checks; those use `xoa_pool_validate_certs`.

See [XOA certificate configuration](https://docs.xen-orchestra.com/getting-started/configuration)
and [XCP-ng TLS certificates](https://docs.xcp-ng.org/guides/TLS-certificates-xcpng/).

## Prepare credentials

Keep network settings in the existing `private/hosts.yml`. Put XOA settings and
secrets alongside that inventory:

```text
private/
  hosts.yml
  group_vars/xcpng/
    vars.yml                 # XOA URL and optional workstation CA bundle
    vault.yml                # encrypted XOA account credentials
  host_vars/
    host01/vault.yml         # encrypted XAPI password
    host02/vault.yml         # encrypted XAPI password
```

Ansible loads these variables automatically with `-i private/hosts.yml`.
Use your actual inventory names for the host directories. Keep real values and
encrypted files outside Git. The shipped `*.example.yml` files are templates,
not encrypted vaults.

### Prepare and encrypt empty templates

For a new inventory, from the repository root (do not overwrite existing files):

```sh
mkdir -p private/group_vars/xcpng private/host_vars/host01 private/host_vars/host02
cp ansible/inventory/group-vault.example.yml private/group_vars/xcpng/vault.yml
cp ansible/inventory/host-vault.example.yml private/host_vars/host01/vault.yml
cp ansible/inventory/host-vault.example.yml private/host_vars/host02/vault.yml
chmod 600 private/group_vars/xcpng/vault.yml private/host_vars/host01/vault.yml private/host_vars/host02/vault.yml
ansible-vault encrypt private/group_vars/xcpng/vault.yml private/host_vars/host01/vault.yml private/host_vars/host02/vault.yml
```

Choose one Vault password for these files, store it in your password manager,
and keep it separate from the encrypted files. This is neither your SSH key
passphrase nor your sudo password. No password file or editor integration is
required. A file named `vault.yml` is encrypted only after `ansible-vault encrypt`
succeeds; its first line then starts with `$ANSIBLE_VAULT;`.

### Fill the encrypted files

```sh
ansible-vault edit private/group_vars/xcpng/vault.yml
ansible-vault edit private/host_vars/host01/vault.yml
ansible-vault edit private/host_vars/host02/vault.yml
```

Set `xoa_api_username` and `xoa_api_password` in the group vault. Set
`xoa_pool_password` in each host vault when its pool is not yet registered.
Existing registrations do not require that password again.

Keep `xoa_api_url` in `xcpng.vars` in the inventory or in
`private/group_vars/xcpng/vars.yml`, with no trailing slash. Optionally set
`xoa_api_ca_path` there. Remove any duplicate plaintext credentials from the
inventory once migrated. Vault encrypts files on disk; it does not encrypt
other copies, editor backups or secrets stored by XOA.

Use `ansible-vault edit` for later changes and `ansible-vault rekey` to change
the encryption password. Keep a protected backup of the encrypted files and
your means of recovering the Vault password. Do not print decrypted files in
shared logs or disable sensitive-task logging protections.

API requests suppress sensitive output. The playbook creates no persistent
credential cache on the workstation. XOA stores the host credentials needed
for its pool connections.

The token for a future application repository is created or retrieved manually
and supplied directly to that repository. This playbook does not generate it.

## Run

```sh
ansible-playbook -i private/hosts.yml ansible/playbooks/xoa.yml --check --ask-vault-pass
ansible-playbook -i private/hosts.yml ansible/playbooks/xoa.yml --ask-vault-pass
```

Because these vaults belong to the shared inventory, other playbooks such as
`setup.yml` and `vpn.yml` may also require `--ask-vault-pass` when loading it,
even if they do not use the XOA credentials. Keep any `--ask-become-pass` needed
by VPN workstation tasks: it is a separate prompt.

This runs once locally using the `xcpng` group variables and considers every
host in `xcpng`; do not use a host
`--limit`. It does not SSH to the hosts or need local sudo.
Check mode authenticates, checks API support and reads registrations, then shows
what would be registered or connected. It does not test new XAPI credentials
or the future XOA-to-host TLS connection and performs no writes.

Existing registrations are identified using the private endpoint, inventory
name, `ansible_host`, optional `site_vpn.endpoint`, or an inventory-name label.
Multiple matches, or a match using another endpoint, cause a failure before
any registrations are changed. Review such entries in XOA and switch them to
the intended private endpoint manually. The playbook never deletes or silently
repoints existing entries. Unknown aliases cannot reliably be associated with
a pool: review existing connections before the first run.

## Verify and retry

- Both pools should be connected in XOA, with their SRs and networks visible.
- Run the apply command again: expect no changes for connected registrations.
- A successful connection does not validate VM imports, transfer URLs, MTU,
  reboot recovery, or application networking. Test those separately as needed.

If a request fails, its details are hidden to protect credentials. Check the
installed API schema, account permissions, XOA connection error in its UI,
private connectivity and both TLS trust paths. Do not disable `no_log` to debug
with real passwords.

Connection failures report the HTTP status and only recognized TLS, network or
authentication error codes. Raw responses remain hidden. If no code is
recognized, inspect the connection in XOA's Settings > Servers. An HTTP 500
alone does not establish whether the cause is TLS, credentials or connectivity.

A registration can remain after a failed connection. Fix the underlying cause
and retry: its ID is reused. Registrations are not removed automatically on
failure or when a host disappears from the inventory. For rollback, review and
remove only the newly added connection in XOA; this does not delete its VMs.
Existing credentials are not rotated by reruns; update them explicitly in XOA.

## API references

- [REST API principles and authentication](https://docs.xen-orchestra.com/automation/restapi)
- [Server endpoints](https://github.com/vatesfr/xen-orchestra/blob/master/@xen-orchestra/rest-api/src/servers/server.controller.mts)
- The installed appliance's `/rest/v0/docs/swagger.json` is the compatibility
  check used by this playbook; newer upstream documentation is not proof of
  support in an older installed version.

## Vault references

- [Encrypting inventory variables](https://docs.ansible.com/projects/ansible/latest/vault_guide/vault_encrypting_content.html)
- [Using encrypted files](https://docs.ansible.com/projects/ansible/latest/vault_guide/vault_using_encrypted_content.html)
