output "resource_group_name" {
  value = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  value = module.storage.storage_account_name
}

output "storage_account_id" {
  value = module.storage.storage_account_id
}

output "container_names" {
  value = module.storage.container_names
}

output "primary_blob_endpoint" {
  value = module.storage.primary_blob_endpoint
}

output "log_analytics_workspace_name" {
  value = module.log_analytics.workspace_name
}

output "log_analytics_workspace_id" {
  value = module.log_analytics.workspace_id
}

output "action_group_name" {
  value = module.action_group.action_group_name
}

output "action_group_id" {
  value = module.action_group.action_group_id
}

output "backup_vault_name" {
  value = module.backup_vault.backup_vault_name
}

output "backup_vault_id" {
  value = module.backup_vault.backup_vault_id
}

output "state_access_alert_name" {
  value = module.state_access_alert.alert_rule_name
}

output "state_non_oauth_alert_name" {
  value = module.state_non_oauth_alert.alert_rule_name
}
