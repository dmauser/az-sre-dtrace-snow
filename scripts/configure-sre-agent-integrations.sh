#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# configure-sre-agent-integrations.sh — connects the lab's Azure SRE Agent to
# Dynatrace (MCP connector) and the ServiceNow incident platform.
#
#   ./scripts/configure-sre-agent-integrations.sh [--show-password]
#
# Dynatrace: creates the "dynatrace-mcp" connector on the agent through ARM
#   (Microsoft.App/agents/connectors), using DT_PLATFORM_TOKEN from .env as the
#   bearer token for the Dynatrace remote MCP server. Idempotent (PUT).
#
# ServiceNow: sets the agent's incident platform to ServiceNow (ARM PATCH of
#   incidentManagementConfiguration with the integration user's basic-auth
#   credentials), waits for the agent to connect, scopes incident indexing to
#   the lab's assignment group, and creates a response plan that hands the
#   lab's incidents to the agent. These are the same calls the portal makes.
#   If any step fails it prints the portal steps instead; the password is then
#   in .secrets/ (mode 0600) unless --show-password is given.
#
# GitHub: registers GITHUB_REPO (owner/name) as a code repository on the agent
#   (Builder > Code access). For a private repo the agent also needs a GitHub
#   credential: GITHUB_PAT (fine-grained, this repo only, Contents + Metadata
#   read-only) is stored on the agent when set; otherwise authorize GitHub once
#   in the portal (OAuth), as the script prints.
# -----------------------------------------------------------------------------

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-integrations.sh"

SHOW_PASSWORD=false
CONNECTOR_API_VERSION="${SRE_AGENT_CONNECTOR_API_VERSION:-2025-05-01-preview}"
DT_CONNECTOR_NAME="dynatrace-mcp"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show-password) SHOW_PASSWORD=true; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

require_core_tools
require_state
load_env_file

SUFFIX="$(state_get suffix)"
SUBSCRIPTION_ID="$(state_get subscriptionId)"
RESOURCE_GROUP="$(state_get resourceGroup)"
AGENT_NAME="$(state_get sreAgentName)"
AGENT_ENDPOINT="$(state_get sreAgentEndpoint)"
KEY_VAULT_NAME="$(state_get keyVaultName)"

[[ -n "${AGENT_NAME}" ]] || die "This lab has no SRE Agent. Redeploy with --with-agent, or connect your own agent by following docs/SERVICENOW-SETUP.md."

# The agent's data plane verifies each integration from the agent's side.
DP_READY=true
sre_dp_init "${AGENT_ENDPOINT}" "${SUBSCRIPTION_ID}" \
  || { DP_READY=false; warn "Could not reach the agent data plane (${AGENT_ENDPOINT:-endpoint unknown}); checks from the agent's side are skipped"; }

# --- Dynatrace MCP connector -------------------------------------------------

step "Dynatrace MCP connector"
if [[ -z "${DT_ENV_URL:-}" ]]; then
  info "DT_ENV_URL is not set; skipping"
elif [[ -z "${DT_PLATFORM_TOKEN:-}" ]]; then
  warn "DT_PLATFORM_TOKEN is not set; the agent cannot query Dynatrace. See docs/DYNATRACE-SETUP.md (platform token scopes)."
