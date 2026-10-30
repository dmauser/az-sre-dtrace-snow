#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# validate.sh — end-to-end health verification of a deployed lab.
#
# Prints PASS/FAIL for every check and exits non-zero if any fail, so it can be
# used as a gate in CI or before a customer demo.
# -----------------------------------------------------------------------------

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_env_file
require_core_tools

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

check() {
  local label="$1"; shift
  # lib.sh runs under `set -e`. Every call site below invokes check() as a bare
  # statement, so a non-zero return here would abort the whole script on the
  # first failed check instead of accumulating PASS/FAIL across every check as
  # documented at the top of this file. Always return 0; failures are recorded
  # in FAIL_COUNT and reflected in the final exit code instead.
  if "$@" >/dev/null 2>&1; then
    ok "${label}"; PASS_COUNT=$(( PASS_COUNT + 1 ))
  else
    fail "${label}"; FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  fi
  return 0
}

report() {
  local label="$1" passed="$2" detail="${3:-}"
  if [[ "${passed}" == "true" ]]; then
    ok "${label}${detail:+ — ${detail}}"; PASS_COUNT=$(( PASS_COUNT + 1 ))
  else
    fail "${label}${detail:+ — ${detail}}"; FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  fi
}

skip() {
  warn "SKIP ${1}"; SKIP_COUNT=$(( SKIP_COUNT + 1 ))
}

require_state
SUBSCRIPTION_ID="$(state_get subscriptionId)"
RESOURCE_GROUP="$(state_get resourceGroup)"
CONTROLLER_URL="$(state_get controllerUrl)"
MAGIC8BALL_URL="$(state_get magic8ballUrl)"
MAGIC8BALL_HTTPS_URL="$(state_get magic8ballHttpsUrl)"
AKS_NAME="$(state_get aksName)"
APP_VM_NAME="$(state_get appVmName)"
PG_VM_NAME="$(state_get postgresVmName)"
KUBECONFIG_PATH="$(state_get kubeconfig)"
APPI_NAME="$(state_get appInsightsName)"
LAW_ID="$(state_get logAnalyticsId)"

printf '\n%sAzure SRE Agent Demo Lab — validation%s\n' "${C_BOLD}" "${C_RESET}"
printf 'Resource group: %s\n' "${RESOURCE_GROUP}"

# --- Azure resources --------------------------------------------------------

step "Azure resources"
require_azure_login
az account set --subscription "${SUBSCRIPTION_ID}" 2>/dev/null || true

check "Resource group ${RESOURCE_GROUP} exists" az group show -n "${RESOURCE_GROUP}"

APP_VM_STATE="$(az vm get-instance-view -g "${RESOURCE_GROUP}" -n "${APP_VM_NAME}" \
  --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" -o tsv 2>/dev/null || echo unknown)"
report "App VM running" "$([[ "${APP_VM_STATE}" == "VM running" ]] && echo true || echo false)" "${APP_VM_STATE}"

PG_VM_STATE="$(az vm get-instance-view -g "${RESOURCE_GROUP}" -n "${PG_VM_NAME}" \
  --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" -o tsv 2>/dev/null || echo unknown)"
report "PostgreSQL VM running" "$([[ "${PG_VM_STATE}" == "VM running" ]] && echo true || echo false)" "${PG_VM_STATE}"

AKS_STATE="$(az aks show -g "${RESOURCE_GROUP}" -n "${AKS_NAME}" --query provisioningState -o tsv 2>/dev/null || echo unknown)"
report "AKS cluster provisioned" "$([[ "${AKS_STATE}" == "Succeeded" ]] && echo true || echo false)" "${AKS_STATE}"

# --- Scenario Controller ----------------------------------------------------

step "Scenario Controller"
CONTROLLER_HEALTH="$(curl -fsS --max-time 15 "${CONTROLLER_URL}/api/health" 2>/dev/null || echo '')"
report "Controller reachable" "$([[ -n "${CONTROLLER_HEALTH}" ]] && echo true || echo false)" "${CONTROLLER_URL}"

