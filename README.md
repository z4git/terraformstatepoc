# README.md

Terraform remote state infrastructure for Azure, deployed from GitHub Actions, with the monitoring, alerting and backup around it — and an Azure Policy layer that locks the hosting subscription down to exactly those resources.

## Overview

This repository creates and operates the Azure Storage Account that holds Terraform remote state. It deliberately uses two tools:

- **Bicep** creates the resource group, the storage account, its blob containers, the role assignments and the `CanNotDelete` lock. The backend therefore exists before — and independently of — any Terraform run, so `terraform destroy` can never remove its own backend.
- **Terraform** adopts those resources through `import` blocks guarded by `prevent_destroy`, and adds everything that is not needed to bootstrap state: diagnostic settings, a Log Analytics workspace, an action group, two state-access alerts and a backup vault.

On top of that, an Enterprise Policy as Code (EPAC) layer denies every resource type the infrastructure does not use and enforces a hardening baseline on the types it does use.

Both layers are deployed only from `main`. Pull requests produce a preview — Checkov, Bicep What-if, `terraform plan`, EPAC plan — and change nothing in Azure.

## Architecture

```
Pull request ──> tfstate-infrastructure-plan.yml ──> Checkov, What-if, terraform plan   (read-only)
Push to main ──> tfstate-infrastructure-deploy.yml ─> Bicep deploy, then terraform apply

                 Resource group  rg-<app>-tfstate-<env>-<num>
                 ├── Storage account  st<suffix>        (Bicep, imported by Terraform)
                 │   └── Container  tfstate             (Bicep, imported by Terraform)
                 ├── Log Analytics workspace  log<suffix>   (Terraform)  <── blob/queue/table/file logs
                 ├── Action group  ag<suffix>               (Terraform)  ──> notificationEmails
                 ├── Scheduled query alert  alert-tfstate-access-<suffix>  (Terraform, KQL every 5 min)
                 ├── Scheduled query alert  alert-tfstate-non-oauth-<suffix>  (Terraform, KQL every 5 min)
                 └── Backup vault  bvault<suffix>           (Terraform)  ──> operational blob backup
```

Who owns what:

| Resource | Created by | Managed afterwards by |
|---|---|---|
| Resource group, storage account, blob containers | Bicep | Bicep + Terraform (imported, `prevent_destroy`) |
| Storage firewall IP rules | Bicep | Bicep; pipelines add/remove the runner IP temporarily. Terraform ignores them. |
| Role assignments, `CanNotDelete` lock | Bicep | Bicep only |
| Diagnostic settings, Log Analytics, action group, alert, backup vault | Terraform | Terraform |

Both tools write the same storage settings, and Terraform's values are kept identical to Bicep's so the first plan after import shows no changes. See section 3, "What each tool owns", in `docs/tfstate-infrastructure.md` for the full table.

## Repository layout

```
.devcontainer/              Dev container for Claude Code: Terraform, az, PowerShell + Az, egress firewall
.github/
  actions/
    checkov-scan/           Installs pinned Checkov and scans infrastructure/
    storage-firewall-runner-ip/  Adds/removes the runner's public IP on the storage firewall
    epac-setup/             Installs pinned EPAC and Az PowerShell modules
    epac-definitions/       Renders tenant/subscription placeholders in policies/ and validates
  workflows/               Plan and deploy workflows for infrastructure/ and policies/, plus act smoke tests
docs/                      Long-form documentation (see Documentation below)
infrastructure/
  bicep/                   Subscription-scope main.bicep + storage module
  parameterfiles/          tfstate-infrastructure.json — the inputs for both workflows
  rbac/                    Custom role definition the plan identity needs for Bicep What-if
  scripts/                 create-service-principals.sh — bootstraps the two CI identities
  terraform/               Root module, imports.tf, variables, outputs, KQL template
    modules/               storage, log-analytics, action-group, scheduled-query-alert, backup-vault
policies/                  EPAC definitions, policy set, assignments and exemptions
```

## Prerequisites

| Where | What |
|---|---|
| Azure | A subscription for the state infrastructure. Bootstrapping needs Owner (or User Access Administrator + Contributor) and Entra ID Application Developer, ideally PIM-activated. |
| GitHub | Admin on the repository, to set the Actions variables. |
| Tools | `az`, `jq`, and `gh` for the optional variable-setting step. Terraform `>= 1.7` with the `azurerm` `~> 4.0` provider if you run it by hand. |

## Getting started

The order matters: the storage role assignments come from the deploy itself, so the CI identities hold only their subscription-scope roles until the deploy workflow has run once.

