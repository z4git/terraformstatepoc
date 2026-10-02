output "alert_rule_name" {
  value = azurerm_monitor_scheduled_query_rules_alert_v2.this.name
}

output "alert_rule_id" {
  value = azurerm_monitor_scheduled_query_rules_alert_v2.this.id
}