if [[ -n "${CONTROLLER_HEALTH}" ]]; then
  TELEMETRY_OK="$(echo "${CONTROLLER_HEALTH}" | jq -r '.telemetryConfigured // false')"
  report "Controller telemetry configured" "${TELEMETRY_OK}"

  LAB_STATUS="$(curl -fsS --max-time 25 "${CONTROLLER_URL}/api/lab/status" 2>/dev/null || echo '{}')"
  for component in "App VM" "PostgreSQL" "AKS" "Magic 8 Ball" "TLS"; do
    STATE_VALUE="$(echo "${LAB_STATUS}" | jq -r --arg n "${component}" '.components[]? | select(.name==$n) | .state // "UNKNOWN"')"
    DETAIL="$(echo "${LAB_STATUS}" | jq -r --arg n "${component}" '.components[]? | select(.name==$n) | .detail // ""')"
    report "${component} healthy" "$([[ "${STATE_VALUE}" == "HEALTHY" ]] && echo true || echo false)" "${STATE_VALUE}: ${DETAIL}"
  done

  SCENARIO_COUNT="$(curl -fsS --max-time 20 "${CONTROLLER_URL}/api/scenarios" 2>/dev/null | jq -r '.scenarios | length // 0')"
  report "All six scenario APIs available" "$([[ "${SCENARIO_COUNT}" == "6" ]] && echo true || echo false)" "${SCENARIO_COUNT} registered"

  # Needs no Dynatrace token: the controller reports its own last ingest result.
  # Without this, a wrong DT_API_URL (e.g. /api/api/v2 -> 404) drops every
  # sre_demo.* metric and no Dynatrace metric event can ever open a problem.
  if [[ "$(state_get dynatraceEnabled false)" == "true" ]]; then
    DT_INGEST="$(echo "${LAB_STATUS}" | jq -c '.telemetry.dynatraceIngest // null')"
    report "Controller metrics accepted by Dynatrace" \
      "$(echo "${DT_INGEST}" | jq -r '.ok // false')" \
      "$(echo "${DT_INGEST}" | jq -r 'if . == null then "no ingest attempt reported (sink not configured or not flushed yet)" else "HTTP \(.detail) at \(.at)" end')"
  fi
else
  skip "Component health checks (controller unreachable)"
fi

# --- Magic 8 Ball -----------------------------------------------------------

step "Magic 8 Ball"
check "HTTP health endpoint" curl -fsS --max-time 15 "${MAGIC8BALL_URL}/healthz"
check "Readiness endpoint" curl -fsS --max-time 15 "${MAGIC8BALL_URL}/readyz"

VERSION_JSON="$(curl -fsS --max-time 15 "${MAGIC8BALL_URL}/api/version" 2>/dev/null || echo '{}')"
VARIANT="$(echo "${VERSION_JSON}" | jq -r '.variant // "unknown"')"
report "Stable variant deployed" "$([[ "${VARIANT}" == "stable" ]] && echo true || echo false)" "variant=${VARIANT}"
report "Build metadata present" \
  "$([[ "$(echo "${VERSION_JSON}" | jq -r '.gitCommit // "unknown"')" != "unknown" ]] && echo true || echo false)" \
  "commit=$(echo "${VERSION_JSON}" | jq -r '.gitCommit // "unknown"')"

ANSWER="$(curl -fsS --max-time 20 -X POST "${MAGIC8BALL_URL}/api/answer" \
  -H 'content-type: application/json' -d '{"question":"is the lab healthy?"}' 2>/dev/null || echo '{}')"
report "Answer API returns a result" \
  "$([[ -n "$(echo "${ANSWER}" | jq -r '.answer // empty')" ]] && echo true || echo false)" \
  "$(echo "${ANSWER}" | jq -r '.answer // "no answer"')"
report "Answer persisted to PostgreSQL" "$(echo "${ANSWER}" | jq -r '.persisted // false')"

# TLS must validate against the demo CA specifically, which is what proves the
# certificate scenario will fail for the right reason later.
step "TLS"
CERT_DIR="${REPO_ROOT}/certs"
if [[ -f "${CERT_DIR}/ca.crt" ]]; then
  # The demo CA publishes no revocation endpoint. Schannel curl (Git Bash on
  # Windows) fails closed on that unless revocation checks are turned off.
  TLS_REVOKE_OPT=()
  curl -V 2>/dev/null | grep -qi schannel && TLS_REVOKE_OPT=(--ssl-no-revoke)
  if curl -fsS --max-time 15 ${TLS_REVOKE_OPT[@]+"${TLS_REVOKE_OPT[@]}"} --cacert "${CERT_DIR}/ca.crt" \
       --resolve "magic8ball.sre-demo.local:443:$(state_get magic8ballIp)" \
       "https://magic8ball.sre-demo.local/healthz" >/dev/null 2>&1; then
    report "HTTPS validates against the demo CA" true
  elif curl -fsSk --max-time 15 "${MAGIC8BALL_HTTPS_URL}/healthz" >/dev/null 2>&1; then
    report "HTTPS validates against the demo CA" false "handshake works but validation failed — check certificate dates"
  else
    report "HTTPS endpoint reachable" false "no TLS response"
  fi

  NOT_AFTER="$(echo | openssl s_client -connect "$(state_get magic8ballIp):443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo unknown)"
  report "Served certificate is currently valid" \
    "$([[ "${NOT_AFTER}" != "unknown" ]] && date -d "${NOT_AFTER}" +%s >/dev/null 2>&1 && \
       [[ "$(date -d "${NOT_AFTER}" +%s)" -gt "$(date +%s)" ]] && echo true || echo false)" \
    "notAfter=${NOT_AFTER}"
