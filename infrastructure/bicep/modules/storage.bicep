targetScope = 'resourceGroup'

param location string
param storageAccountName string
param skuName string
param containerNames array
param publicNetworkAccess string
param networkDefaultAction string
param allowedIpAddresses array
param softDeleteRetentionDays int
param restorePolicyDays int
param terraformApplyPrincipalId string
param terraformApplyPrincipalType string
param terraformPlanPrincipalId string
param terraformPlanPrincipalType string
param terraformLocalPrincipalId string
param terraformLocalPrincipalType string
param enableDeleteLock bool
param tags object

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
// Control plane only (no data actions): lets pipelines add/remove their runner IP in the firewall.
var storageAccountContributorRoleId = '17d1049b-9a84-46fb-8f53-869881c3d3ab'
var roleBasedAccessControlAdministratorRoleId = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
// The only role Terraform assigns on the account: the backup vault identity (modules/backup-vault).
var storageAccountBackupContributorRoleId = 'e5e2a7ff-d759-4cd2-bb51-3152d37e2eb1'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  // Same accepted posture as the Terraform module: hosted runners cannot reach a private endpoint, so
  // networkAcls.defaultAction = 'Deny' plus an IP allowlist is the control (docs/terraform-best-practices.md).
  //checkov:skip=CKV_AZURE_59:public network access is intentional; access is limited to networkAcls.ipRules
  // networkDefaultAction is 'Allow' while CI runs on GitHub-hosted runners: their egress IP is not stable
  // enough for an allowlist (docs/tfstate-infrastructure.md, "State storage network access"). Entra ID + RBAC
  // is the access control; shared keys are disabled and every request is logged and alerted on.
  //checkov:skip=CKV_AZURE_35:networkDefaultAction is a deliberate, documented input; set it to Deny once runners have a stable egress
  // The name is composed from parameters, so Checkov sees an unresolved expression instead of a name.
  // @minLength/@maxLength here and the regex validation in the workflows enforce the real rules.
  //checkov:skip=CKV_AZURE_43:storageAccountName is a parameter expression Checkov cannot evaluate
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: skuName
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowedCopyScope: 'AAD'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    publicNetworkAccess: publicNetworkAccess
    // Double encryption at rest: a second, independent AES-256 pass under the platform's own pass.
    // Settable only at creation -- the API rejects it on an existing account, so this cannot be
    // turned on by redeploying over the account that already exists.
    encryption: {
      requireInfrastructureEncryption: true
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
    networkAcls: {
      defaultAction: networkDefaultAction
      bypass: 'AzureServices'
      ipRules: [
        for ip in allowedIpAddresses: {
          value: ip
          action: 'Allow'
        }
      ]
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    isVersioningEnabled: true
    changeFeed: {
      enabled: true
    }
    // blobType and allowPermanentDelete are Azure's defaults; declared so What-if does not report them as removed.
    lastAccessTimeTrackingPolicy: {
      enable: true
      blobType: [
        'blockBlob'
      ]
    }
    deleteRetentionPolicy: {
      enabled: true
      days: softDeleteRetentionDays
      allowPermanentDelete: false
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: softDeleteRetentionDays
    }
    restorePolicy: {
      enabled: true
      days: restorePolicyDays
    }
  }
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [
  for name in containerNames: {
    parent: blobService
    name: name
    properties: {
      publicAccess: 'None'
      // Azure's defaults; declared so What-if does not report them as removed.
      defaultEncryptionScope: '$account-encryption-key'
      denyEncryptionScopeOverride: false
    }
  }
]

resource applyBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (name, i) in containerNames: if (!empty(terraformApplyPrincipalId)) {
    name: guid(containers[i].id, terraformApplyPrincipalId, storageBlobDataContributorRoleId)
    scope: containers[i]
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
      principalId: terraformApplyPrincipalId
      principalType: terraformApplyPrincipalType
    }
  }
]

resource planBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (name, i) in containerNames: if (!empty(terraformPlanPrincipalId)) {
    name: guid(containers[i].id, terraformPlanPrincipalId, storageBlobDataReaderRoleId)
    scope: containers[i]
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
      principalId: terraformPlanPrincipalId
      principalType: terraformPlanPrincipalType
    }
  }
]

resource localBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (name, i) in containerNames: if (!empty(terraformLocalPrincipalId)) {
    name: guid(containers[i].id, terraformLocalPrincipalId, storageBlobDataContributorRoleId)
    scope: containers[i]
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
      principalId: terraformLocalPrincipalId
      principalType: terraformLocalPrincipalType
    }
  }
]

resource applyAccountContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(terraformApplyPrincipalId)) {
  name: guid(storageAccount.id, terraformApplyPrincipalId, storageAccountContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountContributorRoleId)
    principalId: terraformApplyPrincipalId
    principalType: terraformApplyPrincipalType
  }
}

resource planAccountContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(terraformPlanPrincipalId)) {
  name: guid(storageAccount.id, terraformPlanPrincipalId, storageAccountContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountContributorRoleId)
    principalId: terraformPlanPrincipalId
    principalType: terraformPlanPrincipalType
  }
}

// Lets terraform apply create and remove the backup vault's role assignment. The condition limits it to
// Storage Account Backup Contributor, so the apply identity cannot grant itself or others any other role.
resource applyRbacAdministrator 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(terraformApplyPrincipalId)) {
  name: guid(storageAccount.id, terraformApplyPrincipalId, roleBasedAccessControlAdministratorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBasedAccessControlAdministratorRoleId)
    principalId: terraformApplyPrincipalId
    principalType: terraformApplyPrincipalType
    description: 'Terraform apply: may only assign or remove Storage Account Backup Contributor (backup vault identity).'
    conditionVersion: '2.0'
    condition: '((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/write\'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${storageAccountBackupContributorRoleId}})) AND ((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/delete\'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${storageAccountBackupContributorRoleId}}))'
  }
}

resource deleteLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
  name: 'lock-tfstate-cannotdelete'
  dependsOn: [
    containers
    applyBlobContributor
    planBlobReader
    localBlobContributor
    applyAccountContributor
    planAccountContributor
    applyRbacAdministrator
  ]
  properties: {
    level: 'CanNotDelete'
    notes: 'Protects Terraform remote state from accidental deletion.'
  }
}

output storageAccountName string = storageAccount.name
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
