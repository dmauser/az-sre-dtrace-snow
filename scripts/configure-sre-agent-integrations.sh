#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# configure-sre-agent-integrations.sh — connects the lab's Azure SRE Agent to
# Dynatrace (MCP connector) and prepares the ServiceNow incident platform.
#
#   ./scripts/configure-sre-agent-integrations.sh [--show-password]
#
# Dynatrace: creates the "dynatrace-mcp" connector on the agent through ARM
#   (Microsoft.App/agents/connectors), using DT_PLATFORM_TOKEN from .env as the
#   bearer token for the Dynatrace remote MCP server. Idempotent (PUT).
#
# ServiceNow: the incident platform's basic-auth credentials have no public ARM
#   or data-plane API, so this prints the exact values to enter at
#   sre.azure.com > Builder > Incident platform. The integration user's password
#   is written to .secrets/ (mode 0600) rather than the terminal unless
#   --show-password is given.
# -----------------------------------------------------------------------------

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-integrations.sh"

SHOW_PASSWORD=false
CONNECTOR_API_VERSION="${SRE_AGENT_CONNECTOR_API_VERSION:-2025-05-01-preview}"
DT_CONNECTOR_NAME="dynatrace-mcp"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show-password) SHOW_PASSWORD=true; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
      extendedProperties: { type: "http", endpoint: $e, authType: "BearerToken", bearerToken: $t }
    }
  }' > "${body}"
  CONNECTOR_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}/connectors/${DT_CONNECTOR_NAME}?api-version=${CONNECTOR_API_VERSION}"
  if err="$(az rest --method put --url "${CONNECTOR_URL}" --body "@${body}" \
        --headers 'Content-Type=application/json' -o none 2>&1)"; then
    state="$(az rest --method get --url "${CONNECTOR_URL}" --query properties.provisioningState -o tsv 2>/dev/null || true)"
    ok "Connector ${DT_CONNECTOR_NAME} on ${AGENT_NAME} (${state:-submitted}) -> ${MCP_ENDPOINT}"
  else
    rm -f "${body}"
    die "Could not create the Dynatrace connector: $(echo "${err}" | head -3)"
  fi
  rm -f "${body}"
fi

# --- ServiceNow incident platform -------------------------------------------

step "ServiceNow incident platform"
if [[ -z "${SNOW_INSTANCE_URL:-}" ]]; then
  info "SNOW_INSTANCE_URL is not set; skipping"
  exit 0
fi

SNOW_ASSIGNMENT_GROUP="${SNOW_ASSIGNMENT_GROUP:-SRE Demo Lab}"
SNOW_INTEGRATION_USER="${SNOW_INTEGRATION_USER:-sre_demo_integration}"

PASSWORD=""
if [[ -d "${TF_INTEGRATION_DIR}/terraform.tfstate.d/${SUFFIX}" ]] && command -v terraform >/dev/null 2>&1; then
  PASSWORD="$(cd "${TF_INTEGRATION_DIR}" && TF_WORKSPACE="${SUFFIX}" terraform output -raw servicenow_integration_password 2>/dev/null || true)"
fi
if [[ -z "${PASSWORD}" && -n "${KEY_VAULT_NAME}" ]]; then
  PASSWORD="$(az keyvault secret show --subscription "${SUBSCRIPTION_ID}" --vault-name "${KEY_VAULT_NAME}" -n servicenow-integration-password \
    --query value -o tsv 2>/dev/null || true)"
fi
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
if [[ "${SHOW_PASSWORD}" == "true" ]]; then
  PW_DISPLAY="${PASSWORD}"
else
  PW_DISPLAY="(in ${PW_FILE#${REPO_ROOT}/}; or re-run with --show-password)"
fi

cat <<NEXT

  ServiceNow incident indexing is configured in the SRE Agent portal (it has no
  public API). Open ${AGENT_ENDPOINT:-https://sre.azure.com} and select ${AGENT_NAME}, then:

    Builder > Incident platform > ServiceNow
      Authentication Type : Basic Authentication
      ServiceNow endpoint : ${SNOW_INSTANCE_URL%/}
      Username            : ${SNOW_INTEGRATION_USER}
      Password            : ${PW_DISPLAY}
      Assignment group    : ${SNOW_ASSIGNMENT_GROUP}
      [x] Quickstart response plan

    Save, and wait for the indicator to show Connected (up to 2 minutes).

  Only one incident platform can be active. If Azure Monitor is connected,
  disconnect it first; Azure Monitor alerts keep firing and stay visible in the
  portal, but the agent then picks incidents up from ServiceNow.

NEXT