else
  skip "TLS validation (certs/ca.crt not present locally)"
fi

# --- Kubernetes -------------------------------------------------------------

step "Kubernetes"
if command -v kubectl >/dev/null 2>&1 || [[ -x "${HOME}/.local/bin/kubectl" ]]; then
  require_kubectl
  export KUBECONFIG="${KUBECONFIG_PATH}"
  if kubectl cluster-info >/dev/null 2>&1; then
    report "AKS API reachable" true

    READY_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || echo 0)"
    report "AKS nodes Ready" "$([[ "${READY_NODES}" -ge 1 ]] && echo true || echo false)" "${READY_NODES} node(s)"

    M8_READY="$(kubectl -n sre-demo get deploy magic8ball -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    report "Magic 8 Ball pods ready" "$([[ "${M8_READY:-0}" -ge 1 ]] && echo true || echo false)" "${M8_READY:-0} ready"

    RUNNER_READY="$(kubectl -n sre-demo get deploy scenario-runner -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    report "scenario-runner ready" "$([[ "${RUNNER_READY:-0}" -ge 1 ]] && echo true || echo false)" "${RUNNER_READY:-0} ready"

    PENDING="$(kubectl -n sre-demo get pods --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    report "No pods pending at baseline" "$([[ "${PENDING}" == "0" ]] && echo true || echo false)" "${PENDING} pending"

    BURNER="$(kubectl -n sre-demo get deploy resource-burner -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    report "Resource pressure workload idle" "$([[ "${BURNER:-0}" == "0" ]] && echo true || echo false)" "${BURNER:-0} replicas"
  else
    report "AKS API reachable" false "kubeconfig ${KUBECONFIG_PATH}"
  fi
else
  skip "Kubernetes checks (kubectl unavailable)"
fi

# --- Networking -------------------------------------------------------------

step "Networking"
DENY_RULE="$(az network nsg rule show -g "${RESOURCE_GROUP}" \
  --nsg-name "$(state_get databaseNsgName)" -n sre-demo-deny-postgres --query name -o tsv 2>/dev/null || echo '')"
report "No scenario NSG deny rule present" "$([[ -z "${DENY_RULE}" ]] && echo true || echo false)" \
  "${DENY_RULE:-none}"

PG_PUBLIC_IP="$(az vm list-ip-addresses -g "${RESOURCE_GROUP}" -n "${PG_VM_NAME}" \
  --query "[0].virtualMachine.network.publicIpAddresses | length(@)" -o tsv 2>/dev/null || echo 0)"
report "PostgreSQL has no public IP" "$([[ "${PG_PUBLIC_IP}" == "0" ]] && echo true || echo false)"

# --- Telemetry --------------------------------------------------------------

step "Telemetry"
LAW_GUID="$(az monitor log-analytics workspace show -g "${RESOURCE_GROUP}" \
  -n "$(state_get logAnalyticsName)" --query customerId -o tsv 2>/dev/null || true)"

