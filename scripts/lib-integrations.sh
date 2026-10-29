#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set here are consumed by the sourcing script
# -----------------------------------------------------------------------------
# lib-integrations.sh — Dynatrace and ServiceNow helpers shared by deploy.sh,
# validate.sh, reset-lab.sh and destroy-lab.sh. Source after lib.sh.
#
#   Dynatrace problem  --(webhook | workflow)-->  ServiceNow incident  --(poll)-->  SRE Agent
#                                                                              \--> Dynatrace MCP
#
# Two Dynatrace flavours are supported and detected automatically:
#   classic   metric events + alerting profile + problem-notification webhook
#   platform  (latest Dynatrace, no classic alerting) Davis anomaly detectors +
#             an AutomationEngine workflow; needs DT_PLATFORM_TOKEN
#
# Everything here is driven from .env / the environment:
#   DT_ENV_URL, DT_API_TOKEN, DT_PLATFORM_TOKEN
#   SNOW_INSTANCE_URL, SNOW_ADMIN_USER, SNOW_ADMIN_PASSWORD,
#   SNOW_ASSIGNMENT_GROUP, SNOW_INTEGRATION_USER
#
# Secrets are never placed on a command line: curl reads credentials from a
# config on stdin and kubectl reads tokens from 0600 temp files.
# -----------------------------------------------------------------------------

TF_INTEGRATION_DIR="${REPO_ROOT}/infra/terraform/integration"
DT_OPERATOR_VERSION="${DT_OPERATOR_VERSION:-v1.11.1}"
DT_OPERATOR_MANIFEST="https://github.com/Dynatrace/dynatrace-operator/releases/download/${DT_OPERATOR_VERSION}/kubernetes-csi.yaml"

DYNATRACE_ENABLED=false
SERVICENOW_ENABLED=false
DT_ENV_ID=""
DT_CLASSIC_URL=""
DT_APPS_URL=""
DT_PLATFORM_MODE=false

# Derives both URL forms from whichever one the operator supplied.
#   https://abc12345.apps.dynatrace.com      <-> https://abc12345.live.dynatrace.com
#   https://abc12345.sprint.apps.dynatracelabs.com <-> https://abc12345.sprint.dynatracelabs.com
dt_resolve_urls() {
  local url="${1%/}" host
  host="${url#https://}"; host="${host#http://}"; host="${host%%/*}"
  DT_ENV_ID="${host%%.*}"
  case "${host}" in
    *.apps.dynatrace.com)      DT_APPS_URL="https://${host}"; DT_CLASSIC_URL="https://${host/.apps.dynatrace.com/.live.dynatrace.com}" ;;
    *.live.dynatrace.com)      DT_CLASSIC_URL="https://${host}"; DT_APPS_URL="https://${host/.live.dynatrace.com/.apps.dynatrace.com}" ;;
    *.apps.dynatracelabs.com)  DT_APPS_URL="https://${host}"; DT_CLASSIC_URL="https://${host/.apps.dynatracelabs.com/.dynatracelabs.com}" ;;
    *.dynatracelabs.com)       DT_CLASSIC_URL="https://${host}"; DT_APPS_URL="https://${host/.dynatracelabs.com/.apps.dynatracelabs.com}" ;;
    *)                         DT_CLASSIC_URL="https://${host}"; DT_APPS_URL="https://${host}" ;;
  esac
}

# curl with credentials supplied through a config on stdin, never argv.
#   _curl_auth basic <user> <password> <curl args...>
#   _curl_auth header "<Header: value>" "" <curl args...>
_curl_auth() {
  local kind="$1" a="$2" b="$3"; shift 3
  local esc_a="${a//\\/\\\\}" esc_b="${b//\\/\\\\}"
  esc_a="${esc_a//\"/\\\"}"; esc_b="${esc_b//\"/\\\"}"
  if [[ "${kind}" == "basic" ]]; then
    printf 'user = "%s:%s"\n' "${esc_a}" "${esc_b}" | curl -K - "$@"
  else
    printf 'header = "%s"\n' "${esc_a}" | curl -K - "$@"
  fi
}

