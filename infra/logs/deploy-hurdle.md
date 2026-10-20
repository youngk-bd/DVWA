# DVWA deployment hurdle log

Deployment date: 2026-07-18

Target subscription: `BYTEDEFENSE_INFRA_NON_PROD` (`e7a4e20a-0fb3-42fe-95ca-4e5a5edcb527`)

Target resource group: `rg-test-server-dvwa`

This log records issues encountered during the first real deployment, their
cause, resolution, and verification evidence. It intentionally contains no
credentials, private keys, or generated application secrets.

## Preflight

- Azure CLI was already authenticated as `young@bytedefense.com` to the exact
  target subscription.
- Required resource providers were registered.
- Azure credentials were not exported as `ARM_*`; the deployment script is
  expected to derive and export `ARM_SUBSCRIPTION_ID` from the authenticated
  Azure CLI session.
- No SSH key environment variable was set. The deployment script can safely
  select the existing local `~/.ssh/id_ed25519.pub` public key.
- `infra/terraform.tfvars` existed locally with AppSec and Ept workload subnet
  access. The temporary Bastion source CIDR `10.70.2.0/26` was appended before
  planning because Azure Bastion connects to the VM from its dedicated subnet.

## Hurdles and resolutions

### H1 — Persistent disk plan exposed public import/export access

- **Observed:** The first reviewed Terraform plan showed
  `network_access_policy = "AllowAll"` and
  `public_network_access_enabled = true` for `disk-dvwa-data`.
- **Risk:** The disk was not anonymously readable, but Azure disk import/export
  could be exposed through a granted access URI. That was broader than the
  intended private-only posture.
- **Resolution:** Rejected the saved plan before apply. Set
  `network_access_policy = "DenyAll"` and
  `public_network_access_enabled = false`, added a regression assertion, and
  regenerated the plan.
- **Workload impact:** None; the first plan was never applied.

### H2 — `Standard_B2s` unavailable because of live regional capacity

- **Observed:** Azure returned `409 SkuNotAvailable` while creating
  `vm-test-server-dvwa` in `eastus2`.
- **Cause:** `Standard_B2s` was listed for the region and quota was available,
  but Azure reported a live capacity restriction at allocation time.
- **Resolution:** Queried the Compute SKU REST API for subscription-level
  restrictions and retained security capabilities. Selected
  `Standard_D2s_v7` (2 vCPU, 8 GiB, Premium I/O, Generation 2, Trusted Launch
  capable) with no current subscription restriction and healthy Dsv7 quota.
- **Recovery:** Terraform state retained all resources that Azure had already
  created. The next saved plan will create only the missing resources.

### H3 — `AzurePlatformDNS` service tag rejected on allow rules

- **Observed:** Azure returned `400 SecurityRuleInvalidAccessType` for both TCP
  and UDP rules using `destination_address_prefix = "AzurePlatformDNS"`, stating
  that the only allowed access type for this special tag was `Deny`.
- **Cause:** `AzurePlatformDNS` is a platform-control tag intended to opt into
  blocking Azure's virtual DNS endpoint, not a normal allow-list service tag.
- **Resolution:** Removed the invalid explicit allow rules. The deployment does
  not add an `AzurePlatformDNS` deny rule, so Azure-provided DNS remains
  available while the workload's ordinary outbound traffic remains governed by
  the explicit NSG allow list and final deny rule.

### H4 — Entra SSH extension rejected automatic platform upgrades

- **Observed:** Azure returned `409 OperationNotAllowed` for
  `AADSSHLoginForLinux`, stating that the extension does not support
  `enableAutomaticUpgrade = true`.
- **Resolution:** Removed `automatic_upgrade_enabled` from that extension while
  retaining `auto_upgrade_minor_version = true`, which is supported by the
  publisher. The Azure Monitor extension keeps its own supported automatic
  upgrade setting.
- **Recovery:** The VM, data-disk attachment, monitoring extension, and DCR
  association were already recorded in Terraform state. The retry will add only
  the missing Entra SSH extension.

### H5 — BSD awk rejected the VNet resource-ID parser

- **Observed:** After Terraform completed, reciprocal peering reconciliation
  failed locally with `awk: syntax error` at `index = 1`.
- **Cause:** The deployment helper used `index` as a loop variable. BSD awk on
  macOS reserves `index` as a built-in function name, while other awk variants
  accept it.
- **Resolution:** Renamed the variable to `field_index` and reran the deployment
  idempotently. Terraform had already completed, so no workload rollback was
  needed.

### H6 — Azure Run Command used POSIX `sh`, not Bash

- **Observed:** Guest and container verification succeeded, but the automatic
  database initialization stopped with `set: Illegal option -o pipefail`.
- **Cause:** Azure Run Command writes the supplied payload to a script executed
  by `/bin/sh`. The initialization payload requested Bash-only `pipefail`, even
  though the rest of the payload was POSIX-compatible.
- **Resolution:** Changed the remote payload from `set -euo pipefail` to
  portable `set -eu`, then reran only the idempotent initialization stage.
