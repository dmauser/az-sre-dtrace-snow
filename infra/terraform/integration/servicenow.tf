# ServiceNow objects, provisioned through the Table API with the admin account
# from the environment. Everything after this (the Dynatrace webhook and the
# SRE Agent incident connector) authenticates as the integration user only.

resource "random_password" "integration" {
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

data "restapi_object" "itil_role" {
  count = var.servicenow_enabled ? 1 : 0

  path         = "/api/now/table/sys_user_role"
  query_string = "sysparm_query=name%3Ditil&sysparm_fields=sys_id,name"
  results_key  = "result"
  search_key   = "name"
  search_value = "itil"
  id_attribute = "sys_id"
}

resource "restapi_object" "assignment_group" {
  count = var.servicenow_enabled ? 1 : 0

  path = "/api/now/table/sys_user_group"
  data = jsonencode({
    name        = var.assignment_group
    description = "Incidents raised by Dynatrace for the Azure SRE Agent demo lab (${var.lab_suffix}). The SRE Agent is scoped to this group."
    active      = "true"
  })
  ignore_all_server_changes = true
}

resource "restapi_object" "integration_user" {
  count = var.servicenow_enabled ? 1 : 0

  path = "/api/now/table/sys_user"
  # input_display_value makes ServiceNow hash user_password on write instead of
  # storing the literal string.
  query_string = "sysparm_input_display_value=true"
  data = jsonencode({
    user_name               = var.integration_user
    first_name              = "SRE Demo"
    last_name               = "Integration"
    user_password           = random_password.integration.result
    web_service_access_only = "true"
    active                  = "true"
    password_needs_reset    = "false"
  })
  ignore_all_server_changes = true
}

resource "restapi_object" "integration_user_group" {
  count = var.servicenow_enabled ? 1 : 0

  path = "/api/now/table/sys_user_grmember"
  data = jsonencode({
    user  = restapi_object.integration_user[0].id
    group = restapi_object.assignment_group[0].id
  })
  ignore_all_server_changes = true
}

resource "restapi_object" "integration_user_role" {
  count = var.servicenow_enabled ? 1 : 0

  path = "/api/now/table/sys_user_has_role"
  data = jsonencode({
    user = restapi_object.integration_user[0].id
    role = data.restapi_object.itil_role[0].id
  })
  ignore_all_server_changes = true
}
