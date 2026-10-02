resource "azurerm_monitor_scheduled_query_rules_alert_v2" "this" {
  name                = var.name
  display_name        = var.display_name
  description         = var.description
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  scopes               = [var.log_analytics_workspace_id]
  severity             = var.severity
  evaluation_frequency = var.evaluation_frequency
  window_duration      = var.window_duration

  # Stateful: notifies once when the alert fires (per dimension value) and again when it resolves,
  # so overlapping evaluation windows do not send duplicate emails.
  auto_mitigation_enabled = true

  # The queried table only exists after the first log arrives; validating on create would fail before that.
  skip_query_validation = true

  criteria {
    query                   = var.query
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    dynamic "dimension" {
      for_each = var.dimensions

      content {
        name     = dimension.value
        operator = "Include"
        values   = ["*"]
      }
    }

    failing_periods {
      number_of_evaluation_periods             = 1
      minimum_failing_periods_to_trigger_alert = 1
    }
  }

  action {
    action_groups = [var.action_group_id]
  }
}
