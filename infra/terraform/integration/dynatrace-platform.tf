# ===========================================================================
# Latest Dynatrace platform (var.dynatrace_platform = true)
#
# These environments have no classic metric events, alerting profiles or
# problem-notification webhooks. The same contract is built from:
#   Davis anomaly detectors (DQL)  -> Davis problem titled "<title_prefix> ..."
#   AutomationEngine workflow      -> ServiceNow incident (same fields as the
#                                     classic webhook payload)
# The workflow's JavaScript reaches ServiceNow through the environment's
# outbound-connection allowlist, which scripts/lib-integrations.sh maintains
# (it is an environment-wide singleton, so Terraform does not own it).
# ===========================================================================

locals {
  platform_servicenow = var.dynatrace_platform && var.servicenow_enabled
  workflow_name       = "sre-demo-${var.lab_suffix}-servicenow"
}

resource "dynatrace_davis_anomaly_detectors" "lab" {
  for_each = var.dynatrace_platform ? local.metric_events : {}

  enabled     = true
  title       = "${local.title_prefix} ${each.value.title}"
  description = "${each.value.description} Lab: ${var.lab_suffix}."
  source      = "sre-demo-lab (Terraform)"

  analyzer {
    name = "dt.statistics.ui.anomaly_detection.StaticThresholdAnomalyDetectionAnalyzer"
    input {
      analyzer_input_field {
        key   = "query"
        value = each.value.dql
      }
      analyzer_input_field {
        key   = "threshold"
        value = tostring(each.value.threshold)
      }
      analyzer_input_field {
        key   = "alertCondition"
        value = each.value.condition
      }
      analyzer_input_field {
        key   = "alertOnMissingData"
        value = "false"
      }
      analyzer_input_field {
        key   = "slidingWindow"
        value = "3"
      }
      analyzer_input_field {
        key   = "violatingSamples"
        value = tostring(each.value.violating)
      }
      analyzer_input_field {
        key   = "dealertingSamples"
        value = "3"
      }
    }
  }

  event_template {
    properties {
      property {
        key   = "event.type"
        value = local.davis_event_type[each.value.event_type]
      }
      property {
        key   = "event.name"
        value = "${local.title_prefix} ${each.value.title}"
      }
      property {
        key   = "event.description"
        value = "${each.value.description} Lab: ${var.lab_suffix}."
      }
      property {
        key   = "sre.demo.scenario"
        value = each.key
      }
      property {
        key   = "sre.demo.lab"
        value = var.lab_suffix
      }
      # Host-scoped detectors attach the problem to the affected AKS node.
      dynamic "property" {
        for_each = strcontains(each.value.dql, "dt.entity.host") ? [1] : []
        content {
          key   = "dt.source_entity"
          value = "{dims:dt.entity.host}"
        }
      }
    }
  }

  # Queries run as the user who owns DYNATRACE_PLATFORM_TOKEN.
  execution_settings {}
}

# The workflow reads these at run time; only the token owner can use them.
# allow_contextless_requests is required: a problem-triggered (Event) run has no
# user context, so without it getCredentialsDetails returns 403 "cannot be
# accessed by the current user or entity". Manual runs (and the deploy smoke
# test) carry a user context, so they never expose the problem.
resource "dynatrace_credentials" "servicenow" {
  count = local.platform_servicenow ? 1 : 0

  name              = local.workflow_name
  description       = "ServiceNow integration user for the ${local.workflow_name} workflow (SRE demo lab ${var.lab_suffix})."
  username          = var.integration_user
  password          = random_password.integration.result
  scopes            = ["APP_ENGINE"]
  owner_access_only = true

  allow_contextless_requests = true

  depends_on = [
    restapi_object.integration_user_role,
    restapi_object.integration_user_group,
  ]
}

locals {
  workflow_script = replace(
    replace(file("${path.module}/workflow/servicenow-incident.js"), "\r", ""),
    "__CONFIG__",
    jsonencode({
      titlePrefix     = local.title_prefix
      credentialId    = local.platform_servicenow ? dynatrace_credentials.servicenow[0].id : ""
      instanceUrl     = trimsuffix(var.servicenow_instance_url, "/")
      appsUrl         = trimsuffix(var.dynatrace_apps_url, "/")
      assignmentGroup = var.assignment_group
      workflowName    = local.workflow_name
    })
  )
}

resource "dynatrace_automation_workflow" "servicenow" {
  count = local.platform_servicenow ? 1 : 0

  title       = local.workflow_name
  description = "Opens a priority-2 ServiceNow incident (group ${var.assignment_group}) for every Davis problem titled ${local.title_prefix}, and resolves it when the problem closes. Managed by Terraform (SRE demo lab)."
  is_deployed = true

  tasks {
    task {
      name        = "create_incident"
      description = "Create the ServiceNow incident on open (once per correlation_id); resolve it on close"
      action      = "dynatrace.automations:run-javascript"
      input       = jsonencode({ script = local.workflow_script })
      position {
        x = 0
        y = 1
      }
    }
  }

  trigger {
    event {
      active = true
      config {
        davis_problem {
          # open-and-close: the script creates the incident on open and resolves it on close.
          trigger_on    = "open-and-close"
          custom_filter = "matchesValue(event.name, \"${local.title_prefix}*\")"
          categories {
            availability           = true
            error                  = true
            slowdown               = true
            resource               = true
            custom                 = true
            monitoring_unavailable = true
            info                   = false
          }
        }
      }
    }
  }
}