else
  dt_resolve_urls "${DT_ENV_URL}"
  MCP_ENDPOINT="${DT_APPS_URL}/platform-reserved/mcp-gateway/v0.1/servers/dynatrace-mcp/mcp"

  body="$(mktemp)"; chmod 600 "${body}"
  trap 'rm -f "${body}"' EXIT

  # Prove the token reaches the MCP gateway before handing it to the agent.
  # (_curl_auth owns stdin for the credential, so the body goes via a file.)
  jq -cn '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:"2025-03-26",capabilities:{},clientInfo:{name:"sre-demo-lab",version:"1.0"}}}' > "${body}"
  code="$(_curl_auth header "Authorization: Bearer ${DT_PLATFORM_TOKEN}" "" \
        -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        --data-binary "@${body}" "${MCP_ENDPOINT}" 2>/dev/null || true)"
  case "${code}" in
    200|202) ok "Dynatrace MCP gateway accepted DT_PLATFORM_TOKEN" ;;
    401|403) die "Dynatrace MCP gateway rejected DT_PLATFORM_TOKEN (HTTP ${code}). Check its scopes in docs/DYNATRACE-SETUP.md." ;;
    *) warn "Dynatrace MCP gateway check returned HTTP ${code:-none}; creating the connector anyway" ;;
  esac

  jq -n --arg n "${DT_CONNECTOR_NAME}" --arg e "${MCP_ENDPOINT}" --arg t "${DT_PLATFORM_TOKEN}" '{
    properties: {
      name: $n,
      dataConnectorType: "Mcp",
      dataSource: $e,
      identity: "system",
      # partnerType makes the portal show it as the built-in Dynatrace connector
      # (same body the portal sends from Builder > Connectors > Dynatrace).
      extendedProperties: { type: "http", endpoint: $e, authType: "BearerToken", bearerToken: $t, partnerType: "DynatraceMcp" }
    }
  }' > "${body}"
  CONNECTOR_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}/connectors/${DT_CONNECTOR_NAME}?api-version=${CONNECTOR_API_VERSION}"
  if err="$(az rest --method put --url "${CONNECTOR_URL}" --body "@${body}" \
        --headers 'Content-Type=application/json' -o none 2>&1)"; then
    state="$(az rest --method get --url "${CONNECTOR_URL}" --query properties.provisioningState -o tsv 2>/dev/null || true)"
    ok "Connector ${DT_CONNECTOR_NAME} on ${AGENT_NAME} (${state:-submitted}) -> ${MCP_ENDPOINT}"
    if [[ "${DP_READY}" == "true" ]]; then
      # ARM and the data plane redact the endpoint on read; this proves the agent
      # itself reaches Dynatrace and discovered its tools.
      dt_status=""; dt_tools=0
      for _ in $(seq 1 24); do
        resp="$(sre_dp GET "/api/v2/extendedAgent/connectors/${DT_CONNECTOR_NAME}/tools")"
        dt_status="$(_http_body <<<"${resp}" | jq -r '.connectionStatus // empty' 2>/dev/null || true)"
        dt_tools="$(_http_body <<<"${resp}" | jq -r '.tools | length' 2>/dev/null || echo 0)"
        [[ "${dt_status}" == "Connected" && "${dt_tools:-0}" -gt 0 ]] && break
        sleep 5
      done
      if [[ "${dt_status}" == "Connected" && "${dt_tools:-0}" -gt 0 ]]; then
        ok "Agent is connected to the Dynatrace MCP server (${dt_tools} tools)"
      else
        warn "The agent reports the Dynatrace connector as '${dt_status:-unknown}'; check it under Builder > Connectors"
      fi
    fi
  else
    rm -f "${body}"
    die "Could not create the Dynatrace connector: $(echo "${err}" | head -3)"
  fi
  rm -f "${body}"
fi

# --- GitHub code repository --------------------------------------------------

step "GitHub code repository"
if [[ -z "${GITHUB_REPO:-}" ]]; then
  info "GITHUB_REPO is not set; skipping"
elif [[ "${DP_READY}" != "true" ]]; then
  warn "Agent data plane unavailable; add https://github.com/${GITHUB_REPO} under Builder > Code access"
else
  GITHUB_REPO="${GITHUB_REPO#https://github.com/}"; GITHUB_REPO="${GITHUB_REPO%.git}"
  REPO_URL="https://github.com/${GITHUB_REPO}"
  REPO_NAME="${GITHUB_REPO##*/}"
  if [[ -n "${GITHUB_PAT:-}" ]]; then
    # Same call as the portal's "Personal access token" option; domain key is
    # the host with dots replaced by underscores.
    resp="$(sre_dp PUT /api/v2/github/domains/github_com "$(jq -cn --arg p "${GITHUB_PAT}" '{authType:"Pat", pat:$p}')")"
    if [[ "$(_http_code <<<"${resp}")" =~ ^20[0-9]$ ]]; then
      ok "GitHub credential (GITHUB_PAT) stored on the agent"
    else
      warn "Could not store GITHUB_PAT (HTTP $(_http_code <<<"${resp}")): $(_http_body <<<"${resp}" | head -c 200)"
    fi
  fi
  body="$(jq -cn --arg n "${REPO_NAME}" --arg u "${REPO_URL}" '{
    name: $n, type: "CodeRepo",
    properties: { url: $u, type: "GitHub",
      description: "SRE demo lab source: Magic 8 Ball app, scenario-runner, Kubernetes manifests, Bicep and Terraform." }
  }')"
  resp="$(sre_dp PUT "/api/v2/repos/${REPO_NAME}" "${body}")"
  if [[ "$(_http_code <<<"${resp}")" =~ ^20[0-9]$ ]] && jq -e . >/dev/null 2>&1 <<<"$(_http_body <<<"${resp}")"; then
    ok "Code repository ${REPO_NAME} -> ${REPO_URL}"
    test_body="$(sre_dp POST "/api/v2/repos/${REPO_NAME}/test" | _http_body)"
    if jq -e '(.isSuccessful // .success // .isConnected // false) == true' >/dev/null 2>&1 <<<"${test_body}"; then
      ok "Agent can read ${GITHUB_REPO}"
    else
      warn "Agent cannot read ${GITHUB_REPO} yet: $(jq -r '.errorMessage // .message // .error // .status // empty' 2>/dev/null <<<"${test_body}" | head -c 200)"
      info "Private repo: set GITHUB_PAT in .env (fine-grained, this repo only, Contents + Metadata read-only)"
      info "and re-run, or authorize GitHub in the portal: Builder > Code access > ${REPO_NAME}"
    fi
  else
    warn "Could not register the repository (HTTP $(_http_code <<<"${resp}")); add ${REPO_URL} under Builder > Code access"
  fi