**1. Create the two CI identities.** A plan identity (read-only) and an apply identity, each with GitHub OIDC federated credentials — no secrets:

```bash
az login
az account set --subscription <subscription-id>

infrastructure/scripts/create-service-principals.sh --repo org/repo --dry-run   # preview
infrastructure/scripts/create-service-principals.sh --repo org/repo
```

Add `--set-github-variables` to write the repository variables too (needs `gh auth login`). The script is safe to re-run; each step checks first and creates only what is missing. Full detail, including doing it by hand: `docs/service-principal-setup.md`.

**2. Set the repository variables** under *Settings → Secrets and variables → Actions → Variables*. None of them are secrets; the script prints the values.

**3. Fill in the parameter file**, `infrastructure/parameterfiles/tfstate-infrastructure.json`.

**4. Merge a change under `infrastructure/` to `main`.** One deploy run does everything: Bicep creates the resource group, storage account, containers, the storage role assignments for both principals and the lock; Terraform then imports them and creates the monitoring, alert and backup resources.

**5. Open a pull request touching `infrastructure/`** to confirm the plan identity works end to end.

Between steps 1 and 4 neither workflow can reach the state container — there is no blob role yet, and on a first deployment no storage account either. That is expected.

## Configuration

### Parameter file

`infrastructure/parameterfiles/tfstate-infrastructure.json` is read by both infrastructure workflows:

```json
{
  "location": "westeurope",
  "applicationName": "alz",
  "environmentName": "dev",
  "environmentNumber": 1,
  "networkDefaultAction": "Allow",
  "notificationEmails": ["platform-team@example.com"]
}
```

Every key except `networkDefaultAction` is required; a missing key fails the run before any Azure call. `applicationName` is 1–5 characters, `environmentName` 1–3, `environmentNumber` a single digit 1–9.

All resource names derive from these four inputs plus a deterministic 13-character hash of them, so re-running a workflow never creates a second account. See section 4, "Naming", in `docs/tfstate-infrastructure.md`.

### Repository variables

| Variable | Required | Effect |
|---|---|---|
| `AZURE_PLAN_CLIENT_ID` | Yes | App registration the plan workflow signs in as (falls back to `AZURE_CLIENT_ID`) |
| `AZURE_APPLY_CLIENT_ID` | Yes | App registration the deploy workflow signs in as (falls back to `AZURE_CLIENT_ID`) |
| `AZURE_TENANT_ID` | Yes | Tenant for OIDC login |
| `AZURE_SUBSCRIPTION_ID` | Yes | Target subscription |
| `TERRAFORM_APPLY_PRINCIPAL_ID` | No | Object ID of the apply identity; gets data/RBAC roles and is excluded from the state-access alert |
| `TERRAFORM_PLAN_PRINCIPAL_ID` | No | Object ID of the plan identity; gets read roles and is excluded from the alert |
| `TERRAFORM_LOCAL_PRINCIPAL_ID` | No | Object ID of a user for local `act` runs; **not** excluded from the alert |
| `TERRAFORM_STATE_ALLOWED_IPS` | No | Comma-separated IPs/CIDRs always allowed through the storage firewall |
| `TERRAFORM_STATE_LOCAL_ALLOWED_IPS` | No | Extra IPs added only under `act` |

The full table, including the `AZURE_CLIENT_ID` fallback, is in section 5, "Configuration", of `docs/tfstate-infrastructure.md`.

## Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `tfstate-infrastructure-plan.yml` | `pull_request` touching `infrastructure/**` | Checkov, Bicep What-if, `terraform plan`. Changes nothing in Azure except a temporary firewall rule. |
| `tfstate-infrastructure-deploy.yml` | `push` to `main` touching `infrastructure/**` | Checkov, What-if, plan, then Bicep deploy and `terraform apply`. |
| `policies-plan.yml` | `pull_request` touching `policies/**` or the `epac-*` actions | Validates the EPAC files and builds the policy plan. Read-only. |
| `policies-deploy.yml` | `push` to `main`, same paths | Builds a fresh plan and deploys definitions, sets and assignments. |
| `act-hello-world-test.yml` | manual | Smoke test that `act` and GitHub Actions can run workflows here. |
| `large-runner-hello-world.yml` | manual | Reports which large runner picked up the job and its public egress IP, so that IP can be added to `TERRAFORM_STATE_ALLOWED_IPS`. |

Plan and deploy use separate concurrency groups, so a queued pull-request plan can never silently drop a queued deploy. Note that changes outside `infrastructure/` — including to the infrastructure workflows themselves — do not trigger the infrastructure workflows; the policy workflows do trigger on their own files.

## Azure Policy layer

