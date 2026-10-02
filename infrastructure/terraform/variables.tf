variable "subscription_id" {
  description = "Subscription that holds the Bicep-created Terraform state resources."
  type        = string
}

variable "location" {
  description = "Azure region the Bicep deployment used."
  type        = string
  default     = "westeurope"
}

variable "application_name" {
  description = "Same value as the Bicep applicationName input (case-insensitive)."
  type        = string
  default     = "alz"

  validation {
    condition     = can(regex("^[a-z0-9]{1,5}$", lower(var.application_name)))
    error_message = "application_name must be 1-5 letters or digits."
  }
}

variable "environment_name" {
  description = "Same value as the Bicep environmentName input (case-insensitive)."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9]{1,3}$", lower(var.environment_name)))
    error_message = "environment_name must be 1-3 letters or digits."
  }
}

variable "environment_number" {
  description = "Same value as the Bicep environmentNumber input."
  type        = number
  default     = 1

  validation {
    condition     = var.environment_number >= 1 && var.environment_number <= 9 && floor(var.environment_number) == var.environment_number
    error_message = "environment_number must be a whole number 1-9."
  }
}

variable "unique_identifier" {
  description = "The 13-character uniqueIdentifier the tfstate-infrastructure-deploy and tfstate-infrastructure-plan workflows generate."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{13}$", lower(var.unique_identifier)))
    error_message = "unique_identifier must be exactly 13 letters or digits."
  }
}

variable "container_names" {
  description = "Containers the Bicep deployment created (containerNames)."
  type        = set(string)
  default     = ["tfstate"]
}

variable "replication_type" {
  description = "Replication type matching the Bicep skuName (e.g. GZRS for Standard_GZRS)."
  type        = string
  default     = "GZRS"
}

variable "soft_delete_retention_days" {
  description = "Matches Bicep softDeleteRetentionDays."
  type        = number
  default     = 90
}

variable "restore_policy_days" {
  description = "Matches Bicep restorePolicyDays. Must be lower than soft_delete_retention_days."
  type        = number
  default     = 30
}

variable "network_default_action" {
  description = "Matches Bicep networkDefaultAction (networkDefaultAction in infrastructure/parameterfiles/tfstate-infrastructure.json). Deny limits access to the firewall IP rules; Allow accepts any source and leaves Entra ID + RBAC as the only control."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.network_default_action)
    error_message = "network_default_action must be Allow or Deny."
  }
}

variable "public_network_access_enabled" {
  description = "Matches Bicep publicNetworkAccess (Enabled = true)."
  type        = bool
  default     = true
}

variable "log_analytics_sku" {
  description = "Log Analytics workspace pricing tier."
  type        = string
  default     = "PerGB2018"
}

variable "log_analytics_retention_in_days" {
  description = "Days to keep storage logs in the Log Analytics workspace (30-730)."
  type        = number
  default     = 30

  validation {
    condition     = var.log_analytics_retention_in_days >= 30 && var.log_analytics_retention_in_days <= 730
    error_message = "log_analytics_retention_in_days must be between 30 and 730."
  }
}

variable "backup_vault_datastore_type" {
  description = "Backup vault datastore type."
  type        = string
  default     = "VaultStore"
}

variable "backup_vault_redundancy" {
  description = "Backup vault redundancy. Operational blob backups stay in the (GZRS) storage account, so this only affects vault metadata. Cannot be changed once the vault protects an item."
  type        = string
  default     = "LocallyRedundant"
}

variable "terraform_apply_principal_id" {
  description = "Object ID of the Terraform apply identity (TERRAFORM_APPLY_PRINCIPAL_ID). Its state access does not alert."
  type        = string
  default     = ""

  validation {
    condition     = var.terraform_apply_principal_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.terraform_apply_principal_id))
    error_message = "terraform_apply_principal_id must be empty or an object ID (GUID)."
  }
}

variable "terraform_plan_principal_id" {
  description = "Object ID of the Terraform plan identity (TERRAFORM_PLAN_PRINCIPAL_ID). Its state access does not alert."
  type        = string
  default     = ""

  validation {
    condition     = var.terraform_plan_principal_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.terraform_plan_principal_id))
    error_message = "terraform_plan_principal_id must be empty or an object ID (GUID)."
  }
}

variable "notification_emails" {
  description = "Email addresses notified by the action group (notificationEmails in infrastructure/parameterfiles/tfstate-infrastructure.json)."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for email in var.notification_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))])
    error_message = "notification_emails must contain valid email addresses."
  }
}
