variable "name" {
  description = "Action group name."
  type        = string
}

variable "short_name" {
  description = "Short name shown in email and SMS notifications (1-12 characters)."
  type        = string

  validation {
    condition     = length(var.short_name) >= 1 && length(var.short_name) <= 12
    error_message = "short_name must be 1-12 characters."
  }
}

variable "resource_group_name" {
  description = "Resource group that holds the action group."
  type        = string
}

variable "email_addresses" {
  description = "Email addresses notified by the action group."
  type        = set(string)
}

variable "tags" {
  description = "Tags applied to the action group."
  type        = map(string)
}