`policies/` makes this repository the single source of Azure Policy for the subscription, deployed with EPAC in **desired-state** mode (`strategy: full`): what is in the folder exists in Azure, what is not is removed.

- **One allow-list policy** denies every resource type that `infrastructure/` does not deploy — nothing else can be created in the subscription, not even by an Azure service on its own initiative.
- **Eighteen hardening policies**, one control each, deny any configuration that differs from the settings the infrastructure already uses: HTTPS and TLS 1.2, no shared keys, no public blob access, versioning and soft delete, Log Analytics as the only diagnostic target, email-only action groups, an allowed-roles list, required tags and allowed locations.

They are bundled into the `tfstate-infrastructure-hardening` policy set and assigned at subscription scope alongside the allow-list assignment. Adding a resource type to `infrastructure/` means adding it to the allow-list policy in the same pull request, or the deploy will be denied.

Details: `policies/README.md` for the folder-level guide, `docs/policies.md` for the long version.

## Running things locally

**Terraform by hand:**

```bash
cd infrastructure/terraform
cp backend.tfbackend.example backend.tfbackend     # fill in the real account name
cp terraform.tfvars.example terraform.tfvars       # subscription_id, unique_identifier, emails...
az login
terraform init -backend-config=backend.tfbackend
terraform plan
```

You need Storage Blob Data Reader (or Contributor) on the container, and your public IP must be allowed through the storage firewall. **Your access raises the state-access alert** unless your object ID is the plan or apply principal — that is intended. Keep `backend.tfbackend` and `terraform.tfvars` out of commits; `.gitignore` already excludes `*.tfstate*` and `.terraform/`.

**Workflows with `act`.** The workflows detect `act` through the `ACT` environment variable and reuse the host's `az login` instead of OIDC, so the Azure profile has to be mounted in:

```bash
az login   # on the host

# Preview (pull_request event)
act pull_request -W .github/workflows/tfstate-infrastructure-plan.yml \
  --container-options "-v $HOME/.azure:/tmp/azure-host:ro"

# Deploys for real (push event)
act push -W .github/workflows/tfstate-infrastructure-deploy.yml \
  --container-options "-v $HOME/.azure:/tmp/azure-host:ro"
```

**Checkov** and the **EPAC plan** can also be run locally — see "Running Checkov locally" in `docs/tfstate-infrastructure.md` and section 13, "Running locally", in `docs/policies.md`. Render EPAC placeholders into a scratch copy, never into `policies/` itself.

## Development environment

`.devcontainer/` provides a container for working on this repository with Claude Code: Node 22, `terraform`, the Azure CLI, PowerShell with the Az module, `git`, `gh`, `jq`, `ripgrep` and `zsh`. An iptables firewall allows internet egress but blocks private address ranges, so the agent cannot reach the Docker host or LAN. Bicep is not preinstalled — `az bicep install` fetches it on first use. See `.devcontainer/README.md`.

## Conventions

- **Storage settings live in two places.** When you change one, change it in both `infrastructure/bicep/modules/storage.bicep` and `infrastructure/terraform/modules/storage/main.tf`, or the two tools will fight over the account.
- **Imported resources carry `prevent_destroy`.** The resource group, storage account and containers cannot be destroyed by Terraform; a plain `terraform destroy` fails at plan time. The Bicep-owned `CanNotDelete` lock is the backstop outside Terraform.
- **Never repoint Terraform state.** The state key and Azure deployment name deliberately exclude workflow file names, so renaming a workflow cannot point Terraform at a new, empty state file.
- **Pin third-party actions by commit SHA.** Dependabot updates them weekly as a group via `.github/dependabot.yml`.
- **Checkov suppressions are documented inline.** Each `checkov:skip` carries the reason it is accepted; see "Suppressions in use" in `docs/tfstate-infrastructure.md`.

## Documentation

| Document | Contents |
|---|---|
| `docs/tfstate-infrastructure.md` | How the implementation works: workflows step by step, naming, configuration, RBAC, Checkov, monitoring, backup, and a table of known behaviours and limitations. |
| `docs/terraform-best-practices.md` | The design rationale: non-negotiable storage settings, the four ways to solve the state bootstrap problem, backup, access control, auditing, alerting, tagging and anti-patterns. |
| `docs/service-principal-setup.md` | Creating the plan and apply identities, their GitHub OIDC federated credentials, subscription roles, verification and troubleshooting. |
| `docs/policies.md` | The Azure Policy layer in full: EPAC mechanics, every policy, the assignments, the pipelines and the identities. |
| `policies/README.md` | Folder-level guide to `policies/`. |
| `.devcontainer/README.md` | The development container and its egress firewall. |
