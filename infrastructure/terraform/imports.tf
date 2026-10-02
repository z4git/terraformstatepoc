# Adopts the resources created by infrastructure/bicep/main.bicep. After the first successful apply these
# blocks are no-ops and can be removed. Role assignments and the CanNotDelete lock stay owned by Bicep.
# Import blocks are only allowed in the root module, so they target the module addresses from here.

locals {
  resource_group_id  = "/subscriptions/${var.subscription_id}/resourceGroups/${local.resource_group_name}"
  storage_account_id = "${local.resource_group_id}/providers/Microsoft.Storage/storageAccounts/${local.storage_account_name}"
}

import {
  to = azurerm_resource_group.tfstate
  id = local.resource_group_id
}

import {
  to = module.storage.azurerm_storage_account.tfstate
  id = local.storage_account_id
}

import {
  for_each = var.container_names
  to       = module.storage.azurerm_storage_container.tfstate[each.value]
  id       = "${local.storage_account_id}/blobServices/default/containers/${each.value}"
}
