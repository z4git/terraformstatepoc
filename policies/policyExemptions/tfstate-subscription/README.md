# Policy exemptions for `tfstate-subscription`

Exemption files (`*.json`, `*.jsonc` or `*.csv`) in this folder are deployed by EPAC to the
`tfstate-subscription` environment (`pacSelector` in `../../global-settings.jsonc`). The folder is
committed on purpose: with it present, EPAC also **deletes** exemptions that exist in Azure but not here,
so a portal-created exemption cannot silently weaken the baseline.

There are no exemptions today. Prefer changing the policy over exempting from it: if a resource type is
missing from the allow-list, add it to `policyDefinitions/tfstate-allowed-resource-types.jsonc`; if a
setting has a documented reason to differ, set that policy's effect parameter in
`policyAssignments/tfstate-hardening.jsonc` (as done for `storageNetworkDefaultDenyEffect`).

When an exemption is the right tool (a time-boxed waiver for one resource), add a file here, for example:

```jsonc
{
  "$schema": "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-exemption-schema.json",
  "exemptions": [
    {
      "name": "tfstate-diag-archive-waiver",
      "displayName": "Temporary archive diagnostic setting on the state account",
      "description": "Ticket 1234: archive storage logs to the audit storage account until the SIEM connector is live.",
      "exemptionCategory": "Waiver",
      "expiresOn": "2026-12-31T00:00:00Z",
      "scope": "/subscriptions/__AZURE_SUBSCRIPTION_ID__/resourceGroups/rg-alz-tfstate-dev-1",
      "policyAssignmentId": "/subscriptions/__AZURE_SUBSCRIPTION_ID__/providers/Microsoft.Authorization/policyAssignments/tfstate-hardening",
      "policyDefinitionReferenceIds": [
        "diagnosticSettingLogAnalyticsOnly"
      ],
      "metadata": {
        "requestedBy": "platform-team@example.com"
      }
    }
  ]
}
```

`__AZURE_SUBSCRIPTION_ID__` is replaced by the workflows like everywhere else under `policies/`.
Always set `expiresOn`; the pull request plan shows the exemption before it is deployed. Reference:
<https://azure.github.io/enterprise-azure-policy-as-code/policy-exemptions/>.