dt_api() {
  # dt_api <METHOD> <path> [curl args...]  -> body on stdout, HTTP code on last line
  local method="$1" path="$2"; shift 2
  _curl_auth header "Authorization: Api-Token ${DT_API_TOKEN}" "" \
    -sS --max-time 30 -X "${method}" -w '\n%{http_code}' \
    -H 'Content-Type: application/json' "$@" "${DT_CLASSIC_URL}${path}"
}

dt_platform_api() {
  # dt_platform_api <METHOD> <path> [curl args...]  -> body on stdout, HTTP code on last line
  local method="$1" path="$2"; shift 2
  _curl_auth header "Authorization: Bearer ${DT_PLATFORM_TOKEN}" "" \
    -sS --max-time 30 -X "${method}" -w '\n%{http_code}' \
    -H 'Content-Type: application/json' "$@" "${DT_APPS_URL}${path}"
}

# Latest-platform environments have no classic metric-event schema; that is
# the switch between the two alerting designs (see the header).
dt_detect_mode() {
  local code
  code="$(dt_api GET /api/v2/settings/schemas/builtin:anomaly-detection.metric-events 2>/dev/null | _http_code || true)"
  case "${code}" in
    200) DT_PLATFORM_MODE=false ;;
    404) DT_PLATFORM_MODE=true ;;
    *)   die "Could not read Dynatrace settings schemas (HTTP ${code:-none}); DT_API_TOKEN needs settings.read." ;;
  esac
}

# The workflow's JavaScript may only call hosts on the environment-wide
# outbound allowlist. Appends the ServiceNow host when the list is enforced;
# never removes entries (other labs or apps may rely on them).
dt_allow_outbound_host() {
  local host="$1" resp code body object_id enforced tmp
  resp="$(dt_api GET "/api/v2/settings/objects?schemaIds=builtin:dt-javascript-runtime.allowed-outbound-connections&scopes=environment&fields=objectId,value" 2>/dev/null || true)"
  code="$(printf '%s' "${resp}" | _http_code)"
  body="$(printf '%s' "${resp}" | _http_body)"
  [[ "${code}" == "200" ]] || die "Could not read the Dynatrace outbound-connection allowlist (HTTP ${code:-none})."
  object_id="$(jq -r '.items[0].objectId // empty' <<<"${body}")"
  enforced="$(jq -r '.items[0].value.allowedOutboundConnections.enforced // false' <<<"${body}")"
  if [[ -z "${object_id}" || "${enforced}" != "true" ]]; then
    ok "Dynatrace outbound connections are not restricted; ${host} is reachable from workflows"
    return 0
  fi
  if jq -e --arg h "${host}" '.items[0].value.allowedOutboundConnections.hostList // [] | index($h)' <<<"${body}" >/dev/null; then
    ok "Dynatrace outbound allowlist already contains ${host}"
    return 0
  fi
  tmp="$(mktemp)"; chmod 600 "${tmp}"
  jq -c --arg h "${host}" '.items[0].value | .allowedOutboundConnections.hostList = ((.allowedOutboundConnections.hostList // []) + [$h]) | {value: .}' <<<"${body}" > "${tmp}"
  code="$(dt_api PUT "/api/v2/settings/objects/${object_id}" --data-binary "@${tmp}" 2>/dev/null | _http_code || true)"
  rm -f "${tmp}"
  [[ "${code}" == "200" ]] || die "Could not add ${host} to the Dynatrace outbound allowlist (HTTP ${code:-none}). Add it in Settings > General > External requests."
  ok "Added ${host} to the Dynatrace outbound allowlist"
}

# Runs the ServiceNow workflow once with a non-lab problem title: the task
# loads, sees the title does not match and exits without calling ServiceNow.
# Catches the one-time AutomationEngine consent that only the actor can give.
# Permissions the workflow actor must grant under Workflows > Settings >
# Authorization settings; servicenow-incident.js needs every one of them.
DT_WORKFLOW_PERMISSIONS="automation:workflows:read, app-engine:functions:run, environment-api:credentials:read and storage:events:read"

