terraform {
  required_version = ">= 1.6.0"

  required_providers {
    dynatrace = {
      source  = "dynatrace-oss/dynatrace"
      version = "~> 1.107"
    }
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Credentials come from the environment, never from variables or files:
#   DYNATRACE_ENV_URL   classic environment URL (https://<env>.live.dynatrace.com)
#   DYNATRACE_API_TOKEN bootstrap token (scopes in docs/DYNATRACE-SETUP.md)
# scripts/deploy.sh exports both from DT_ENV_URL / DT_API_TOKEN.
provider "dynatrace" {}

# ServiceNow Table API. The admin account is used only here, to create the
# assignment group and the least-privilege integration user that everything
# else (the Dynatrace webhook and the SRE Agent) uses.
provider "restapi" {
  uri                   = var.servicenow_enabled ? trimsuffix(var.servicenow_instance_url, "/") : "https://servicenow.invalid"
  username              = var.servicenow_admin_user
  password              = var.servicenow_admin_password
  write_returns_object  = true
  create_returns_object = true
  id_attribute          = "result/sys_id"
  update_method         = "PATCH"
  headers = {
    Accept       = "application/json"
    Content-Type = "application/json"
  }
}
