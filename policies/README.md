# Azure Policy for the Terraform state subscription (EPAC)

This folder is an [Enterprise Policy as Code (EPAC)](https://azure.github.io/enterprise-azure-policy-as-code/)
definitions root. This README is the short guide; the full implementation description (EPAC mechanics, every
policy rule, workflow steps, identities, known behaviours) is [docs/policies.md](../docs/policies.md). It locks the subscription that holds the Terraform state infrastructure down to exactly
what `infrastructure/` deploys, and hardens those resource types with deny-by-default policies.

Two GitHub workflows run it, mirroring the `tfstate-infrastructure-*` pair:

| Workflow | Trigger | Identity | What it does |
|---|---|---|---|
| `.github/workflows/policies-plan.yml` | pull request touching `policies/` | plan (read-only) | validates the files, builds the EPAC deployment plan, posts a summary and uploads the plan |
| `.github/workflows/policies-deploy.yml` | push to `main` touching `policies/` | apply | builds a fresh plan and deploys it (policy resources, then role assignments if any) |

Nothing is deployed from a pull request. Nothing tenant- or subscription-specific is committed: the
`__AZURE_TENANT_ID__` and `__AZURE_SUBSCRIPTION_ID__` placeholders are rendered from the `AZURE_TENANT_ID` and
`AZURE_SUBSCRIPTION_ID` repository variables at run time.

---

## 1. Layout

| Path | Purpose |
|---|---|
| `global-settings.jsonc` | EPAC settings: `pacOwnerId`, the single `tfstate-subscription` environment, desired-state strategy. |
| `policyDefinitions/tfstate-allowed-resource-types.jsonc` | **The allow-list policy.** Denies every resource type not used by `infrastructure/`. |
| `policyDefinitions/tfstate-*.jsonc` | One hardening policy per control for the allowed resource types (section 3). |
| `policySetDefinitions/tfstate-infrastructure-hardening.jsonc` | Policy set (initiative) bundling all hardening policies, one effect parameter each. |
| `policyAssignments/tfstate-allowed-resource-types.jsonc` | Assigns the allow-list policy to the subscription. |
| `policyAssignments/tfstate-hardening.jsonc` | Assigns the hardening set to the subscription and fixes every effect (all `Deny`, one documented `Audit`). |
| `policyExemptions/tfstate-subscription/` | Exemptions for the environment; empty today, see its README. |
| `.github/actions/epac-setup/` | Installs pinned EPAC and Az PowerShell modules (and PowerShell under act). |
| `.github/actions/epac-definitions/` | Renders the placeholders and validates the files before EPAC runs. |

EPAC only reads `global-settings.jsonc` and `*.json`, `*.jsonc`, `*.csv` files inside the four `policy*`
folders; README files are ignored.

---

## 2. The allow-list policy

`tfstate-allowed-resource-types` runs in mode `All`, so it evaluates child resources, extension resources,
resource groups and deployments, not only the top-level resources that the built-in "Allowed resource types"
(mode `Indexed`) sees. Its default `allowedResourceTypes` is derived from `infrastructure/`:

| Resource type | Created by |
|---|---|
| `Microsoft.Resources/deployments`, `Microsoft.Resources/subscriptions/resourceGroups` | `bicep/main.bicep` (subscription deployment, nested module deployment, resource group) |
| `Microsoft.Storage/storageAccounts`, `.../blobServices`, `.../blobServices/containers`, `.../queueServices`, `.../tableServices`, `.../fileServices` | `bicep/modules/storage.bicep`, `terraform/modules/storage` (the last three carry the per-service diagnostic settings) |
| `Microsoft.Authorization/roleAssignments`, `Microsoft.Authorization/locks` | `bicep/modules/storage.bicep`, `terraform/modules/backup-vault` |
| `Microsoft.OperationalInsights/workspaces`, `.../workspaces/tables`, `.../workspaces/savedSearches` | `terraform/modules/log-analytics`; the tables and saved searches are filled in by Azure |
| `Microsoft.Insights/actionGroups`, `Microsoft.Insights/scheduledQueryRules`, `Microsoft.Insights/diagnosticSettings` | `terraform/modules/action-group`, `scheduled-query-alert`, `storage`, `backup-vault` |
| `Microsoft.DataProtection/backupVaults`, `.../backupPolicies`, `.../backupInstances` | `terraform/modules/backup-vault` |
| `Microsoft.Authorization/policyDefinitions`, `policySetDefinitions`, `policyAssignments`, `policyExemptions` | this folder, through EPAC |
| `Microsoft.Authorization/policyDefinitions/versions`, `policySetDefinitions/versions` | Azure, whenever EPAC updates a definition or a set |
| `Microsoft.Authorization/roleDefinitions` | `scripts/create-service-principals.sh` (the custom What-If role) |
| `Microsoft.Advisor/recommendations`, `Microsoft.Advisor/configurations`, `Microsoft.Authorization/roleManagementPolicies`, `Microsoft.Consumption/budgets`, `Microsoft.Security/pricings`, `Microsoft.Security/settings`, `Microsoft.Security/policies` | Azure or an administrator, not this repository; allowed because denying them buys nothing and only creates noise |

Everything else is denied on create and update. That includes types Azure services write on their own
initiative when they are enabled, for example Defender for Cloud auto-provisioning
(data collection rules, and `Microsoft.Security/*` beyond the three settings types above). That is the intended posture for a subscription whose only
job is to hold Terraform state; if such a service is wanted, add its types through a pull request. The
subscription resource itself is excluded from evaluation so it is not reported as non-compliant.

**Adding a resource type to `infrastructure/`** means adding it here in the same pull request, otherwise the
Bicep deploy or Terraform apply is denied. Read the Azure error: it names the assignment
`tfstate-allowed-types` and the denied type.

---

## 3. Hardening policies

All policies are custom, live at the subscription, and default to `Deny`. Where a Microsoft built-in exists
for the control, the policy rule is the built-in's rule (referenced in each file) with the effect fixed to
`Deny`; the rest use the same aliases the built-ins use. Every value is the one `infrastructure/` deploys,
so the existing Bicep deploy and Terraform apply pass as they are.

| Policy | Resource type | Enforces | Source of truth in `infrastructure/` |
|---|---|---|---|
| `tfstate-storage-secure-transfer` | storage account | `supportsHttpsTrafficOnly` true, `minimumTlsVersion` TLS1_2 or TLS1_3 | `storage.bicep`, `modules/storage/main.tf` |
| `tfstate-storage-no-shared-key` | storage account | `allowSharedKeyAccess` explicitly false | same |
| `tfstate-storage-no-public-blob-access` | storage account | `allowBlobPublicAccess` explicitly false (covers containers too: they have no policy alias) | same |
| `tfstate-storage-no-cross-tenant-replication` | storage account | `allowCrossTenantReplication` explicitly false | same |
| `tfstate-storage-entra-id-defaults` | storage account | `defaultToOAuthAuthentication` true, `allowedCopyScope` AAD | same |
| `tfstate-storage-network-default-deny` | storage account | `networkAcls.defaultAction` Deny (**Audit** today, see below) | `networkDefaultAction` in the parameter file |
| `tfstate-storage-kind-and-sku` | storage account | `kind` StorageV2, SKU in `Standard_GZRS`, `Standard_RAGZRS` | `skuName` / `replication_type` |
| `tfstate-storage-blob-data-protection` | blob service | versioning, change feed, blob and container soft delete >= 90 days, point-in-time restore | `softDeleteRetentionDays`, `restorePolicyDays` |
| `tfstate-log-analytics-retention` | Log Analytics workspace | `retentionInDays` >= 30 | `log_analytics_retention_in_days` |
| `tfstate-action-group-email-only` | action group | email receivers only, common alert schema | `modules/action-group` |
| `tfstate-alert-rule-enabled` | log search alert rule | `enabled` true (the state access alert cannot be switched off) | `modules/scheduled-query-alert` |
| `tfstate-diagnostic-setting-log-analytics-only` | diagnostic setting | Log Analytics destination, no storage account or event hub | `modules/storage`, `modules/backup-vault` |
| `tfstate-backup-vault-soft-delete` | backup vault | soft delete not Off | `modules/backup-vault` |
| `tfstate-role-assignment-allowed-roles` | role assignment | role in the allow-list of role definition GUIDs | `storage.bicep`, `modules/backup-vault`, `create-service-principals.sh` |
| `tfstate-required-tags-resources` (Indexed), `tfstate-required-tags-resource-groups` | taggable resources, resource groups | the tag named by `tagName` present; referenced once per tag (`application`, `environment`, `environmentNumber`, `workload`, `managedBy`) | `locals.tags` in `main.bicep` and `main.tf` |
| `tfstate-allowed-locations-resources` (Indexed), `tfstate-allowed-locations-resource-groups` | located resources, resource groups | location `westeurope` (`global` accepted) | `location` in the parameter file |

Deny policies act on create and update requests only. Resources that already exist and violate a policy
show up as non-compliant in the compliance view; nothing is changed or deleted by policy.

### The one `Audit` effect

`storageNetworkDefaultDenyEffect` is `Audit` in `policyAssignments/tfstate-hardening.jsonc` because
`infrastructure/parameterfiles/tfstate-infrastructure.json` sets `networkDefaultAction` to `Allow` (GitHub-hosted
runners have no stable egress IP, see [tfstate-infrastructure.md](../docs/tfstate-infrastructure.md), "State
storage network access"). With `Deny` the next `tfstate-infrastructure-deploy` run would be rejected. Flip both
values in the same pull request.

### Role assignment allow-list and the custom What-If role

`tfstate-role-assignment-allowed-roles` allows the five roles Bicep and Terraform assign on the storage
account plus Reader, Owner, Contributor and User Access Administrator, which
`infrastructure/scripts/create-service-principals.sh` grants at the subscription. The script also assigns the
custom role `Terraform Plan What-If Operator`, whose GUID only exists once the role definition has been
created in the tenant. Add that GUID to `allowedRoleDefinitionIds` in `policyAssignments/tfstate-hardening.jsonc`
before running the script (or set the effect to `Audit` for the run):

```bash
az role definition list --name "Terraform Plan What-If Operator" --query "[0].name" -o tsv
```

---

## 4. How a change flows

1. Edit files under `policies/` on a branch and open a pull request.
2. `policies-plan.yml` installs EPAC, signs in as the plan identity, renders and validates the files, and runs
   `Build-DeploymentPlans`. The job summary lists every definition, set, assignment and exemption that would be
   created, updated, replaced or deleted; the plan JSON is attached as an artifact. Review deletions with care:
   with `desiredState.strategy = "full"` EPAC removes policy resources that exist in Azure but not in this
   folder (portal-created ones without a `pacOwnerId`). Resources owned by another EPAC repository and the
   Defender for Cloud assignments are left alone.
3. Merge. `policies-deploy.yml` builds a fresh plan as the apply identity and runs `Deploy-PolicyPlan`, then
   `Deploy-RolesPlan` when the plan contains role assignments (only for DeployIfNotExists or Modify policies;
   there are none).

Both workflows also trigger on changes to themselves and to the two composite actions.

---

## 5. Identities and repository variables

The workflows reuse the identities and variables from
[service-principal-setup.md](../docs/service-principal-setup.md); nothing new has to be created.

| Workflow | Client ID variable | Subscription role needed | Why it is enough |
|---|---|---|---|
| `policies-plan.yml` | `AZURE_PLAN_CLIENT_ID` (falls back to `AZURE_CLIENT_ID`) | Reader | EPAC reads policy resources, role assignments and resource groups (Resource Graph) |
| `policies-deploy.yml` | `AZURE_APPLY_CLIENT_ID` (falls back to `AZURE_CLIENT_ID`) | Owner (or Contributor + User Access Administrator) | covers Resource Policy Contributor and Role Based Access Control Administrator, which EPAC needs |

`AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` are used for the OIDC login and rendered into the definitions.
The OIDC federated credentials are the same ones (`pull_request` for plan, branch `main` for deploy).

---

## 6. Running locally

With [act](https://github.com/nektos/act), the workflow headers show the exact commands; both reuse the host
`az login` like the infrastructure workflows. Under act, `azure/login` is skipped and the Azure CLI token is
handed to Az PowerShell (valid for about an hour).

By hand, with PowerShell 7.4+:

```powershell
Install-PSResource Az.Accounts, Az.Resources, Az.ResourceGraph, EnterprisePolicyAsCode -Scope CurrentUser
Connect-AzAccount -Tenant <tenant-id> -Subscription <subscription-id>

# Render the placeholders into a scratch copy; never into policies/ itself.
$rendered = Join-Path ([System.IO.Path]::GetTempPath()) 'epac/Definitions'
Remove-Item $rendered -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item policies $rendered -Recurse
Get-ChildItem $rendered -Recurse -Include *.json, *.jsonc | ForEach-Object {
  (Get-Content $_ -Raw) -replace '__AZURE_TENANT_ID__', '<tenant-id>' -replace '__AZURE_SUBSCRIPTION_ID__', '<subscription-id>' |
    Set-Content $_ -NoNewline
}

Build-DeploymentPlans -DefinitionsRootFolder $rendered -OutputFolder ./Output -PacEnvironmentSelector tfstate-subscription -DetailedOutput
# Review ./Output/plans-tfstate-subscription/policy-plan.json, then, with an identity that may deploy:
Deploy-PolicyPlan -DefinitionsRootFolder $rendered -InputFolder ./Output -PacEnvironmentSelector tfstate-subscription
```

`Output/` is ignored by git.

---

## 7. Extending

- **New resource type in `infrastructure/`:** add it to `allowedResourceTypes` in
  `policyDefinitions/tfstate-allowed-resource-types.jsonc`, and add a hardening policy for it: copy the closest
  `tfstate-*.jsonc`, keep `effect` parameterised with default `Deny`, reference it from the policy set with a new
  `<name>Effect` parameter, and set that effect in `policyAssignments/tfstate-hardening.jsonc`.
- **Changing a value** (retention, SKU, locations, tags): change the assignment parameter and the matching
  input in `infrastructure/` in the same pull request.
- **Exception for one resource:** a time-boxed exemption, see `policyExemptions/tfstate-subscription/README.md`.
- **Aliases:** custom policies refer to resource properties through policy aliases. Azure validates them when the
  definition is created, so a wrong alias fails `policies-deploy.yml` at that definition, not silently. List the
  aliases of a resource type with
  `az provider show --namespace Microsoft.Insights --expand "resourceTypes/aliases" --query "resourceTypes[?resourceType=='actionGroups'].aliases[].name"`.
- **Bumping EPAC:** change `epac-version` in `.github/actions/epac-setup/action.yml` (the schema pin in
  `.github/actions/epac-definitions/action.yml` follows it); the PowerShell Gallery has no Dependabot ecosystem.

---

## 8. Known behaviours

- `strategy: full` treats this folder as the only source of policy resources at the subscription and in its
  resource groups. Switch to `ownedOnly` in `global-settings.jsonc` while adopting a subscription that still has
  policy resources you want to keep, then back to `full`.
- Policies assigned above the subscription (management groups) are inherited and not managed here.
- `pacOwnerId` must never change after the first deployment.
- EPAC usage telemetry is disabled (`telemetryOptOut`): it would create a `pid-*` deployment on every run.
- The role assignment allow-list applies to every scope in the subscription, including resource groups other
  than the state resource group. Roles that are not in the list cannot be assigned anywhere in it.

## References

- EPAC documentation: <https://azure.github.io/enterprise-azure-policy-as-code/>
- Azure Policy definition structure: <https://learn.microsoft.com/azure/governance/policy/concepts/definition-structure-basics>
- Built-in policy definitions (rules reused here): <https://github.com/Azure/azure-policy/tree/master/built-in-policies/policyDefinitions>