if [[ -n "${LAW_GUID}" ]]; then
  # The REST API rather than `az monitor log-analytics query`: the CLI extension
  # loads slowly enough to exceed any sensible timeout, which previously made
  # healthy telemetry look like a failure.
  #
  # KQL string literals below must be SINGLE quoted. The query is embedded in a
  # JSON body, so a double quote would close the JSON string and produce a
  # malformed request that also reads as "no telemetry".
  la_count() {
    timeout 45 az rest --method post \
      --url "https://api.loganalytics.io/v1/workspaces/${LAW_GUID}/query" \
      --resource "https://api.loganalytics.io" \
      --body "{\"query\":\"$1\"}" -o json 2>/dev/null \
      | jq -r '.tables[0].rows[0][0] // 0' 2>/dev/null || echo 0
  }

  ROWS="$(la_count 'union isfuzzy=true AppMetrics, AppRequests, AppDependencies | where TimeGenerated > ago(30m) | count')"
  report "Application telemetry reaching Log Analytics" \
    "$([[ "${ROWS}" != "0" ]] && echo true || echo false)" \
    "${ROWS} row(s) in the last 30 minutes (allow 5-10 min after deployment)"

  CUSTOM="$(la_count "AppMetrics | where TimeGenerated > ago(30m) | where Name startswith 'sre_demo_' | count")"
  report "Custom sre_demo_ metrics present" \
    "$([[ "${CUSTOM}" != "0" ]] && echo true || echo false)" "${CUSTOM} row(s)"

  CROWS="$(la_count "KubePodInventory | where TimeGenerated > ago(30m) | where Namespace == 'sre-demo' | count")"
  report "Container Insights collecting AKS data" \
    "$([[ "${CROWS}" != "0" ]] && echo true || echo false)" \
    "${CROWS} row(s) (Container Insights can take 10-15 min on a new cluster)"
else
  skip "Log Analytics queries (workspace unknown)"
fi

ALERT_COUNT="$(az rest --method get --url "https://management.azure.com/subscriptions/$(state_get subscriptionId)/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Insights/scheduledQueryRules?api-version=2022-06-15" -o json 2>/dev/null | jq -r ".value | length" 2>/dev/null || echo 0)"
report "Azure Monitor alert rules created" "$([[ "${ALERT_COUNT}" -ge 6 ]] && echo true || echo false)" "${ALERT_COUNT} rule(s)"

# --- Dynatrace --------------------------------------------------------------

if [[ "$(state_get dynatraceEnabled false)" == "true" ]]; then
  step "Dynatrace"
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-integrations.sh"
  dt_resolve_urls "$(state_get dynatraceApiUrl)"
  DT_PREFIX="$(state_get dynatraceProblemTitlePrefix)"

  if command -v kubectl >/dev/null 2>&1 && [[ -f "${KUBECONFIG_PATH}" ]]; then
    DK_PHASE="$(KUBECONFIG="${KUBECONFIG_PATH}" kubectl -n dynatrace get dynakube sre-demo \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    report "DynaKube sre-demo Running" "$([[ "${DK_PHASE}" == "Running" ]] && echo true || echo false)" "${DK_PHASE:-not found}"
  else
    skip "DynaKube phase (kubectl unavailable)"
  fi

  if [[ -z "${DT_API_TOKEN:-}" ]]; then
    skip "Dynatrace API checks (DT_API_TOKEN not set in .env)"
  else
    # Optional scopes: metrics.read, entities.read. A 403 is a SKIP, not a FAIL.
    dt_check() {
      local label="$1" path="$2" jqexpr="$3" min="$4" hint="$5" resp code n
      resp="$(dt_api GET "${path}" 2>/dev/null || true)"
      code="$(printf '%s' "${resp}" | _http_code)"
      if [[ "${code}" == "403" ]]; then skip "${label} (DT_API_TOKEN lacks the scope)"; return 0; fi
      n="$(printf '%s' "${resp}" | _http_body | jq -r "${jqexpr}" 2>/dev/null || echo 0)"
      report "${label}" "$([[ "${code}" == "200" && "${n:-0}" -ge "${min}" ]] && echo true || echo false)" \
        "${n:-0} found (HTTP ${code:-none})${hint:+; ${hint}}"
    }
    dt_detect_mode
    if [[ "${DT_PLATFORM_MODE}" == "true" ]]; then
      dt_check "Davis anomaly detectors for ${DT_PREFIX}" \
        "/api/v2/settings/objects?schemaIds=builtin:davis.anomaly-detectors&fields=value&pageSize=500" \
        "[.items[] | select((.value.title // \"\") | startswith(\"${DT_PREFIX}\"))] | length" 8 ""
      if [[ "$(state_get servicenowEnabled false)" == "true" && -z "${DT_PLATFORM_TOKEN:-}" ]]; then
        skip "ServiceNow workflow test run (DT_PLATFORM_TOKEN not set in .env)"
      elif [[ "$(state_get servicenowEnabled false)" == "true" ]]; then
        # "[sre-demo-<suffix>]" -> workflow "sre-demo-<suffix>-servicenow"
        WF_TITLE="${DT_PREFIX#[}"; WF_TITLE="${WF_TITLE%]}-servicenow"
        WF_ID="$(dt_platform_api GET "/platform/automation/v1/workflows?search=${WF_TITLE}" 2>/dev/null | _http_body \
          | jq -r --arg t "${WF_TITLE}" '[.results[]? | select(.title == $t)][0].id // empty' 2>/dev/null)"
        if [[ -z "${WF_ID}" ]]; then
          report "Dynatrace workflow ${WF_TITLE} exists" false "re-run deploy with the same suffix"
        elif dt_workflow_smoke_test "${WF_ID}"; then
          report "Dynatrace workflow ${WF_TITLE} runs" true
        else
          report "Dynatrace workflow ${WF_TITLE} runs" false "see the warning above"
        fi
      fi
    else
      dt_check "Metric events for ${DT_PREFIX}" \
        "/api/v2/settings/objects?schemaIds=builtin:anomaly-detection.metric-events&fields=value&pageSize=500" \
        "[.items[] | select((.value.eventTemplate.title // \"\") | startswith(\"${DT_PREFIX}\"))] | length" 8 ""
    fi
    dt_check "Custom sre_demo.* metrics reaching Dynatrace" \
      "/api/v2/metrics?metricSelector=sre_demo.*&writtenSince=now-30m&fields=metricId" \
      ".totalCount // 0" 1 "allow 5 min after deployment"
    for hg in "$(state_get dynatraceAksHostGroup)" "$(state_get dynatraceVmHostGroup)"; do
      [[ -n "${hg}" ]] || continue
      sel="$(jq -rn --arg s "type(HOST),hostGroupName(\"${hg}\")" '$s|@uri')"
      dt_check "OneAgent hosts in ${hg}" "/api/v2/entities?entitySelector=${sel}&from=now-30m" \
        ".totalCount // 0" 1 "OneAgent hosts appear 5-10 min after install"
    done
  fi