dt_workflow_smoke_test() {
  local wf_id="$1" tmp resp code body exec_id state info i
  tmp="$(mktemp)"; chmod 600 "${tmp}"
  printf '%s' '{"params":{"event":{"event.name":"sre-demo deploy smoke test"}}}' > "${tmp}"
  resp="$(dt_platform_api POST "/platform/automation/v1/workflows/${wf_id}/run" --data-binary "@${tmp}" 2>/dev/null || true)"
  rm -f "${tmp}"
  code="$(printf '%s' "${resp}" | _http_code)"
  exec_id="$(printf '%s' "${resp}" | _http_body | jq -r '.id // empty' 2>/dev/null)"
  if [[ "${code}" != "201" && "${code}" != "200" || -z "${exec_id}" ]]; then
    warn "Could not start a test run of the ServiceNow workflow (HTTP ${code:-none}); check it in the Workflows app"
    return 1
  fi
  for i in $(seq 1 30); do
    state="$(dt_platform_api GET "/platform/automation/v1/executions/${exec_id}" 2>/dev/null | _http_body | jq -r '.state // empty' 2>/dev/null)"
    [[ "${state}" == "SUCCESS" || "${state}" == "ERROR" || "${state}" == "CANCELLED" ]] && break
    sleep 2
  done
  if [[ "${state}" == "SUCCESS" ]]; then
    ok "ServiceNow workflow test run succeeded"
    return 0
  fi
  body="$(dt_platform_api GET "/platform/automation/v1/executions/${exec_id}/tasks" 2>/dev/null | _http_body)"
  info="$(jq -r '[.[]?.stateInfo // empty] | first // empty' <<<"${body}" 2>/dev/null)"
  # "Authorization Settings": no consent at all. "403: Forbidden": consent given, but
  # without a permission the task uses (it reads its own execution first).
  if [[ "${info}" == *"Authorization Settings"* || "${info}" == *"403"* ]]; then
    if [[ "${info}" == *"403"* ]]; then
      warn "The ServiceNow workflow is missing a permission (${info}), so problems will NOT create ServiceNow incidents."
    else
      warn "Dynatrace has not been allowed to run workflows on your behalf yet, so problems will NOT create ServiceNow incidents."
    fi
    warn "  Fix: open ${DT_APPS_URL}/ui/apps/dynatrace.automations > Settings > Authorization settings,"
    warn "  enable at least ${DT_WORKFLOW_PERMISSIONS}, save,"
    warn "  then re-run this deploy with the same suffix (or scripts/validate.sh)."
  else
    warn "ServiceNow workflow test run ended in ${state:-unknown state}: ${info:-see the Workflows app execution ${exec_id}}"
  fi
  return 1
}

snow_api() {
  # snow_api <user> <password> <METHOD> <path> [curl args...]
  local user="$1" pass="$2" method="$3" path="$4"; shift 4
  _curl_auth basic "${user}" "${pass}" \
    -sS --max-time 30 -X "${method}" -w '\n%{http_code}' \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    "$@" "${SNOW_INSTANCE_URL%/}${path}"
}

_http_code() { tail -n1; }
_http_body() { sed '$d'; }

