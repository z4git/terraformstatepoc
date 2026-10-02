variable "name" {
  description = "Log Analytics workspace name (4-63 letters, digits and hyphens)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the workspace."
  type        = string
}

variable "location" {
  description = "Azure region for the workspace."
  type        = string
}

variable "sku" {
  description = "Workspace pricing tier."
  type        = string
}

variable "retention_in_days" {
  description = "Days to keep data in the workspace (30-730)."
  type        = number
}

variable "tags" {
  description = "Tags applied to the workspace."
  type        = map(string)
}
