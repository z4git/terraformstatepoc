resource "azurerm_storage_account" "tfstate" {
  # Hosted runners cannot reach a private endpoint, so the account stays reachable over the internet with
  # default_action = "Deny" and an IP allowlist. docs/terraform-best-practices.md calls that the weaker
  # posture that has to be accepted explicitly; these two skips are that acceptance.
  #checkov:skip=CKV_AZURE_59:public network access is intentional; access is limited to network_rules.ip_rules
  #checkov:skip=CKV_AZURE_35:network_default_action is a deliberate, documented input; set it to Deny once runners have a stable egress
  #checkov:skip=CKV2_AZURE_33:no private endpoint until CI runs on ARC/self-hosted runners in a VNet
  # Platform-managed keys. A CMK needs a Key Vault that is itself outside Terraform state, which this PoC does not have.
  #checkov:skip=CKV2_AZURE_1:platform-managed encryption keys are accepted for the state account
  # Storage logs go to Log Analytics through azurerm_monitor_diagnostic_setting below (category_group allLogs
  # covers StorageRead/Write/Delete). The check only recognises the legacy queue_properties.logging block,
  # and this account serves blobs only.
  #checkov:skip=CKV_AZURE_33:queue logging is covered by the diagnostic setting; no queues are used
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.replication_type
  access_tier              = "Hot"

  https_traffic_only_enabled       = true
  min_tls_version                  = "TLS1_2"
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  allowed_copy_scope               = "AAD"
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false
  public_network_access_enabled    = var.public_network_access_enabled

  # Matches Bicep requireInfrastructureEncryption. ForceNew in the provider and immutable in the ARM
  # API, so on an account that already exists this plans a destroy/create that prevent_destroy blocks.
  infrastructure_encryption_enabled = true

  identity {
    type = "SystemAssigned"
  }

  network_rules {
    default_action = var.network_default_action
    bypass         = ["AzureServices"]
    ip_rules       = []
  }

  blob_properties {
    versioning_enabled       = true
    change_feed_enabled      = true
    last_access_time_enabled = true

    delete_retention_policy {
      days = var.soft_delete_retention_days
    }

    container_delete_retention_policy {
      days = var.soft_delete_retention_days
    }

    restore_policy {
      days = var.restore_policy_days
    }
  }

  lifecycle {
    prevent_destroy = true

    # IP rules are owned by the Bicep deployment and by pipelines that temporarily add their runner IP
    # (.github/actions/storage-firewall-runner-ip). Managing them here would remove that IP mid-apply.
    ignore_changes = [network_rules[0].ip_rules]
  }
}

resource "azurerm_storage_container" "tfstate" {
  # Read logging arrives via the blob diagnostic setting below; the check looks for an enabled_log block
  # naming StorageRead explicitly, which category_group = "allLogs" already includes.
  #checkov:skip=CKV2_AZURE_21:blob read logging is covered by the allLogs diagnostic setting
  for_each = var.container_names

  name                  = each.value
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

# Storage logs are emitted per service (the account resource itself only has metrics).
resource "azurerm_monitor_diagnostic_setting" "tfstate" {
  for_each = toset(["blob", "queue", "table", "file"])

  name                       = "diag-${each.value}-to-log-analytics"
  target_resource_id         = "${azurerm_storage_account.tfstate.id}/${each.value}Services/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # allLogs includes the audit category group (StorageRead, StorageWrite, StorageDelete),
  # so audit logs are sent without a separate "audit" block.
  enabled_log {
    category_group = "allLogs"
  }
}
