locals {
  # Every Dynatrace object carries this prefix. Problem routing (the classic
  # alerting profile or the platform workflow trigger) matches on it, so only
  # this lab's problems reach ServiceNow even when the environment is shared.
  title_prefix   = "[sre-demo-${var.lab_suffix}]"
  aks_host_group = "sre-demo-aks-${var.lab_suffix}"
  vm_host_group  = "sre-demo-vm-${var.lab_suffix}"

  lab_filter = "filter(eq(\"lab.suffix\",\"${var.lab_suffix}\"))"

  aks_hosts = "filter(in(\"dt.entity.host\",entitySelector(\"type(HOST),fromRelationships.isInstanceOf(type(HOST_GROUP),entityName.equals(~\"${local.aks_host_group}~\"))\")))"

  # DQL equivalents for the latest platform (Davis anomaly detectors).
  dql_lab      = "filter: lab.suffix == \"${var.lab_suffix}\""
  dql_aks_host = "by: {dt.entity.host}, filter: in(dt.entity.host, classicEntitySelector(\"type(HOST),fromRelationships.isInstanceOf(type(HOST_GROUP),entityName.equals(\\\"${local.aks_host_group}\\\"))\"))"

  # Classic event types -> Davis event.type values for anomaly detectors.
  davis_event_type = {
    RESOURCE = "RESOURCE_CONTENTION_EVENT"
    ERROR    = "ERROR_EVENT"
  }

  # Keep keys in step with toDynatraceKey() in apps/*/backend/src/dynatrace.ts
  # and the metric names in apps/scenario-controller/backend/src/telemetry.ts.
  # tests/consistency.test.mjs enforces this.
  metric_events = {
    "01-disk-capacity" = {
      title       = "01 App VM demo disk capacity"
      description = "The dedicated demo data disk on the App VM (/var/sre-demo) is above ${var.disk_threshold_percent}%. Expected root cause: runaway application logging."
      selector    = "sre_demo.disk_percent_used:${local.lab_filter}:max"
      dql         = "timeseries value = max(sre_demo.disk_percent_used), ${local.dql_lab}"
      condition   = "ABOVE"
      threshold   = var.disk_threshold_percent
      event_type  = "RESOURCE"
      violating   = 2
    }
    "02-aks-node-cpu" = {
      title       = "02 AKS node CPU pressure"
      description = "AKS node CPU utilisation is above ${var.node_pressure_threshold_percent}%. Expected remediation: scale the system node pool above the baseline."
      selector    = "builtin:host.cpu.usage:${local.aks_hosts}:splitBy():max"
      dql         = "timeseries value = max(dt.host.cpu.usage), ${local.dql_aks_host}"
      condition   = "ABOVE"
      threshold   = var.node_pressure_threshold_percent
      event_type  = "RESOURCE"
      violating   = 2
    }
    "02-aks-node-memory" = {
      title       = "02 AKS node memory pressure"
      description = "AKS node memory utilisation is above ${var.node_pressure_threshold_percent}%. Expected remediation: scale the system node pool above the baseline."
      selector    = "builtin:host.mem.usage:${local.aks_hosts}:splitBy():max"
      dql         = "timeseries value = max(dt.host.memory.usage), ${local.dql_aks_host}"
      condition   = "ABOVE"
      threshold   = var.node_pressure_threshold_percent
      event_type  = "RESOURCE"
      violating   = 2
    }
    "02-aks-pending-pods" = {
      title       = "02 AKS pods cannot be scheduled"
      description = "One or more pods in the sre-demo namespace are Pending, indicating insufficient allocatable node capacity."
      selector    = "sre_demo.aks_pending_pods:${local.lab_filter}:max"
      dql         = "timeseries value = max(sre_demo.aks_pending_pods), ${local.dql_lab}"
      condition   = "ABOVE"
      threshold   = 0.5
      event_type  = "RESOURCE"
      violating   = 2
    }
    "03-http-failure-rate" = {
      title       = "03 Magic 8 Ball HTTP failure rate"
      description = "Magic 8 Ball is returning server errors on more than ${var.failure_rate_threshold_percent}% of requests. Correlate with the deployment.imagetag dimension and /api/version."
      selector    = "sre_demo.magic8ball_request_failed:${local.lab_filter}:splitBy():avg"
      dql         = "timeseries value = avg(sre_demo.magic8ball_request_failed), ${local.dql_lab}"
      condition   = "ABOVE"
      threshold   = var.failure_rate_threshold_percent / 100
      event_type  = "ERROR"
      violating   = 2
    }
    "04-postgres-connections" = {
      title       = "04 PostgreSQL connection utilisation"
      description = "PostgreSQL connection usage is above ${var.connection_threshold_percent}% of max_connections. Expected root cause: a client leaking connections."
      selector    = "sre_demo.postgres_connection_percent:${local.lab_filter}:max"
      dql         = "timeseries value = max(sre_demo.postgres_connection_percent), ${local.dql_lab}"
      condition   = "ABOVE"
      threshold   = var.connection_threshold_percent
      event_type  = "RESOURCE"
      violating   = 2
    }
    "05-postgres-connectivity" = {
      title       = "05 PostgreSQL dependency failures"
      description = "Repeated failures reaching PostgreSQL on TCP 5432 while the database service itself is healthy. Check NSG rules on the database subnet."
      selector    = "sre_demo.postgres_connectivity:${local.lab_filter}:min"
      dql         = "timeseries value = min(sre_demo.postgres_connectivity), ${local.dql_lab}"
      condition   = "BELOW"
      threshold   = 1
      event_type  = "ERROR"
      violating   = 2
    }
    "06-tls-certificate" = {
      title       = "06 Magic 8 Ball TLS validation failing"
      description = "Synthetic HTTPS checks against Magic 8 Ball fail TLS validation while pods remain healthy. Check server certificate validity dates."
      selector    = "sre_demo.magic8ball_tls_valid:${local.lab_filter}:min"
      dql         = "timeseries value = min(sre_demo.magic8ball_tls_valid), ${local.dql_lab}"
      condition   = "BELOW"
      threshold   = 1
      event_type  = "ERROR"
      violating   = 2
    }
  }
}