fi

# --- ServiceNow -------------------------------------------------------------

if [[ "$(state_get servicenowEnabled false)" == "true" ]]; then
  step "ServiceNow"
  # shellcheck disable=SC2034  # read by snow_api (lib-integrations.sh)
  SNOW_INSTANCE_URL="$(state_get servicenowInstanceUrl)"
  SNOW_USER="$(state_get servicenowIntegrationUser)"
  SNOW_GROUP="$(state_get servicenowAssignmentGroup)"
  SNOW_PW="$(snow_integration_password "$(state_get suffix)" "$(state_get keyVaultName)" "${SUBSCRIPTION_ID}")"
  if [[ -z "${SNOW_PW}" ]]; then
    report "Integration user password readable" false "not in Terraform state or Key Vault (servicenow-integration-password)"
  else
    q="$(jq -rn --arg g "${SNOW_GROUP}" '"name=\($g)" | @uri')"
    resp="$(snow_api "${SNOW_USER}" "${SNOW_PW}" GET "/api/now/table/sys_user_group?sysparm_query=${q}&sysparm_fields=sys_id" 2>/dev/null || true)"
    code="$(printf '%s' "${resp}" | _http_code)"
    n="$(printf '%s' "${resp}" | _http_body | jq -r '.result | length' 2>/dev/null || echo 0)"
    report "ServiceNow login as ${SNOW_USER}" "$([[ "${code}" == "200" ]] && echo true || echo false)" \
      "HTTP ${code:-none}$([[ "${code:-000}" == "000" ]] && echo '; developer instances hibernate')"
    report "Assignment group '${SNOW_GROUP}' exists" "$([[ "${n:-0}" -ge 1 ]] && echo true || echo false)"
  fi
fi

# --- Azure SRE Agent --------------------------------------------------------

