variable "resource_group_name" {
  description = "Resource group that holds the storage account."
  type        = string
}

variable "location" {
  description = "Azure region for the storage account."
  type        = string
}

variable "storage_account_name" {
  description = "Globally unique storage account name (3-24 lowercase letters and digits)."
  type        = string
}

variable "container_names" {
  description = "Blob containers for state, one per stack/landing zone."
  type        = set(string)
}

variable "replication_type" {
  description = "Replication type (e.g. GZRS for Standard_GZRS)."
  type        = string
}

variable "soft_delete_retention_days" {
  description = "Days to keep soft-deleted blobs and containers."
  type        = number
}

variable "restore_policy_days" {
  description = "Point-in-time restore window in days. Must be lower than soft_delete_retention_days."
  type        = number
}

variable "network_default_action" {
  description = "Matches Bicep networkDefaultAction. Deny limits access to the IP rules; Allow leaves Entra ID + RBAC as the only control."
  type        = string

  validation {
    condition     = contains(["Allow", "Deny"], var.network_default_action)
    error_message = "network_default_action must be Allow or Deny."
  }
}

variable "public_network_access_enabled" {
  description = "Allow public network access (limited by the firewall IP rules)."
  type        = bool
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace that receives all storage logs."
  type        = string
}

variable "tags" {
  description = "Tags applied to the storage account."
  type        = map(string)
}
