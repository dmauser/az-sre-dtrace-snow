variable "lab_suffix" {
  description = "Lab suffix. Scopes every Dynatrace object and metric filter to this lab, so several labs can share one Dynatrace environment."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.lab_suffix))
    error_message = "lab_suffix must be 3-12 lowercase letters or digits."
  }
}

variable "dynatrace_platform" {
  description = <<-EOT
    true  = latest Dynatrace platform: Davis anomaly detectors (DQL) raise the
            problems and an AutomationEngine workflow opens the ServiceNow incident.
            Needs DYNATRACE_PLATFORM_TOKEN.
    false = classic environment: metric events, an alerting profile and a
            problem-notification webhook.
    scripts/lib-integrations.sh detects which one the environment supports.
  EOT
  type        = bool
  default     = false
}

variable "dynatrace_apps_url" {
  description = "Platform UI URL (https://<env-id>.apps.dynatrace.com). Used for problem links in ServiceNow incidents."
  type        = string
  default     = ""
}

variable "servicenow_enabled" {
  description = "Create the ServiceNow objects and the Dynatrace -> ServiceNow problem routing (webhook or workflow)."
  type        = bool
  default     = true
}

variable "servicenow_instance_url" {
  description = "ServiceNow instance base URL, e.g. https://dev12345.service-now.com"
  type        = string
  default     = ""

  validation {
    condition     = var.servicenow_instance_url == "" || can(regex("^https://[^/]+/?$", var.servicenow_instance_url))
    error_message = "servicenow_instance_url must be an https:// base URL with no path."
  }
}

variable "servicenow_admin_user" {
  description = "ServiceNow admin used only to provision the group and the integration user."
  type        = string
  default     = ""
}

variable "servicenow_admin_password" {
  description = "Password for servicenow_admin_user. Supply via TF_VAR_servicenow_admin_password."
  type        = string
  default     = ""
  sensitive   = true
}

variable "assignment_group" {
  description = "ServiceNow assignment group that receives lab incidents and that the SRE Agent is scoped to."
  type        = string
  default     = "SRE Demo Lab"
}

variable "integration_user" {
  description = "user_name of the ServiceNow integration account (itil, web-service access only)."
  type        = string
  default     = "sre_demo_integration"
}

# Thresholds mirror infra/bicep/modules/alerts.bicep so both pipelines fire on
# the same conditions and can be compared side by side.
variable "disk_threshold_percent" {
  type    = number
  default = 85
}

variable "node_pressure_threshold_percent" {
  type    = number
  default = 80
}

variable "failure_rate_threshold_percent" {
  type    = number
  default = 20
}

variable "connection_threshold_percent" {
  type    = number
  default = 80
}