fi

# --- ServiceNow incident platform -------------------------------------------

step "ServiceNow incident platform"
if [[ -z "${SNOW_INSTANCE_URL:-}" ]]; then
  info "SNOW_INSTANCE_URL is not set; skipping"
  exit 0
fi

SNOW_ASSIGNMENT_GROUP="${SNOW_ASSIGNMENT_GROUP:-SRE Demo Lab}"
SNOW_INTEGRATION_USER="${SNOW_INTEGRATION_USER:-sre_demo_integration}"
SNOW_LOOKBACK_DAYS="${SNOW_LOOKBACK_DAYS:-30}"
# ServiceNow priorities the response plan picks up. The Dynatrace workflow
# opens incidents with impact 2 / urgency 1, which ServiceNow rates priority 2.
SNOW_RESPONSE_PRIORITIES="${SNOW_RESPONSE_PRIORITIES:-1,2}"
# review = the agent investigates on its own but asks before changing anything.
RESPONSE_PLAN_MODE="${SRE_RESPONSE_PLAN_MODE:-review}"
RESPONSE_PLAN_ID="servicenow-lab-response-plan"
AGENT_API_VERSION="${SRE_AGENT_API_VERSION:-2026-01-01}"

PASSWORD="$(snow_integration_password "${SUFFIX}" "${KEY_VAULT_NAME}" "${SUBSCRIPTION_ID}")"
[[ -n "${PASSWORD}" ]] || die "Could not read the integration user's password from Terraform state or Key Vault."

# Confirm the credentials the agent will use actually work, with the same
# scoped query the agent's scanner runs.
q="$(jq -rn --arg g "${SNOW_ASSIGNMENT_GROUP}" '"assignment_group.name=\($g)" | @uri')"
code="$(snow_api "${SNOW_INTEGRATION_USER}" "${PASSWORD}" GET \
  "/api/now/table/incident?sysparm_query=${q}&sysparm_fields=number&sysparm_limit=1" | _http_code)"
[[ "${code}" == "200" ]] && ok "ServiceNow accepts ${SNOW_INTEGRATION_USER} and can read '${SNOW_ASSIGNMENT_GROUP}' incidents" \
  || warn "ServiceNow returned HTTP ${code} for ${SNOW_INTEGRATION_USER}; the agent's connectivity check will fail"

PW_FILE="${REPO_ROOT}/.secrets/servicenow-integration-${SUFFIX}.txt"
mkdir -p "${REPO_ROOT}/.secrets"; chmod 700 "${REPO_ROOT}/.secrets"
( umask 077; printf '%s\n' "${PASSWORD}" > "${PW_FILE}" )

print_portal_fallback() {
  local pw_display="(in ${PW_FILE#${REPO_ROOT}/}; or re-run with --show-password)"
  [[ "${SHOW_PASSWORD}" == "true" ]] && pw_display="${PASSWORD}"
  cat <<NEXT

  Finish the ServiceNow connection in the portal instead: open
  ${AGENT_ENDPOINT:-https://sre.azure.com} and select ${AGENT_NAME}, then

    Builder > Incident platform > ServiceNow
      Authentication Type : Basic Authentication
      ServiceNow endpoint : ${SNOW_INSTANCE_URL%/}
      Username            : ${SNOW_INTEGRATION_USER}
      Password            : ${pw_display}
      Assignment group    : ${SNOW_ASSIGNMENT_GROUP}
      [x] Quickstart response plan

NEXT
}

# 1. Point the agent's incident platform at ServiceNow (ARM). This mirrors what
#    the portal sends: connectionKey is a JSON {username,password} document and
#    oboUser carries a config revision the data plane uses to spot propagation.
AGENT_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}?api-version=${AGENT_API_VERSION}"
body="$(mktemp)"; chmod 600 "${body}"
trap 'rm -f "${body}"' EXIT
REVISION="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || date +%s%N)"
jq -n --arg url "${SNOW_INSTANCE_URL%/}" --arg u "${SNOW_INTEGRATION_USER}" --arg p "${PASSWORD}" \
      --arg rev "sreagent-config-revision:${REVISION}" '{
  properties: { incidentManagementConfiguration: {
    type: "ServiceNow",
    connectionName: "servicenow",
    connectionUrl: $url,
    apiConnectionName: "",
    oboUser: $rev,
    connectionKey: ({username: $u, password: $p} | tojson)
  } }
}' > "${body}"
if ! err="$(az rest --method patch --url "${AGENT_URL}" --body "@${body}" \
      --headers 'Content-Type=application/json' -o none 2>&1)"; then
  rm -f "${body}"
  warn "Could not set the agent's incident platform: $(echo "${err}" | head -3)"
  print_portal_fallback; exit 1
