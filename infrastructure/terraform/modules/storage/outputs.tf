output "storage_account_name" {
  value = azurerm_storage_account.tfstate.name
}

output "storage_account_id" {
  value = azurerm_storage_account.tfstate.id
}

output "container_names" {
  value = [for c in azurerm_storage_container.tfstate : c.name]
}

output "primary_blob_endpoint" {
  value = azurerm_storage_account.tfstate.primary_blob_endpoint
}
