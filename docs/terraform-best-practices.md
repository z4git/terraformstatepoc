# Terraform State Storage on Azure Storage Account — Best Practices

Scope: how to design, bootstrap, protect, monitor and operate the Azure Storage Account that holds Terraform remote state (`azurerm` backend), in the context of an Azure Landing Zone (ALZ) deployment.

State files are the single most sensitive artifact in an IaC estate: they contain resource IDs, connection strings, generated passwords and keys in plaintext. Treat the state storage account as a **Tier-0 / control-plane asset**, not as ordinary application storage.

---

## 1. Target architecture

| Decision | Recommendation | Why |
|---|---|---|
| Subscription placement | Dedicated **management/platform** subscription, not the workload subscription | The thing that manages a subscription must survive that subscription being wiped |
| One account or many | One storage account per **environment tier** (`prod` vs `nonprod`) or per **security boundary**; separate containers per landing zone/stack | Blast radius + separate RBAC without exploding cost |
| Container layout | `tfstate-platform`, `tfstate-connectivity`, `tfstate-identity`, `tfstate-lz-<name>` | RBAC is assignable at container scope |
| Key layout | `<stack>/<env>.tfstate` | Predictable, greppable, works with partial backend config |
| Redundancy | **GZRS** (prod) / ZRS (nonprod) | Region-pair durability for a tiny blob |
| SKU / kind | `StorageV2`, `Standard`, Hot tier | Blob leases required; premium block blob not needed |
| Locking | Native blob lease (built into `azurerm` backend) | No DynamoDB-equivalent needed; **never** set `skip_lock`/`use_lockfile=false` semantics |

### Non-negotiable resource settings

```hcl
resource "azurerm_storage_account" "tfstate" {
  name                            = "sttfstateprodweu001"
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = "westeurope"
  account_tier                    = "Standard"
  account_replication_type        = "GZRS"
  account_kind                    = "StorageV2"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false   # force Entra ID (AAD) auth — no account keys
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false   # private endpoint only
  default_to_oauth_authentication = true

  infrastructure_encryption_enabled = true  # creation-time only — see below

  blob_properties {
    versioning_enabled       = true
    change_feed_enabled      = true
    last_access_time_enabled = true

    delete_retention_policy           { days = 90 }
    container_delete_retention_policy { days = 90 }
    restore_policy                    { days = 30 }  # point-in-time restore
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]   # keep minimal; prefer explicit PE + agent subnet
  }

  identity { type = "SystemAssigned" }

  tags = local.tags
}
```

Key points:

- **`shared_access_key_enabled = false`.** Account keys are the number one exfiltration path for state. With keys disabled, all access is Entra ID and therefore fully auditable and conditional-access-able. Configure the backend with `use_azuread_auth = true`.
- **Disable public network access** and expose the account via a **private endpoint** (`blob` sub-resource) reachable from the CI/CD agent subnet (self-hosted runners / private ADO pools / GitHub Actions with an ARC runner). If you must use hosted runners, restrict `network_rules.ip_rules` to the documented egress ranges and accept the weaker posture explicitly.
  - This repository hits exactly that limit: GitHub-hosted runners publish ~7000 egress ranges and the source address is not stable within a job, while Azure Storage allows at most 200 IP rules. The implementation therefore runs with `default_action = "Allow"` and treats Entra ID + RBAC, disabled shared keys, and the state-access alert as the controls. See [tfstate-infrastructure.md](tfstate-infrastructure.md#state-storage-network-access).
- **`infrastructure_encryption_enabled = true`.** A second, independent AES-256 encryption pass beneath the platform's own, so a single flaw in one layer does not expose the blob. It costs nothing and is a CIS/Checkov control, but it is **settable only at creation**: the ARM API rejects it on an existing account, and the `azurerm` provider marks it `ForceNew`, so turning it on later plans a destroy/create that `prevent_destroy` correctly refuses. Decide it before the first deploy; afterwards the only route is a deliberate rebuild with state migration. In Bicep it is `properties.encryption.requireInfrastructureEncryption`.
- **Versioning + soft delete + PITR** are what make a `terraform destroy` accident recoverable.
- Apply a `CanNotDelete` **management lock** on the resource group, and consider **immutability policies** (time-based, version-level) if a regulator demands WORM. Note: immutable containers block state writes if applied at container scope — apply at *version* level only.

### Backend configuration

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-prod-weu-001"
    storage_account_name = "sttfstateprodweu001"
    container_name       = "tfstate-platform"
    key                  = "platform/prod.tfstate"
    use_azuread_auth     = true
    use_oidc             = true            # workload identity federation from CI
    subscription_id      = "..."
    tenant_id            = "..."
  }
}
```

Keep only invariants in code; pass the rest with `-backend-config=env/prod.azurerm.tfbackend` so the same module set targets multiple environments.

---

## 2. Pre-deployment: solving the chicken-and-egg problem

You need a storage account to store the state of the storage account. Four viable strategies — pick one and document it:

### Option A — Bootstrap-then-migrate (recommended)

1. Run the bootstrap config with a **local backend** from a controlled workstation or an ephemeral privileged pipeline.
2. It creates: resource group, storage account, containers, private endpoint/DNS, diagnostic settings, RBAC, locks.
3. Add the `backend "azurerm"` block and run `terraform init -migrate-state`.
4. **Delete the local `terraform.tfstate`** and confirm it never entered git (`.gitignore` must contain `*.tfstate*`, `.terraform/`, `*.tfvars` with secrets, `crash.log`).
5. Commit the bootstrap config; from then on the bootstrap stack manages itself remotely.

Pros: single language, self-managing afterwards. Cons: one manual run; the migration window is where mistakes happen.

### Option B — Out-of-band bootstrap, unmanaged by Terraform

Create the account with a signed, reviewed **Bicep/ARM template or `az` script** stored in the repo, and never import it into Terraform. The backend becomes an immutable platform primitive.

Pros: no circularity at all, no risk of `terraform destroy` eating the backend. Cons: two toolchains; drift on the account itself must be caught by Azure Policy instead of `terraform plan`.

### Option C — Bootstrap stack with its own separate backend

A tiny `bootstrap/` stack whose state lives in a *different, manually created* account (or in Terraform Cloud/HCP). Circularity is broken by putting the two accounts in different lifecycles.

### Option D — Azure Verified Modules / ALZ accelerator bootstrap

The ALZ Terraform accelerator (`Deploy-Accelerator` / `alz-terraform-accelerator`) ships a bootstrap phase that provisions the state account, the CI/CD identity, federated credentials and the pipeline definitions in one go. For an ALZ PoC this is usually the fastest correct path — use it, then review the generated resources against this document.

### Guardrails for whichever option you choose

- Add `prevent_destroy` to the backend resources:

  ```hcl
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags["LastReviewed"]]
  }
  ```
- The bootstrap run should be done by a **PIM-activated** account, and the standing role assignment afterwards should be the CI/CD workload identity only.
- Record in the repo README: who bootstrapped, when, with which identity, and the exact recovery procedure.
- Never store the bootstrap state file, account keys or SAS tokens in the repo, in Key Vault "for convenience", or in pipeline variables.

---

## 3. Backup and recovery

Layered, because each layer covers a different failure mode:

| Failure | Control |
|---|---|
| Bad `apply` corrupts state | **Blob versioning** — restore previous version |
| Someone deletes the blob | **Soft delete for blobs**, 90 days |
| Someone deletes the container | **Container soft delete**, 90 days |
| Logical corruption discovered late | **Point-in-time restore**, 30 days (requires versioning + change feed) |
| Account/region loss | **GZRS** + `azurerm_storage_object_replication` to a secondary account in another region |
| Subscription/tenant loss | **Azure Backup vaulted backup for blobs** (operational + vaulted tier), or a scheduled export to an isolated subscription |
| Ransomware / malicious insider | Vaulted backup in a **separate subscription with separate RBAC**, plus immutability |

Operational rules:

- Terraform itself writes `<key>.tfstate` and, on `state push`, keeps no history — versioning is your history. Don't rely on `terraform state pull > backup.json` habits alone, but *do* run `terraform state pull` before any `state mv` / `state rm` / provider major upgrade and archive the output to a secure location.
- **Test the restore quarterly.** A restore drill: delete a test state blob, restore it, run `terraform plan`, confirm zero diff. An untested backup is a hypothesis.
- Document RPO/RTO. Realistic target for state: RPO = last successful apply, RTO < 1 hour.
- Keep `terraform.tfstate.backup` semantics in mind for local runs, but CI runs should be stateless containers — nothing to recover from the agent.

---

## 4. Access control

**Principle: no humans have standing write access to state.**

| Identity | Role | Scope | Standing? |
|---|---|---|---|
| CI/CD apply workload identity | `Storage Blob Data Contributor` | Container | Yes (federated, no secret) |
| CI/CD plan workload identity | `Storage Blob Data Reader` | Container | Yes |
| Platform engineers | `Storage Blob Data Contributor` | Container | **No — PIM, time-bound, approval + justification** |
| Auditors | `Reader` (control plane only) | Account | Yes |
| Everyone else | none | — | — |

- Use **Workload Identity Federation / OIDC** from GitHub Actions or Azure DevOps — no client secrets, no service principal passwords to rotate.
- Separate **plan** and **apply** identities. The PR pipeline should not be able to write state.
- The account key path is closed by `shared_access_key_enabled = false`; also set the Azure Policy *"Storage accounts should prevent shared key access"* to `Deny` at the platform management group so it can't be re-enabled.
- Add **Conditional Access** on the human PIM path: compliant device + phishing-resistant MFA.
- `azurerm_role_assignment` for the state account should live in the bootstrap stack and be reviewed in **Entra ID Access Reviews** every 90 days.
- Deny `Microsoft.Storage/storageAccounts/listKeys/action` via a custom role or policy for all non-break-glass principals.

---

## 5. Audit and logging

Enable diagnostics on the **blob service** (not just the account) and ship to a Log Analytics workspace in the platform subscription, with an immutable archive to a separate storage account.

```hcl
resource "azurerm_monitor_diagnostic_setting" "tfstate_blob" {
  name                       = "diag-tfstate-blob"
  target_resource_id         = "${azurerm_storage_account.tfstate.id}/blobServices/default"
  log_analytics_workspace_id = var.law_id

  enabled_log { category = "StorageRead" }
  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }

  metric { category = "Transaction" }
}
```

Also:

- Send **Azure Activity Log** (control plane) for the resource group to the same workspace — this is where `listKeys`, role assignment changes and lock removal show up.
- Retention: 90 days hot in LAW, ≥ 1 year (or per regulator, often 365–730 days) in archive.
- Enable **Microsoft Defender for Storage** (malware scanning off, sensitive data discovery optional; the value here is the *Suspicious access* alerts).
- Keep the **change feed** on — it gives you an ordered, immutable record of every state mutation, useful for forensics beyond log retention.

### Useful KQL

Access from an identity outside the approved set:

```kusto
let ApprovedPrincipals = dynamic([
    "<uuid-cicd-apply>", "<uuid-cicd-plan>", "<uuid-breakglass>"
]);
StorageBlobLogs
| where TimeGenerated > ago(1h)
| where AccountName == "sttfstateprodweu001"
| where OperationName in ("PutBlob","DeleteBlob","GetBlob","LeaseBlob","PutBlockList")
| extend PrincipalId = tostring(parse_json(AuthenticationHash).OAuthIdentity)
| extend Caller = coalesce(tostring(RequesterObjectId), PrincipalId)
| where Caller !in (ApprovedPrincipals)
| project TimeGenerated, Caller, OperationName, Uri, CallerIpAddress,
          StatusCode, AuthenticationType, UserAgentHeader
