# DVWA deployment tools

For the normal human workflow, use the repository-level one-command entrypoint:

```bash
./infra/deploy.sh
# or, with Go Task:
task deploy
```

That entrypoint authenticates/selects the subscription, handles provider
registration and SSH-key discovery/generation, discovers approved Azure network
inputs, generates `terraform.tfvars`, and orchestrates the lower-level tools
described below. Run `./infra/deploy.sh --help` for environment-driven CI/CD and
plan-only options.

These scripts implement the deployment runbook as small, reviewable stages.
Run them from any directory; each script resolves the parent `infra` directory
itself. The command examples below assume the current directory is `infra`.
Mutating operations validate that Azure CLI is authenticated to the
subscription whose display name is exactly `BYTEDEFENSE_INFRA_NON_PROD`.

## Required environment

```bash
az login
az account set --subscription "<BYTEDEFENSE_INFRA_NON_PROD subscription ID>"
export ARM_SUBSCRIPTION_ID="$(az account show --query id --output tsv)"

# Either export the public key value:
export TF_VAR_admin_ssh_public_key="$(< ~/.ssh/dvwa_azure.pub)"

# Or tell every tool where to read it:
export DVWA_SSH_PUBLIC_KEY_FILE="$HOME/.ssh/dvwa_azure.pub"
```

For service-principal authentication, AzureRM also recognizes
`ARM_TENANT_ID`, `ARM_CLIENT_ID`, and `ARM_CLIENT_SECRET`. The scripts require a
matching Azure CLI login because they independently verify the target before
mutating it. No tool writes authentication secrets or private key material.

## First deployment

Run the numbered stages in order:

```bash
./tools/00-check-prerequisites.sh
./tools/01-register-providers.sh
./tools/02-prepare-configuration.sh
```

Edit `terraform.tfvars`, then continue:

```bash
./tools/03-validate.sh
./tools/04-plan.sh
./tools/05-apply.sh
```

`04-plan.sh` writes `dvwa.tfplan` and a subscription-binding sidecar. Both are
ignored by Git and assigned local-only permissions. The sidecar records the
subscription ID and plan SHA-256 digest. `05-apply.sh` refuses a plan whose
binding does not match the validated subscription or whose content changed
after review.

The configuration defaults to no HTTP or SSH access. Before planning, add only
privately routed sources to `application_allowed_source_cidrs` and
`ssh_allowed_source_cidrs`. Add a consumer VNet ID to both
`approved_remote_vnet_ids` and `additional_private_dns_vnet_links` when that VNet
should route to and resolve DVWA.

## Consumer-side peering

Terraform manages the peering owned by the DVWA VNet. To create the reciprocal
consumer-owned half with the Azure CLI:

```bash
export DVWA_CONSUMER_RESOURCE_GROUP="<consumer resource group>"
export DVWA_CONSUMER_VNET_NAME="<consumer VNet name>"
# Optional when the consumer is in a different subscription:
export DVWA_CONSUMER_SUBSCRIPTION_ID="<consumer subscription ID>"

./tools/06-create-reciprocal-peering.sh
```

The consumer-side operation is intentionally separate because that resource is
owned outside `rg-test-server-dvwa` and may belong to another team or stack. It
is the necessary exception to the resource-group ownership rule: Azure requires
a distinct peering resource on each VNet, while this Terraform root owns only
the DVWA side.

## Verify and initialize

```bash
./tools/07-verify.sh
```

The one-command deployment initializes a fresh database automatically. Invoke
the initialization tool manually only when deployment reported that database
initialization was skipped or failed, or when you intentionally want to erase
and reset the lab. From an approved client with private routing and private DNS
resolution:

```bash
./tools/07-verify.sh --test-http --skip-run-command
./tools/08-initialize-dvwa.sh
```

The initialization tool submits DVWA's **Create / Reset Database** action. It
drops existing DVWA tables and therefore requires the exact confirmation phrase
`RESET DVWA DATABASE` unless `--yes` is supplied. After initialization, the lab
login is `admin` / `password`.

## VM lifecycle

Routine power controls retain the VM and all disks:

```bash
./tools/10-deactivate-vm.sh
./tools/09-activate-vm.sh
```

For a longer inactive period, remove billable compute/NAT while retaining the
database disk and foundational private resources:

```bash
./tools/11-remove-compute.sh
./tools/12-restore-compute.sh
./tools/07-verify.sh
```

The remove/restore tools persist the desired value in the Git-ignored,
non-secret `lifecycle.auto.tfvars`. This prevents an unrelated later
`terraform plan` from silently reversing the selected lifecycle state.

All mutating scripts prompt by default. `--yes` is intended for reviewed CI/CD
automation and should not be used as a substitute for examining Terraform plans.

## Script index

| Script | Purpose | Azure changes |
| --- | --- | --- |
| `00-check-prerequisites.sh` | Check commands, login, subscription, SSH input | None |
| `01-register-providers.sh` | Register and wait for required providers | Provider registration |
| `02-prepare-configuration.sh` | Create non-secret `terraform.tfvars` | None |
| `03-validate.sh` | Initialize, format-check, validate, and test | None |
| `04-plan.sh` | Create and display a subscription-bound plan | None |
| `05-apply.sh` | Apply the reviewed saved plan | Workload resources |
| `06-create-reciprocal-peering.sh` | Create consumer-owned peering half | Consumer VNet peering |
| `07-verify.sh` | Verify NIC, power, extensions, data-disk mount, healthy database, proxy, and HTTP | Run Command only |
| `08-initialize-dvwa.sh` | Create/reset the DVWA application database | DVWA database reset |
| `09-activate-vm.sh` | Start a retained VM | VM power state |
| `10-deactivate-vm.sh` | Deallocate a retained VM | VM power state |
| `11-remove-compute.sh` | Apply `vm_deployed=false` | Removes disposable compute/NAT |
| `12-restore-compute.sh` | Apply `vm_deployed=true` | Recreates compute/NAT |
| `13-open-bastion-tunnel.sh` | Run the localhost-to-DVWA Bastion tunnel | Local foreground tunnel only |

The offline `tests/deploy-config-test.sh` uses a stub Azure CLI and the local
Terraform parser to exercise non-interactive configuration generation,
permissions, CIDR rendering, lifecycle state, and secret non-persistence
without contacting Azure.
