locals {
  application_name = lower(var.application_name)
  environment_name = lower(var.environment_name)

  resource_group_name  = "rg-${local.application_name}-tfstate-${local.environment_name}-${var.environment_number}"
  name_suffix          = "${local.application_name}${local.environment_name}${var.environment_number}${lower(var.unique_identifier)}"
  storage_account_name = "st${local.name_suffix}"
  log_analytics_name   = "log${local.name_suffix}"
  action_group_name    = "ag${local.name_suffix}"
  # Shown as the sender in notifications; limited to 12 characters (2 + 5 + 3 + 1 = 11).
  action_group_short_name    = "ag${local.application_name}${local.environment_name}${var.environment_number}"
  state_access_alert_name    = "alert-tfstate-access-${local.name_suffix}"
  state_non_oauth_alert_name = "alert-tfstate-non-oauth-${local.name_suffix}"
  backup_vault_name          = "bvault${local.name_suffix}"

  # Only these identities may touch the state files without alerting. The local principal
  # (TERRAFORM_LOCAL_PRINCIPAL_ID) is left out on purpose, so local access is always reported.
  state_allowed_principal_ids = [
    for id in [var.terraform_apply_principal_id, var.terraform_plan_principal_id] : lower(id) if id != ""
  ]

  # Identical to the Bicep tags so the first plan after import shows no changes.
  tags = {
    application       = local.application_name
    environment       = local.environment_name
    environmentNumber = tostring(var.environment_number)
    workload          = "terraform-state"
    managedBy         = "bicep"
  }
}

resource "azurerm_resource_group" "tfstate" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

module "log_analytics" {
  source = "./modules/log-analytics"

  name                = local.log_analytics_name
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_analytics_retention_in_days
  # Created by Terraform only (not Bicep), so it is not tagged managedBy = bicep.
  tags = merge(local.tags, { managedBy = "terraform" })
}

module "action_group" {
  source = "./modules/action-group"

  name                = local.action_group_name
  short_name          = local.action_group_short_name
  resource_group_name = azurerm_resource_group.tfstate.name
  email_addresses     = var.notification_emails
  # Created by Terraform only (not Bicep), so it is not tagged managedBy = bicep.
  tags = merge(local.tags, { managedBy = "terraform" })
}

module "storage" {
  source = "./modules/storage"

  resource_group_name           = azurerm_resource_group.tfstate.name
  location                      = azurerm_resource_group.tfstate.location
  storage_account_name          = local.storage_account_name
  container_names               = var.container_names
  replication_type              = var.replication_type
  soft_delete_retention_days    = var.soft_delete_retention_days
  restore_policy_days           = var.restore_policy_days
  public_network_access_enabled = var.public_network_access_enabled
  network_default_action        = var.network_default_action
  log_analytics_workspace_id    = module.log_analytics.workspace_id
  tags                          = local.tags
}

module "backup_vault" {
  source = "./modules/backup-vault"

  backup_vault_name           = local.backup_vault_name
  resource_group_name         = azurerm_resource_group.tfstate.name
  location                    = azurerm_resource_group.tfstate.location
  backup_vault_datastore_type = var.backup_vault_datastore_type
  backup_vault_redundancy     = var.backup_vault_redundancy

  storage_account_id   = module.storage.storage_account_id
  backup_policy_name   = "bkpol-tfstate-blob"
  backup_instance_name = "terraform-state-backup-instance"
  # Same window as the storage account's point-in-time restore (Bicep restorePolicyDays), which the
  # backup policy takes over; different values would make Bicep, Terraform and the vault overwrite each other.
  operational_retention_duration = "P${var.restore_policy_days}D"

  diagnostic_settings_name   = "diag-backup-vault-to-log-analytics"
  log_analytics_workspace_id = module.log_analytics.workspace_id
  # Created by Terraform only (not Bicep), so it is not tagged managedBy = bicep.
  tags = merge(local.tags, { managedBy = "terraform" })
}

module "state_access_alert" {
  source = "./modules/scheduled-query-alert"

  name                = local.state_access_alert_name
  display_name        = "Terraform state accessed by an unexpected identity (${local.storage_account_name})"
  description         = "A request to the Terraform state containers came from an identity other than the Terraform plan or apply principal (including the local principal)."
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location

  log_analytics_workspace_id = module.log_analytics.workspace_id
  query = templatefile("${path.module}/queries/tfstate-unexpected-access.kql.tftpl", {
    storage_account_name  = module.storage.storage_account_name
    state_containers      = jsonencode(sort(tolist(var.container_names)))
    allowed_principal_ids = jsonencode(local.state_allowed_principal_ids)
  })
  # One alert (and email) per identity.
  dimensions = ["RequesterObjectId"]

  severity             = 1
  evaluation_frequency = "PT5M"
  # Longer than the frequency so logs that arrive late are still evaluated; stateful alerts avoid duplicate emails.
  window_duration = "PT15M"

  action_group_id = module.action_group.action_group_id
  # Created by Terraform only (not Bicep), so it is not tagged managedBy = bicep.
  tags = merge(local.tags, { managedBy = "terraform" })
}

# Companion to state_access_alert: that query can only judge callers it can identify, so a key, SAS or
# anonymous request -- which carries no RequesterObjectId -- would otherwise reach the state containers
# unreported. Section 6 signal 2 of docs/terraform-best-practices.md.
module "state_non_oauth_alert" {
  source = "./modules/scheduled-query-alert"

  name                = local.state_non_oauth_alert_name
  display_name        = "Terraform state accessed without Entra ID authentication (${local.storage_account_name})"
  description         = "A request to the Terraform state containers authenticated with an account key, a SAS token, or not at all. Shared key access is disabled, so these are rejected; a hit means the key path was re-enabled or something is probing the account."
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location

  log_analytics_workspace_id = module.log_analytics.workspace_id
  query = templatefile("${path.module}/queries/tfstate-non-oauth-access.kql.tftpl", {
    storage_account_name = module.storage.storage_account_name
    state_containers     = jsonencode(sort(tolist(var.container_names)))
  })
  # One alert (and email) per authentication type, so a key attempt and a SAS attempt are distinct.
  dimensions = ["AuthenticationType"]

  severity             = 1
  evaluation_frequency = "PT5M"
  # Longer than the frequency so logs that arrive late are still evaluated; stateful alerts avoid duplicate emails.
  window_duration = "PT15M"

  action_group_id = module.action_group.action_group_id
  # Created by Terraform only (not Bicep), so it is not tagged managedBy = bicep.
  tags = merge(local.tags, { managedBy = "terraform" })
}