```

Shared-key usage (should be zero):

```kusto
StorageBlobLogs
| where AccountName == "sttfstateprodweu001"
| where AuthenticationType != "OAuth"
| summarize Calls = count() by AuthenticationType, CallerIpAddress, bin(TimeGenerated, 15m)
```

State written outside a pipeline window / from an unexpected IP:

```kusto
StorageBlobLogs
| where AccountName == "sttfstateprodweu001" and OperationName in ("PutBlob","PutBlockList","DeleteBlob")
| where CallerIpAddress !startswith "10.50.1."      // CI agent subnet
| project TimeGenerated, Caller = RequesterObjectId, OperationName, Uri, CallerIpAddress
```

---

## 6. Alerting

Wire each detection to an action group (Teams/email/PagerDuty + ITSM connector).

| # | Signal | Severity | Rationale |
|---|---|---|---|
| 1 | Any blob write/delete by a principal **not** in the approved list | Sev 1 | Unauthorized state mutation |
| 2 | Any request with `AuthenticationType != OAuth` (shared key/SAS) | Sev 1 | Key access re-enabled or key leaked |
| 3 | `Microsoft.Storage/storageAccounts/listKeys/action` in Activity Log | Sev 1 | Key exfiltration attempt |
| 4 | Deletion/modification of the management lock or a role assignment on the RG | Sev 1 | Guardrail tampering |
| 5 | `DeleteBlob` on any `*.tfstate` | Sev 1 | Should never happen; Terraform overwrites, never deletes |
| 6 | Public network access enabled / network rule default changed to Allow | Sev 1 | Perimeter breach |
| 7 | Access from outside the CI agent subnet / private endpoint | Sev 2 | Human bypassing the pipeline |
| 8 | Anonymous or failed-auth spike (`StatusCode 403/401`) | Sev 2 | Enumeration/brute force |
| 9 | Blob lease held > 30 min | Sev 3 | Hung pipeline holding the state lock |
| 10 | Defender for Storage alert on the account | Sev 1 | Managed detection |
| 11 | Diagnostic setting removed | Sev 1 | Log tampering |

Implement #1 as a scheduled log-search alert on the KQL above:

```hcl
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "unapproved_state_access" {
  name                = "alert-tfstate-unapproved-access"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
  scopes              = [var.law_id]
  severity            = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT10M"

  criteria {
    query                   = local.kql_unapproved_access
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluations_to_trigger_alert   = 1
    }
  }

  auto_mitigation_enabled = false
  action { action_groups = [var.action_group_id] }
}
```

Use **Activity Log alerts** (not log-search) for #3, #4, #6, #11 — lower latency and they survive a LAW outage.

Maintain the approved-principal list as a Terraform variable so adding an identity is a reviewed PR, and so the alert and the RBAC assignments cannot drift apart. Even better: derive both from the same local.

---

## 7. Tagging

Tags on the state account are operational metadata *and* a policy hook. Enforce with Azure Policy (`Require a tag on resources` / `Inherit a tag from the resource group`) so untagged resources are denied.

```hcl
locals {
  mandatory_tags = {
    Environment      = "prod"              # prod | nonprod | sandbox
    Criticality      = "tier0"             # state storage is always tier0
    DataClass        = "confidential"      # state contains secrets
    Owner            = "platform-team@example.com"
    CostCenter       = "CC-1042"
    Application      = "terraform-backend"
    ManagedBy        = "terraform"
    Workload         = "alz-platform"
    ProvisionedDate  = "2026-09-03"        # static; do not use timestamp()
    ReviewCycle      = "quarterly"
  }

  tags = merge(local.mandatory_tags, var.additional_tags)
}
```

Rules:

- Never use `timestamp()` in a tag — it produces a diff on every plan. If you want a deploy stamp, set it from a CI variable and `ignore_changes` it.
- Set tags at the resource group and rely on the *Inherit a tag* policy with `modify` effect for children, so a missed tag is auto-remediated instead of blocking.
- Include `ManagedBy = "terraform"` and `Repository` — when someone finds an orphan resource at 2am, these two tags are what let them find the code.
- Tag values feed cost management (`CostCenter`, `Application`) and the alert routing (`Owner`). Keep the allowed-value list in policy, not in prose.
- `DataClass = confidential` should drive automatic inclusion in the Defender/Purview scope.

---

## 8. CI/CD for managing and updating the configuration

### Pipeline shape

```
PR opened ──> fmt / validate / tflint / checkov|tfsec ──> terraform plan (read-only identity)
          └─> plan posted as PR comment + saved as artifact
