output "backup_vault_name" {
  value = azurerm_data_protection_backup_vault.this.name
}

output "backup_vault_id" {
  value = azurerm_data_protection_backup_vault.this.id
}

output "backup_instance_id" {
  value = azurerm_data_protection_backup_instance_blob_storage.protection_backup_vault.id
}
