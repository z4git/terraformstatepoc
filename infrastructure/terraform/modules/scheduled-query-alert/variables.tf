variable "name" {
  description = "Alert rule resource name."
  type        = string
}

variable "display_name" {
  description = "Alert rule name shown in notifications."
  type        = string
}

variable "description" {
  description = "Alert rule description shown in notifications."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the alert rule."
  type        = string
}

variable "location" {
  description = "Azure region for the alert rule (the Log Analytics workspace region)."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace the query runs against."
  type        = string
}

variable "query" {
  description = "KQL query; every returned row counts towards the alert."
  type        = string
}

variable "dimensions" {
  description = "Query result columns that split the alert, one alert per distinct value."
  type        = list(string)
  default     = []
}

variable "severity" {
  description = "Alert severity, 0 (critical) to 4 (verbose)."
  type        = number

  validation {
    condition     = contains([0, 1, 2, 3, 4], var.severity)
    error_message = "severity must be 0-4."
  }
}

variable "evaluation_frequency" {
  description = "How often the query runs (ISO 8601 duration, e.g. PT5M)."
  type        = string
}

variable "window_duration" {
  description = "Time range the query covers on each run (ISO 8601 duration, e.g. PT15M)."
  type        = string
}

variable "action_group_id" {
  description = "Action group notified when the alert fires."
  type        = string
}

variable "tags" {
  description = "Tags applied to the alert rule."
  type        = map(string)
}
