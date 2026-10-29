#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set here are consumed by the sourcing script
# -----------------------------------------------------------------------------
# lib-integrations.sh — Dynatrace and ServiceNow helpers shared by deploy.sh,
# validate.sh, reset-lab.sh and destroy-lab.sh. Source after lib.sh.
#
#   Dynatrace problem  --(webhook)-->  ServiceNow incident  --(poll)-->  SRE Agent
#                                                                   \--> Dynatrace MCP
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
  fi
}

_tf() { terraform -chdir="${TF_INTEGRATION_DIR}" "$@"; }

_tf_env() {
  export DYNATRACE_ENV_URL="${DT_CLASSIC_URL}"
  export DYNATRACE_API_TOKEN="${DT_API_TOKEN}"
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
  ok "Dynatrace: 4 scoped tokens, $(_tf output -json metric_event_ids | jq 'length') metric events, alerting profile ${DT_TITLE_PREFIX}"
  if [[ "${SERVICENOW_ENABLED}" == "true" ]]; then
    ok "ServiceNow: group '${SNOW_ASSIGNMENT_GROUP}' and itil user '${SNOW_INTEGRATION_USER}'; problems -> incidents webhook active"
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
    ok "Removed Dynatrace tokens/metric events/webhook and ServiceNow objects for ${suffix}"
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