- **Workload impact:** None. DVWA and MariaDB remained healthy; the database
  setup request had not executed before the shell rejected the option.

### H7 — Docker did not publish a port from the internal-only network

- **Observed:** Both containers were running and MariaDB was healthy, but
  `curl http://127.0.0.1` and `curl http://10.70.1.10` were refused. Docker
  recorded the requested `80:80` binding, while its host NAT chain contained no
  forwarding rule for port 80.
- **Cause:** The Compose backend was intentionally marked `internal: true` to
  deny container egress. On the installed Docker Engine, that isolation also
  suppressed the host port-publishing rule. Direct host access to the web
  container's internal address still returned HTTP 200.
- **Resolution:** Kept both vulnerable containers on a fixed, internal-only
  `172.30.0.0/24` bridge and removed Docker port publishing. Added a hardened,
  socket-activated `systemd-socket-proxyd` listener on the VM's port 80 that
  forwards only to DVWA at `172.30.0.10:80`. Extended guest verification to
  require both the proxy socket and the DVWA login-page marker.
- **Recovery:** Applied the immutable cloud-init correction by replacing only
  disposable VM compute; the persistent managed data disk remained attached
  and retained its generated credentials and MariaDB data.

### H8 — Bastion extension required explicit non-interactive confirmation

- **Observed:** The documented `az network bastion delete` command cancelled
  because the Bastion CLI extension could not prompt without a terminal.
- **Resolution:** Reissued the scoped deletion with `--yes` and added that flag
  to the teardown command in the runbook. The public IP and dedicated subnet
  were removed only after the Bastion host deletion completed.

### H9 — Existing data disk was misclassified as a fresh deployment

- **Observed:** A final interactive `task deploy` found a no-change Terraform
  state but offered `Initialize the new DVWA database` with a default-yes
  prompt. The action was declined, so existing data was not reset.
- **Cause:** Freshness detection piped `terraform state list` into `grep -q`
  while Bash `pipefail` was enabled. After finding the disk, `grep -q` could
  close the pipe early; Terraform's resulting nonzero/SIGPIPE status made the
  entire pipeline appear false.
- **Resolution:** Replaced quiet early-exit matching with full-stream
  `grep -Fx ... >/dev/null`, documented the `pipefail` constraint inline, and
  added an offline regression guard. The repeated interactive deployment now
  labels the operation `Reset the existing DVWA database` and defaults to no.

## Final verification

The original `task deploy` run and its idempotent retries exposed the hurdles
above. After applying the corrections, the final non-interactive equivalent was
run with database reset explicitly disabled:

```bash
DVWA_INITIALIZE_DATABASE=false task deploy:yes
```

It completed with exit status 0 and reported:

- Terraform configuration valid; mocked tests: 2 passed, 0 failed.
- Terraform plan: **No changes**.
- Terraform apply: 0 added, 0 changed, 0 destroyed.
- Both consumer-side `peer-dvwa` peerings: `Connected`.
- Cloud-init: `status: done`.
- `dvwa.service` and `dvwa-proxy.socket`: `active`.
- MariaDB container: running and healthy; DVWA container: running.
- In-guest HTTP verification marker: `DVWA_HTTP_OK`.
- Database setup marker: `DVWA_DATABASE_INITIALIZED`.

The exact interactive `task deploy` entrypoint was then repeated after the H9
fix. It reused the existing tfvars, produced another no-change plan/apply,
reverified both peerings and guest HTTP, offered only the safe default-no
`Reset the existing DVWA database` action, and exited 0 after that reset was
declined.

Live Azure checks after deployment and temporary-access cleanup confirmed:

- VM `vm-test-server-dvwa` is running on `Standard_D2s_v7` with Trusted Launch,
  Secure Boot, and vTPM enabled.
- NIC `nic-dvwa-vm` has fixed private IP `10.70.1.10`, IP forwarding disabled,
  and no public-IP association.
- The TCP/80 NSG allow rule contains only AppSec `10.80.2.0/23` and Ept
  `10.90.2.0/23`; the SSH allowlist remains empty.
- DVWA-owned `peer-appsec` and `peer-ept` plus both consumer-owned reciprocal
  peerings are `Connected`.
- AppSec, Ept, and DVWA private-DNS VNet links are `Completed` / `Succeeded`.
- The persistent data disk is attached with `networkAccessPolicy=DenyAll` and
  public network access disabled.
- The remaining public IP, `pip-dvwa-egress`, is associated only with the NAT
  Gateway and has no NIC IP configuration; it cannot be an inbound VM endpoint.

For the requested workstation-path test, a temporary Standard Bastion host was
created with tunneling enabled. The local `127.0.0.1:8080` tunnel to private VM
port 80 returned HTTP 200 and the expected `Damn Vulnerable Web Application`
page marker. The tunnel was then stopped, and `bastion-dvwa`,
`pip-dvwa-bastion`, `AzureBastionSubnet`, and only its temporary
`10.70.2.0/26` NSG source were removed. A final subnet listing contained only
`snet-dvwa-vm` (`10.70.1.0/24`), and no Bastion artifacts remained in the
resource group.