# ---------------------------------------------------------------------------
# Least-privilege tokens minted from the bootstrap token. Nothing downstream
# (apps, VMs, the AKS operator) ever sees the bootstrap token.
# ---------------------------------------------------------------------------

resource "dynatrace_api_token" "metrics_ingest" {
  name    = "sre-demo-${var.lab_suffix}-metrics-ingest"
  enabled = true
  scopes  = ["metrics.ingest"]
}

# Used by the OneAgent VM extension. It lands in the extension's *public*
# settings (that is how the Dynatrace extension is designed), so it is scoped
# to installer download only.
resource "dynatrace_api_token" "paas" {
  name    = "sre-demo-${var.lab_suffix}-oneagent-installer"
  enabled = true
  scopes  = ["InstallerDownload"]
}

resource "dynatrace_api_token" "operator" {
  name    = "sre-demo-${var.lab_suffix}-operator"
  enabled = true
  scopes = [
    "activeGateTokenManagement.create",
    "entities.read",
    "settings.read",
    "settings.write",
    "DataExport",
    "InstallerDownload",
  ]
}

resource "dynatrace_api_token" "operator_data_ingest" {
  name    = "sre-demo-${var.lab_suffix}-operator-ingest"
  enabled = true
  scopes  = ["metrics.ingest", "logs.ingest", "openTelemetryTrace.ingest"]
}

# ===========================================================================
# Classic environments (var.dynatrace_platform = false)
# ===========================================================================

# ---------------------------------------------------------------------------
# Metric events: Dynatrace's equivalent of alerts.bicep. Each raises a Davis
# problem whose title starts with local.title_prefix.
# ---------------------------------------------------------------------------

resource "dynatrace_metric_events" "lab" {
  for_each = var.dynatrace_platform ? {} : local.metric_events

  enabled = true
  summary = "${local.title_prefix} ${each.value.title}"

  event_template {
    title       = "${local.title_prefix} ${each.value.title}"
    description = "${each.value.description} Lab: ${var.lab_suffix}. Value: {severity}. Threshold: {threshold}."
    event_type  = each.value.event_type
    davis_merge = false

    metadata {
      metadata_key   = "sre.demo.scenario"
      metadata_value = each.key
    }
    metadata {
      metadata_key   = "sre.demo.lab"
      metadata_value = var.lab_suffix
    }
  }

  model_properties {
    type               = "STATIC_THRESHOLD"
    alert_condition    = each.value.condition
    alert_on_no_data   = false
    threshold          = each.value.threshold
    samples            = 3
    violating_samples  = each.value.violating
    dealerting_samples = 3
  }

  query_definition {
    type            = "METRIC_SELECTOR"
    metric_selector = each.value.selector
  }
}

