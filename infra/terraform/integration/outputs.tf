output "dynatrace_metrics_ingest_token" {
  description = "metrics.ingest token for the scenario controller and Magic 8 Ball."
  value       = dynatrace_api_token.metrics_ingest.token
  sensitive   = true
}

output "dynatrace_paas_token" {
  description = "InstallerDownload-only token for the OneAgent VM extension."
  value       = dynatrace_api_token.paas.token
  sensitive   = true
}

output "dynatrace_operator_api_token" {
  description = "apiToken for the Dynatrace Operator (DynaKube secret)."
  value       = dynatrace_api_token.operator.token
  sensitive   = true
}

output "dynatrace_operator_data_ingest_token" {
  description = "dataIngestToken for the Dynatrace Operator (DynaKube secret)."
  value       = dynatrace_api_token.operator_data_ingest.token
  sensitive   = true
}

output "aks_host_group" {
  value = local.aks_host_group
}

output "vm_host_group" {
  value = local.vm_host_group
}

output "problem_title_prefix" {
  value = local.title_prefix
}

output "alerting_profile_id" {
  value = dynatrace_alerting.lab.id
}

output "metric_event_ids" {
  value = { for k, v in dynatrace_metric_events.lab : k => v.id }
}

output "servicenow_assignment_group_sys_id" {
  value = var.servicenow_enabled ? restapi_object.assignment_group[0].id : ""
}

output "servicenow_integration_user" {
  value = var.servicenow_enabled ? var.integration_user : ""
}

output "servicenow_integration_password" {
  description = "Password for the integration user. Used by the SRE Agent ServiceNow connector."
  value       = var.servicenow_enabled ? random_password.integration.result : ""
  sensitive   = true
}
