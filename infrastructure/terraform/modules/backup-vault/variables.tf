variable "backup_vault_name" {
  description = "Backup vault name (2-50 letters, digits and hyphens, starting with a letter)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the backup vault."
  type        = string
}

variable "location" {
  description = "Azure region for the backup vault; must match the storage account region."
  type        = string
}

variable "backup_vault_datastore_type" {
  description = "Backup vault datastore type."
  type        = string

  validation {
    condition     = contains(["VaultStore", "OperationalStore", "ArchiveStore", "SnapshotStore"], var.backup_vault_datastore_type)
    error_message = "backup_vault_datastore_type must be VaultStore, OperationalStore, ArchiveStore or SnapshotStore."
  }
}

variable "backup_vault_redundancy" {
  description = "Backup vault storage redundancy. Cannot be changed once the vault protects an item."
  type        = string

  validation {
    condition     = contains(["LocallyRedundant", "ZoneRedundant", "GeoRedundant"], var.backup_vault_redundancy)
    error_message = "backup_vault_redundancy must be LocallyRedundant, ZoneRedundant or GeoRedundant."
  }
}

variable "storage_account_id" {
  description = "Storage account to protect."
  type        = string
}

variable "backup_policy_name" {
  description = "Blob backup policy name."
  type        = string
}

variable "backup_instance_name" {
  description = "Backup instance name for the storage account."
  type        = string
}

variable "operational_retention_duration" {
  description = "Operational backup retention as an ISO 8601 duration (e.g. P30D). Must be shorter than the blob soft delete retention."
  type        = string
}

variable "diagnostic_settings_name" {
  description = "Name of the diagnostic setting that sends backup vault logs to Log Analytics."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace that receives backup vault logs and health metrics."
  type        = string
}

variable "tags" {
  description = "Tags applied to the backup vault."
  type        = map(string)
}