# ---------------------------------------------------------------------------
# Problem routing: only this lab's problems go to ServiceNow.
# ---------------------------------------------------------------------------

resource "dynatrace_alerting" "lab" {
  count = var.dynatrace_platform ? 0 : 1

  name = "sre-demo-${var.lab_suffix}"

  rules {
    rule {
      include_mode     = "NONE"
      delay_in_minutes = 0
      severity_level   = "AVAILABILITY"
    }
    rule {
      include_mode     = "NONE"
      delay_in_minutes = 0
      severity_level   = "ERRORS"
    }
    rule {
      include_mode     = "NONE"
      delay_in_minutes = 0
      severity_level   = "PERFORMANCE"
    }
    rule {
      include_mode     = "NONE"
      delay_in_minutes = 0
      severity_level   = "RESOURCE_CONTENTION"
    }
    rule {
      include_mode     = "NONE"
      delay_in_minutes = 0
      severity_level   = "CUSTOM_ALERT"
    }
    rule {
      include_mode     = "NONE"
      delay_in_minutes = 0
      severity_level   = "MONITORING_UNAVAILABLE"
    }
  }

  filters {
    filter {
      custom {
        title {
          operator       = "BEGINS_WITH"
          value          = local.title_prefix
          case_sensitive = false
          negate         = false
          enabled        = true
        }
      }
    }
  }
}

locals {
  snow_basic_auth = "Basic ${base64encode("${var.integration_user}:${random_password.integration.result}")}"

  # ServiceNow Table API body. sysparm_input_display_value=true on the URL lets
  # assignment_group be given by name. correlation_id carries the Dynatrace
  # problem ID so reset-lab.sh and the SRE Agent can link the two records.
  # impact 2 + urgency 1 maps to priority 2 (High) in the default ServiceNow
  # priority lookup — the SRE Agent quickstart response plan only indexes High.
  # Dynatrace substitutes placeholders without JSON escaping, so multi-line
  # ones such as {ProblemDetailsText} would make the body invalid; the problem
  # URL carries the full detail instead.
  snow_incident_payload = <<-EOT
    {
      "short_description": "{ProblemTitle}",
      "description": "Dynatrace problem {PID} ({State}, severity {ProblemSeverity})\nImpacted: {ImpactedEntity}\nProblem: {ProblemURL}",
      "assignment_group": "${var.assignment_group}",
      "correlation_id": "dynatrace-{PID}",
      "correlation_display": "Dynatrace",
      "category": "software",
      "impact": "2",
      "urgency": "1",
      "work_notes": "Raised automatically by the Dynatrace problem notification sre-demo-${var.lab_suffix}. Tags: {Tags}"
    }
  EOT
}

moved {
  from = dynatrace_alerting.lab
  to   = dynatrace_alerting.lab[0]
}

resource "dynatrace_webhook_notification" "servicenow" {
  count = var.servicenow_enabled && !var.dynatrace_platform ? 1 : 0

  active                 = true
  name                   = "sre-demo-${var.lab_suffix}-servicenow"
  profile                = dynatrace_alerting.lab[0].id
  url                    = "${trimsuffix(var.servicenow_instance_url, "/")}/api/now/table/incident?sysparm_input_display_value=true"
  insecure               = false
  notify_closed_problems = false
  notify_event_merges    = false
  payload                = local.snow_incident_payload

  headers {
    header {
      name  = "Content-Type"
      value = "application/json"
    }
    header {
      name  = "Accept"
      value = "application/json"
    }
    header {
      name         = "Authorization"
      secret_value = local.snow_basic_auth
    }
  }

  depends_on = [
    restapi_object.integration_user_role,
    restapi_object.integration_user_group,
  ]
}
