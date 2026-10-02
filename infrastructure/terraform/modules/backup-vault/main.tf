resource "azurerm_data_protection_backup_vault" "this" {
  name                = var.backup_vault_name
  resource_group_name = var.resource_group_name
  location            = var.location
  datastore_type      = var.backup_vault_datastore_type
  redundancy          = var.backup_vault_redundancy
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# Lets the vault manage point-in-time restore on the storage account (operational backup).
resource "azurerm_role_assignment" "protection_backup_vault" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Account Backup Contributor"
  principal_id         = azurerm_data_protection_backup_vault.this.identity[0].principal_id
}

resource "azurerm_data_protection_backup_policy_blob_storage" "protection_backup_vault" {
  name     = var.backup_policy_name
  vault_id = azurerm_data_protection_backup_vault.this.id
  # Operational backup: restore points stay in the storage account and the vault sets its point-in-time
  # restore window to this duration.
  operational_default_retention_duration = var.operational_retention_duration
}

resource "azurerm_data_protection_backup_instance_blob_storage" "protection_backup_vault" {
  name               = var.backup_instance_name
  vault_id           = azurerm_data_protection_backup_vault.this.id
  location           = var.location
  storage_account_id = var.storage_account_id
  backup_policy_id   = azurerm_data_protection_backup_policy_blob_storage.protection_backup_vault.id

  depends_on = [azurerm_role_assignment.protection_backup_vault]
}

resource "azurerm_monitor_diagnostic_setting" "protection_backup_vault" {
  name                       = var.diagnostic_settings_name
  target_resource_id         = azurerm_data_protection_backup_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "Health"
  }
}