Review + required approvals (CODEOWNERS = platform team)
Merge to main ──> manual approval gate (prod) ──> terraform apply <saved-plan>
                                              └─> drift detection nightly
```

Concretely:

1. **`terraform fmt -check -recursive`** and **`terraform validate`** — fail fast.
2. **`tflint`** with the `azurerm` ruleset; **`checkov`** or **`tfsec`/Trivy** for policy-as-code. Fail the build on HIGH/CRITICAL.
3. **`terraform plan -out=tfplan`** using the **plan identity** (Blob Data Reader — it can read state, which is enough for a plan; if lease acquisition is a problem use `-lock=false` for plan only, never for apply).
4. **Apply the saved plan file**, never re-plan at apply time. This is what makes review meaningful.
5. **Environment protection rules / approval gates** for prod. Separate Azure DevOps environments or GitHub Environments per landing zone.
6. **Concurrency group per state key** in the CI system (`concurrency: tfstate-platform-prod`) so two pipelines don't fight over the blob lease.
7. **OIDC federated credentials** scoped to `repo:<owner>/<repo>:environment:prod` — a workflow on a fork or a different branch cannot obtain the apply token.
8. **Pin everything**: `required_version = "~> 1.9"`, `azurerm = "~> 4.0"`, commit `.terraform.lock.hcl`, and run `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64` so the lock covers both CI and laptops.
9. **Dependabot/Renovate** on providers and modules; upgrades go through the same PR flow.
10. **Nightly drift detection**: `terraform plan -detailed-exitcode`; exit code 2 raises a ticket. Drift on the state account itself is a security signal, not just hygiene.

### Sample GitHub Actions skeleton

```yaml
permissions:
  id-token: write        # OIDC
  contents: read
  pull-requests: write