# Decides what is enabled, then checks reachability and credentials up front so
# a typo fails in seconds rather than after a 15 minute Bicep deployment.
integrations_preflight() {
  local skip_dt="$1" skip_snow="$2"
  SNOW_ASSIGNMENT_GROUP="${SNOW_ASSIGNMENT_GROUP:-SRE Demo Lab}"
  SNOW_INTEGRATION_USER="${SNOW_INTEGRATION_USER:-sre_demo_integration}"

  if [[ "${skip_dt}" == "true" || -z "${DT_ENV_URL:-}" ]]; then
    info "Dynatrace: disabled ($([[ "${skip_dt}" == "true" ]] && echo "--skip-dynatrace" || echo "DT_ENV_URL empty")) — Azure Monitor only"
  else
    [[ -n "${DT_API_TOKEN:-}" ]] || die "DT_ENV_URL is set but DT_API_TOKEN is not. See docs/DYNATRACE-SETUP.md."
    require_tool terraform "Install Terraform >= 1.6: https://developer.hashicorp.com/terraform/install"
    dt_resolve_urls "${DT_ENV_URL}"

    local resp code body scopes tmp missing=()
    # _curl_auth reads the credential from stdin, so the body goes via a file.
    tmp="$(mktemp)"; chmod 600 "${tmp}"
    jq -cn --arg t "${DT_API_TOKEN}" '{token:$t}' > "${tmp}"
    resp="$(dt_api POST /api/v2/apiTokens/lookup --data-binary "@${tmp}" 2>/dev/null || true)"
    rm -f "${tmp}"
    code="$(printf '%s' "${resp}" | _http_code)"
    body="$(printf '%s' "${resp}" | _http_body)"
    [[ "${code}" == "200" ]] || die "Dynatrace rejected DT_API_TOKEN at ${DT_CLASSIC_URL} (HTTP ${code:-none}). It needs at least apiTokens.read."
    scopes="$(printf '%s' "${body}" | jq -r '.scopes[]?' 2>/dev/null)"
    for s in apiTokens.read apiTokens.write settings.read settings.write; do
      grep -qx "${s}" <<<"${scopes}" || missing+=("${s}")
    done
    (( ${#missing[@]} == 0 )) || die "DT_API_TOKEN is missing scope(s): ${missing[*]}. See docs/DYNATRACE-SETUP.md."
    DYNATRACE_ENABLED=true
    ok "Dynatrace ${DT_ENV_ID}: token accepted (${DT_CLASSIC_URL})"

    dt_detect_mode
    if [[ "${DT_PLATFORM_MODE}" == "true" ]]; then
      [[ -n "${DT_PLATFORM_TOKEN:-}" ]] \
        || die "This Dynatrace environment is on the latest platform (no classic metric events). DT_PLATFORM_TOKEN is required to create the Davis anomaly detectors and the ServiceNow workflow. See docs/DYNATRACE-SETUP.md."
      code="$(dt_platform_api GET '/platform/automation/v1/workflows?limit=1' 2>/dev/null | _http_code || true)"
      [[ "${code}" == "200" ]] \
        || die "DT_PLATFORM_TOKEN cannot read workflows at ${DT_APPS_URL} (HTTP ${code:-none}); it needs the automation:workflows:* scopes in docs/DYNATRACE-SETUP.md."
      DT_API_SCOPES="${scopes}"
      DT_API_TOKEN_ID="$(jq -r '.id // empty' <<<"${body}")"
      ok "Dynatrace latest platform: Davis anomaly detectors + workflow (${DT_APPS_URL})"
    else
      ok "Dynatrace classic alerting: metric events + alerting profile + webhook"
    fi
  fi

  if [[ "${skip_snow}" == "true" || -z "${SNOW_INSTANCE_URL:-}" ]]; then
    info "ServiceNow: disabled (SNOW_INSTANCE_URL empty or --skip-servicenow)"
  elif [[ "${DYNATRACE_ENABLED}" != "true" ]]; then
    warn "ServiceNow is configured but Dynatrace is not; incidents are raised by Dynatrace, so ServiceNow is skipped"
  else
    [[ -n "${SNOW_ADMIN_USER:-}" && -n "${SNOW_ADMIN_PASSWORD:-}" ]] \
      || die "SNOW_INSTANCE_URL is set but SNOW_ADMIN_USER / SNOW_ADMIN_PASSWORD are not."
    local code
    code="$(snow_api "${SNOW_ADMIN_USER}" "${SNOW_ADMIN_PASSWORD}" GET \
      '/api/now/table/sys_user_role?sysparm_query=name%3Ditil&sysparm_fields=sys_id&sysparm_limit=1' 2>/dev/null | _http_code || true)"
    case "${code}" in
      200) ;;
      401) die "ServiceNow rejected SNOW_ADMIN_USER/SNOW_ADMIN_PASSWORD (HTTP 401)." ;;
      000|"") die "ServiceNow at ${SNOW_INSTANCE_URL} is unreachable. Developer instances hibernate — wake it at developer.servicenow.com." ;;
      *) die "ServiceNow returned HTTP ${code}. Is the instance awake and the admin user an admin?" ;;
    esac
    SERVICENOW_ENABLED=true
    ok "ServiceNow ${SNOW_INSTANCE_URL}: admin credentials accepted"

    # The platform workflow keeps the ServiceNow password in the credential vault.
    if [[ "${DT_PLATFORM_MODE}" == "true" ]]; then
      missing=()
      for s in credentialVault.read credentialVault.write; do
        grep -qx "${s}" <<<"${DT_API_SCOPES:-}" || missing+=("${s}")
      done
      if (( ${#missing[@]} > 0 )); then
        # apiTokens.write lets the token gain the scopes itself.
        local tmp
        tmp="$(mktemp)"; chmod 600 "${tmp}"
        printf '%s\n' ${DT_API_SCOPES} "${missing[@]}" | jq -Rnc '{scopes: [inputs | select(length > 0)]}' > "${tmp}"
        code="$(dt_api PUT "/api/v2/apiTokens/${DT_API_TOKEN_ID}" --data-binary "@${tmp}" 2>/dev/null | _http_code || true)"
        rm -f "${tmp}"
        [[ "${code}" == "200" || "${code}" == "204" ]] \
          || die "DT_API_TOKEN is missing scope(s) ${missing[*]}: on the latest platform the workflow reads the ServiceNow credentials from the Dynatrace credential vault. Add them in Access Tokens (automatic update failed, HTTP ${code:-none})."
        ok "Added ${missing[*]} to DT_API_TOKEN (ServiceNow credentials live in the Dynatrace credential vault)"
      fi
    fi
  fi
}

_tf() { terraform -chdir="${TF_INTEGRATION_DIR}" "$@"; }

_tf_env() {
  export DYNATRACE_ENV_URL="${DT_CLASSIC_URL}"
  export DYNATRACE_API_TOKEN="${DT_API_TOKEN}"
  export DYNATRACE_AUTOMATION_ENVIRONMENT_URL="${DT_APPS_URL}"
  if [[ -n "${DT_PLATFORM_TOKEN:-}" ]]; then
    export DYNATRACE_PLATFORM_TOKEN="${DT_PLATFORM_TOKEN}"
  fi
  export TF_VAR_dynatrace_platform="${DT_PLATFORM_MODE}"
  export TF_VAR_dynatrace_apps_url="${DT_APPS_URL}"
  export TF_VAR_lab_suffix="${SUFFIX}"
  export TF_VAR_servicenow_enabled="${SERVICENOW_ENABLED}"
  export TF_VAR_servicenow_instance_url="${SNOW_INSTANCE_URL:-}"
  export TF_VAR_servicenow_admin_user="${SNOW_ADMIN_USER:-}"
  export TF_VAR_servicenow_admin_password="${SNOW_ADMIN_PASSWORD:-}"
  export TF_VAR_assignment_group="${SNOW_ASSIGNMENT_GROUP}"
  export TF_VAR_integration_user="${SNOW_INTEGRATION_USER}"
  export TF_IN_AUTOMATION=1
}

# One Terraform workspace per lab suffix, so labs sharing a Dynatrace or
# ServiceNow tenant never touch each other's objects. State is local and
# git-ignored (infra/terraform/integration/terraform.tfstate.d/<suffix>/).
integrations_apply() {
  [[ "${DYNATRACE_ENABLED}" == "true" ]] || return 0
  _tf_env
  _tf init -input=false -no-color >/dev/null || die "terraform init failed in ${TF_INTEGRATION_DIR}"
  _tf workspace select -or-create "${SUFFIX}" >/dev/null || die "Could not select Terraform workspace ${SUFFIX}"
  if [[ "${DT_PLATFORM_MODE}" == "true" && "${SERVICENOW_ENABLED}" == "true" ]]; then
    local snow_host="${SNOW_INSTANCE_URL#https://}"
    dt_allow_outbound_host "${snow_host%%/*}"
  fi
  info "Applying Dynatrace$([[ "${SERVICENOW_ENABLED}" == "true" ]] && echo " + ServiceNow") configuration (workspace ${SUFFIX})"
  _tf apply -input=false -auto-approve -no-color >"${REPO_ROOT}/.secrets/terraform-${SUFFIX}.log" 2>&1 \
    || { tail -30 "${REPO_ROOT}/.secrets/terraform-${SUFFIX}.log"; die "terraform apply failed (full log: .secrets/terraform-${SUFFIX}.log)"; }

  DT_INGEST_TOKEN="$(_tf output -raw dynatrace_metrics_ingest_token)"
  DT_PAAS_TOKEN="$(_tf output -raw dynatrace_paas_token)"
  DT_OPERATOR_API_TOKEN="$(_tf output -raw dynatrace_operator_api_token)"
  DT_OPERATOR_INGEST_TOKEN="$(_tf output -raw dynatrace_operator_data_ingest_token)"
  DT_AKS_HOST_GROUP="$(_tf output -raw aks_host_group)"
  DT_VM_HOST_GROUP="$(_tf output -raw vm_host_group)"
  DT_TITLE_PREFIX="$(_tf output -raw problem_title_prefix)"
  SNOW_INTEGRATION_PASSWORD="$(_tf output -raw servicenow_integration_password)"
  SNOW_GROUP_SYS_ID="$(_tf output -raw servicenow_assignment_group_sys_id)"
  local rules routing
  rules="$(_tf output -json alert_rule_ids | jq 'length')"
  if [[ "${DT_PLATFORM_MODE}" == "true" ]]; then
    ok "Dynatrace: 4 scoped tokens, ${rules} Davis anomaly detectors titled ${DT_TITLE_PREFIX}"
    routing="workflow sre-demo-${SUFFIX}-servicenow"
  else
    ok "Dynatrace: 4 scoped tokens, ${rules} metric events, alerting profile ${DT_TITLE_PREFIX}"
    routing="problem-notification webhook"
  fi
  if [[ "${SERVICENOW_ENABLED}" == "true" ]]; then
    ok "ServiceNow: group '${SNOW_ASSIGNMENT_GROUP}' and itil user '${SNOW_INTEGRATION_USER}'; problems -> incidents via ${routing}"
    if [[ "${DT_PLATFORM_MODE}" == "true" ]]; then
      dt_workflow_smoke_test "$(_tf output -raw servicenow_workflow_id)" || true
    fi
  fi
}

integrations_destroy() {
  local suffix="$1"
  [[ -d "${TF_INTEGRATION_DIR}/terraform.tfstate.d/${suffix}" ]] || { info "No Dynatrace/ServiceNow state for ${suffix}"; return 0; }
  if [[ -z "${DT_ENV_URL:-}" || -z "${DT_API_TOKEN:-}" ]]; then
    warn "Terraform state exists for ${suffix} but DT_ENV_URL/DT_API_TOKEN are not set; Dynatrace/ServiceNow objects were NOT removed"
    return 0
  fi
  require_tool terraform
  dt_resolve_urls "${DT_ENV_URL}"
  dt_detect_mode
  SUFFIX="${suffix}"
  SERVICENOW_ENABLED=false
  [[ -n "${SNOW_INSTANCE_URL:-}" && -n "${SNOW_ADMIN_USER:-}" && -n "${SNOW_ADMIN_PASSWORD:-}" ]] && SERVICENOW_ENABLED=true
  SNOW_ASSIGNMENT_GROUP="${SNOW_ASSIGNMENT_GROUP:-SRE Demo Lab}"
  SNOW_INTEGRATION_USER="${SNOW_INTEGRATION_USER:-sre_demo_integration}"
  _tf_env
  _tf init -input=false -no-color >/dev/null
  _tf workspace select "${suffix}" >/dev/null
  if _tf destroy -input=false -auto-approve -no-color >/dev/null 2>&1; then
    _tf workspace select default >/dev/null
    _tf workspace delete "${suffix}" >/dev/null 2>&1 || true
    ok "Removed Dynatrace tokens/alerting/problem routing and ServiceNow objects for ${suffix}"
  else
    warn "terraform destroy failed for ${suffix}; re-run: terraform -chdir=infra/terraform/integration destroy (workspace ${suffix})"
  fi
}

# Installs the Dynatrace Operator (pinned release manifest, no Helm needed) and
# the lab DynaKube. Must run before the sre-demo workloads are created so their
# pods are injected on first start.
dynatrace_install_operator() {
  [[ "${DYNATRACE_ENABLED}" == "true" ]] || return 0
  info "Installing Dynatrace Operator ${DT_OPERATOR_VERSION}"
  kubectl create namespace dynatrace --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Server-side apply: the CRDs exceed the client-side last-applied annotation limit.
  kubectl apply --server-side --force-conflicts -f "${DT_OPERATOR_MANIFEST}" >/dev/null \
    || die "Could not apply ${DT_OPERATOR_MANIFEST}"
  kubectl -n dynatrace rollout status deployment/dynatrace-operator --timeout=300s >/dev/null \
    || die "dynatrace-operator did not become ready"
  kubectl -n dynatrace rollout status deployment/dynatrace-webhook --timeout=300s >/dev/null \
    || die "dynatrace-webhook did not become ready"

  local tokdir
  tokdir="$(mktemp -d)"; chmod 700 "${tokdir}"
  printf '%s' "${DT_OPERATOR_API_TOKEN}" > "${tokdir}/apiToken"
  printf '%s' "${DT_OPERATOR_INGEST_TOKEN}" > "${tokdir}/dataIngestToken"
  kubectl -n dynatrace create secret generic dynakube-sre-demo \
    --from-file=apiToken="${tokdir}/apiToken" --from-file=dataIngestToken="${tokdir}/dataIngestToken" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -rf "${tokdir}"

  # The webhook can report Ready a few seconds before it serves admission calls.
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if sed -e "s|__DT_API_URL__|${DT_CLASSIC_URL}/api|g" \
           -e "s|__DT_AKS_HOST_GROUP__|${DT_AKS_HOST_GROUP}|g" \
           -e "s|__LAB_SUFFIX__|${SUFFIX}|g" \
           "${REPO_ROOT}/k8s/dynatrace/dynakube.yaml" | kubectl apply -f - >/dev/null 2>&1; then
      break
    fi
    (( attempt == 6 )) && die "Could not apply the DynaKube"
    sleep 10
  done
  ok "Operator ready; DynaKube 'sre-demo' applied (host group ${DT_AKS_HOST_GROUP})"
}

dynatrace_wait_dynakube() {
  [[ "${DYNATRACE_ENABLED}" == "true" ]] || return 0
  info "Waiting for the DynaKube to reach Running (OneAgent + ActiveGate)..."
  if kubectl -n dynatrace wait dynakube/sre-demo --for=jsonpath='{.status.phase}'=Running --timeout=600s >/dev/null 2>&1; then
    ok "DynaKube Running"
  else
    warn "DynaKube is not Running yet: kubectl -n dynatrace get dynakube,pods"
  fi
}

# Closes every open incident Dynatrace raised for this lab. Used by reset-lab.sh
# so each demo run starts from an empty queue (notify_closed_problems is off,
# so ServiceNow incidents are not auto-resolved when a problem closes).
snow_resolve_lab_incidents() {
  local user="$1" pass="$2" group="${3:-${SNOW_ASSIGNMENT_GROUP:-SRE Demo Lab}}"
  local q resp code ids n=0
  q="assignment_group.name=${group}^active=true^correlation_idSTARTSWITHdynatrace-"
  q="$(jq -rn --arg q "${q}" '$q|@uri')"
  resp="$(snow_api "${user}" "${pass}" GET "/api/now/table/incident?sysparm_query=${q}&sysparm_fields=sys_id,number&sysparm_limit=200")"
  code="$(printf '%s' "${resp}" | _http_code)"
  [[ "${code}" == "200" ]] || { warn "ServiceNow incident query failed (HTTP ${code})"; return 0; }
  ids="$(printf '%s' "${resp}" | _http_body | jq -r '.result[].sys_id')"
  for id in ${ids}; do
    code="$(snow_api "${user}" "${pass}" PATCH "/api/now/table/incident/${id}" \
      --data '{"state":"6","close_code":"Resolved by caller","close_notes":"Lab reset (scripts/reset-lab.sh)."}' | _http_code)"
    [[ "${code}" == "200" ]] && n=$(( n + 1 ))
  done
  ok "Resolved ${n} open lab incident(s) in '${group}'"
}