fi
rm -f "${body}"
ok "Incident platform on ${AGENT_NAME} set to ServiceNow (${SNOW_INSTANCE_URL%/})"

[[ "${DP_READY}" == "true" ]] || { print_portal_fallback; exit 1; }

# 2. Wait for the agent to pick up the new configuration and reach ServiceNow.
info "Waiting for the agent to connect to ServiceNow (up to 3 minutes)..."
connected=false; last=""
for _ in $(seq 1 36); do
  resp="$(sre_dp GET /api/v2/incidentManagement/checkConnectivityDetailed)"
  last="$(_http_body <<<"${resp}")"
  if [[ "$(_http_code <<<"${resp}")" == "200" ]] && jq -e '.success == true' >/dev/null 2>&1 <<<"${last}"; then
    connected=true; break
  fi
  sleep 5
done
if [[ "${connected}" != "true" ]]; then
  warn "The agent did not report a ServiceNow connection: $(jq -r '.errorMessage // empty' 2>/dev/null <<<"${last}" | head -c 300)"
  print_portal_fallback; exit 1
fi
ok "Agent is connected to ServiceNow"

# 3. Scope incident indexing to the lab's assignment group.
resp="$(sre_dp PUT /api/v2/incidents/indexing/servicenow/configuration \
  "$(jq -cn --arg g "${SNOW_ASSIGNMENT_GROUP}" --argjson d "${SNOW_LOOKBACK_DAYS}" \
       '{providerType:"servicenow", assignmentGroup:$g, lookbackDays:$d}')")"
code="$(_http_code <<<"${resp}")"
if [[ "${code}" =~ ^20[0-9]$ ]]; then
  ok "Incident indexing scoped to assignment group '${SNOW_ASSIGNMENT_GROUP}' (${SNOW_LOOKBACK_DAYS} days)"
else
  warn "Could not set the incident indexing assignment group (HTTP ${code}): $(_http_body <<<"${resp}" | head -c 300)"
fi

# 4. Response plan: hand matching ServiceNow incidents to the agent. Retried
#    because the data plane can briefly reject it while the platform propagates.
plan="$(jq -cn --arg id "${RESPONSE_PLAN_ID}" --arg mode "${RESPONSE_PLAN_MODE}" \
     --arg pri "${SNOW_RESPONSE_PRIORITIES}" '{
  name: $id, type: "IncidentFilter",
  properties: {
    incidentPlatform: "ServiceNow", incidentType: "ServiceNow",
    priorities: ($pri | split(",") | map(gsub("\\s"; ""))),
    agentMode: $mode, handlingAgent: "meta_agent"
  }
}')"
created=false
for _ in $(seq 1 12); do
  resp="$(sre_dp PUT "/api/v2/incidentManagement/incidentFilters/${RESPONSE_PLAN_ID}" "${plan}")"
  code="$(_http_code <<<"${resp}")"
  if [[ "${code}" =~ ^20[0-9]$ ]] && jq -e . >/dev/null 2>&1 <<<"$(_http_body <<<"${resp}")"; then
    created=true; break
  fi
  sleep 10
done
if [[ "${created}" == "true" ]]; then
  ok "Response plan ${RESPONSE_PLAN_ID}: ServiceNow priority ${SNOW_RESPONSE_PRIORITIES} incidents -> agent (${RESPONSE_PLAN_MODE} mode)"
else
  warn "Could not create the response plan (HTTP ${code}): $(_http_body <<<"${resp}" | head -c 300)"
  info "Add one in the portal: Builder > Incident response plans"
fi