jobs:
  plan:
    environment: prod-plan
    concurrency: tfstate-platform-prod
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_PLAN_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - run: terraform init -backend-config=env/prod.azurerm.tfbackend
        env: { ARM_USE_AZUREAD: "true", ARM_USE_OIDC: "true" }
      - run: terraform plan -out=tfplan -lock-timeout=5m
      - uses: actions/upload-artifact@v4
        with: { name: tfplan, path: tfplan, retention-days: 5 }

  apply:
    needs: plan
    if: github.ref == 'refs/heads/main'
    environment: prod-apply      # requires reviewers
    concurrency: tfstate-platform-prod
    steps: [ download tfplan, azure/login (apply identity), terraform apply tfplan ]
```

### Rules that matter more than the YAML

- **The plan artifact is sensitive.** A plan file contains state values including secrets. Set short retention, restrict artifact access, and never post a raw plan to a public PR — redact or use the summary only.
- **No local applies against prod.** Enforce socially (policy) and technically (only the CI workload identity has standing Blob Data Contributor).
- **Always `-lock-timeout`** so a transient lease contention retries instead of failing the pipeline.
- **Break-glass procedure** for a stuck lease: `terraform force-unlock <ID>` requires an approved incident record; the lease-break shows up in alert #9 and the audit log.
- **Changes to the bootstrap/backend stack itself** should require two approvers and run in a separate, more restricted pipeline than landing-zone changes.
- **Keep secrets out of state where you can**: use Key Vault references, `ephemeral` resources / write-only arguments (Terraform ≥ 1.11) for passwords, and managed identities instead of generated credentials. The best protection for state is having less in it.

---

## 9. Anti-patterns

- Account keys or SAS tokens in pipeline variables, `terraform.tfvars`, or `~/.azure`.
- A single monolithic state for the whole ALZ — slow plans, huge blast radius, lock contention. Split by platform layer and landing zone.
- Public network access "just for the hosted agents".
- `terraform destroy` reachable from any pipeline that targets the bootstrap stack.
- Committing `.tfstate`, `.terraform/`, or plan files to git.
- Re-planning at apply time.
- Storing state for prod and sandbox in the same container with the same RBAC.
- Manual `az storage blob upload` fixes to state instead of `terraform state` subcommands with a pre-pulled backup.

---

## 10. Checklist

**Bootstrap**
- [ ] Bootstrap strategy chosen and documented (A/B/C/D)
- [ ] Local state deleted after `-migrate-state`; `.gitignore` verified
- [ ] `prevent_destroy` + `CanNotDelete` lock in place

**Hardening**
- [ ] `shared_access_key_enabled = false`, TLS 1.2+, HTTPS only
- [ ] `infrastructure_encryption_enabled = true` — **decided before the first deploy**, it cannot be added later
- [ ] Public network access disabled; private endpoint + private DNS zone
- [ ] Versioning, blob soft delete 90d, container soft delete 90d, PITR 30d, change feed on
- [ ] GZRS replication; cross-region object replication or vaulted backup

**Access**
- [ ] OIDC workload identities for plan and apply, separate roles, container scope
- [ ] Zero standing human write access; PIM + CA for break-glass
- [ ] Access review scheduled (90 days)

**Observability**
- [ ] Blob diagnostics + Activity Log → LAW, retention set, archive immutable
- [ ] Defender for Storage enabled
- [ ] Alerts 1–11 deployed with action groups; approved-principal list in code

**Operations**
- [ ] Tags enforced by policy; no `timestamp()` in tags
- [ ] CI: fmt/validate/tflint/checkov, saved-plan apply, approval gate, concurrency group
- [ ] Provider versions pinned, lock file committed for all platforms
- [ ] Nightly drift detection
- [ ] Restore drill performed and dated; force-unlock runbook written

---

## References

- Azure Verified Modules — `Azure/avm-res-storage-storageaccount/azurerm`
- ALZ Terraform Accelerator — `Azure/alz-terraform-accelerator`
- `azurerm` backend documentation (`use_azuread_auth`, `use_oidc`)
- Azure Storage security baseline (Microsoft cloud security benchmark)
- CAF: Manage Terraform state in Azure Storage