AGENT_NAME="$(state_get sreAgentName)"
if [[ -n "${AGENT_NAME}" && ( "$(state_get dynatraceEnabled false)" == "true" || "$(state_get servicenowEnabled false)" == "true" ) ]]; then
  step "Azure SRE Agent integrations"
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-integrations.sh"
  if ! sre_dp_init "$(state_get sreAgentEndpoint)" "${SUBSCRIPTION_ID}"; then
    report "Agent ${AGENT_NAME} data plane reachable" false "no endpoint or token"
  else
    if [[ "$(state_get dynatraceEnabled false)" == "true" ]]; then
      body="$(sre_dp GET /api/v2/extendedAgent/connectors/dynatrace-mcp/tools | _http_body)"
      st="$(jq -r '.connectionStatus // "missing"' 2>/dev/null <<<"${body}" || echo missing)"
      nt="$(jq -r '.tools | length' 2>/dev/null <<<"${body}" || echo 0)"
      report "Agent connected to Dynatrace MCP" "$([[ "${st}" == "Connected" && "${nt:-0}" -gt 0 ]] && echo true || echo false)" \
        "${st}, ${nt:-0} tools; fix with ./scripts/configure-sre-agent-integrations.sh"
      conn="$(sre_dp GET /api/v2/extendedAgent/connectors/dynatrace-mcp | _http_body)"
      vt="$(jq -r '.properties.extendedProperties.toolsVisibleToMetaAgent | length' 2>/dev/null <<<"${conn}" || echo 0)"
      report "Dynatrace tools exposed to the agent (chat and investigations)" "$([[ "${vt:-0}" -gt 0 ]] && echo true || echo false)" \
        "${vt:-0} tools selected; without them the agent cannot query Dynatrace. Fix with ./scripts/configure-sre-agent-integrations.sh"
      pt="$(jq -r '.properties.extendedProperties.partnerType // "none"' 2>/dev/null <<<"${conn}" || echo none)"
      report "Dynatrace connector is the built-in Dynatrace type" "$([[ "${pt}" == "DynatraceMcp" ]] && echo true || echo false)" \
        "partnerType ${pt}; fix with ./scripts/configure-sre-agent-integrations.sh"
    fi
    if [[ -n "${GITHUB_REPO:-}" ]]; then
      gh_name="${GITHUB_REPO%.git}"; gh_name="${gh_name##*/}"
      body="$(sre_dp GET /api/v2/repos | _http_body)"
      report "Agent has code repository ${gh_name}" \
        "$(jq -e --arg n "${gh_name}" '[.value[]? | select(.name == $n)] | length > 0' >/dev/null 2>&1 <<<"${body}" && echo true || echo false)" \
        "fix with ./scripts/configure-sre-agent-integrations.sh"
      # Reading a private repo needs a credential only a human can grant (OAuth)
      # or supply (GITHUB_PAT), so missing access is a skip, not a failure.
      body="$(sre_dp POST "/api/v2/repos/${gh_name}/test" | _http_body)"
      if jq -e '.isSuccessful == true' >/dev/null 2>&1 <<<"${body}"; then
        report "Agent can read ${GITHUB_REPO}" true
      else
        skip "Agent cannot read ${GITHUB_REPO} yet; authorize GitHub (docs/AZURE-SRE-AGENT-SETUP.md section 2)"
      fi
    fi
    if [[ "$(state_get servicenowEnabled false)" == "true" ]]; then
      body="$(sre_dp GET /api/v2/incidentManagement/checkConnectivityDetailed | _http_body)"
      report "Agent connected to ServiceNow" \
        "$(jq -e '.success == true and .incidentType == "ServiceNow"' >/dev/null 2>&1 <<<"${body}" && echo true || echo false)" \
        "$(jq -r '.errorMessage // .observedConnectionStatus // "not configured"' 2>/dev/null <<<"${body}" || echo 'not configured')"
      body="$(sre_dp GET /api/v2/incidentManagement/incidentFilters | _http_body)"
      report "ServiceNow response plan enabled" \
        "$(jq -e '[.value[]? | select(.properties.incidentPlatform == "ServiceNow" and .properties.isEnabled == true)] | length > 0' >/dev/null 2>&1 <<<"${body}" && echo true || echo false)"
    fi
  fi
fi

# --- Summary ----------------------------------------------------------------

printf '\n%s%s%s\n' "${C_BOLD}" "----------------------------------------" "${C_RESET}"
printf '%sPASS%s %d   %sFAIL%s %d   %sSKIP%s %d\n' \
  "${C_GREEN}" "${C_RESET}" "${PASS_COUNT}" \
  "${C_RED}" "${C_RESET}" "${FAIL_COUNT}" \
  "${C_YELLOW}" "${C_RESET}" "${SKIP_COUNT}"

if (( FAIL_COUNT > 0 )); then
  printf '\n%sValidation failed.%s See docs/TROUBLESHOOTING.md.\n' "${C_RED}" "${C_RESET}"
  exit 1
fi
printf '\n%sLab is healthy and ready to demonstrate.%s\n' "${C_GREEN}" "${C_RESET}"
