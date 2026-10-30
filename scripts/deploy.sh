#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# deploy.sh — end-to-end deployment of the Azure SRE Agent Demo Lab.
#
#   ./scripts/deploy.sh --subscription <id> --location <region>
#
# Designed to be re-runnable. Every step is either idempotent or detects the
# existing resource, so an interrupted deployment can simply be run again.
#
# Container images are built with `az acr build`, not locally. That removes the
# need for a working local Docker daemon, a registry login and a push over the
# operator's connection — the build happens next to the registry.
# -----------------------------------------------------------------------------

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-integrations.sh"

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
LOCATION="${AZURE_LOCATION:-eastus}"
SUFFIX="${LAB_SUFFIX:-}"
ADMIN_CIDR="${ADMIN_CIDR:-}"
SKIP_BUILD=false
SKIP_APPS=false
ASSUME_YES="${ASSUME_YES:-false}"
WITH_AGENT="${WITH_AGENT:-false}"
AGENT_MODE="${AGENT_MODE:-Review}"
AGENT_LOCATION="${AGENT_LOCATION:-}"
EXTRA_TAGS="${EXTRA_TAGS:-}"
SKIP_DYNATRACE="${SKIP_DYNATRACE:-false}"
SKIP_SERVICENOW="${SKIP_SERVICENOW:-false}"

usage() {
  cat <<'USAGE'
Usage: scripts/deploy.sh [options]

  --subscription <id>    Azure subscription ID (defaults to the current az account)
  --location <region>    Azure region, e.g. eastus, westus3, uksouth (default: eastus)
  --suffix <string>      Reuse a specific lab suffix instead of generating one
  --admin-cidr <cidr>    CIDR(s) allowed to reach SSH, the controller UI and Magic 8 Ball.
                         Repeatable, or comma-separated. Include the address you
                         will BROWSE from — it is often not this machine.
                         Prompted for interactively when omitted.
  --skip-build           Do not rebuild container images
  --skip-apps            Deploy infrastructure only
  --with-agent           Also create an Azure SRE Agent (Microsoft.App/agents).
                         Off by default: it is a chargeable managed service and
                         is not offered in every region the lab runs in.
  --agent-mode <mode>    ReadOnly | Review | Autonomous (default: Review).
                         Review pauses for human approval before each remediation.
  --agent-location <r>   Region for the agent when the lab region does not offer
                         it. Defaults to --location.
  --tag <Key=Value>      Extra tag to apply to the demo resource group, e.g. for a
                         subscription-level policy exemption. Repeatable, or
                         comma-separated (Key1=Value1,Key2=Value2).
  --skip-dynatrace       Do not configure Dynatrace (OneAgent, alert definitions,
                         problem routing). Implies --skip-servicenow.
                         Dynatrace is enabled whenever DT_ENV_URL is set in .env.
  --skip-servicenow      Do not create the ServiceNow group/user or the
                         Dynatrace -> ServiceNow incident routing.
  --yes                   Do not prompt for confirmation
  -h, --help             Show this help

Examples:
  ./scripts/deploy.sh --subscription 00000000-0000-0000-0000-000000000000 --location eastus
  ./scripts/deploy.sh --location westus3 --admin-cidr 203.0.113.10/32 --yes
  ./scripts/deploy.sh --location eastus2 --admin-cidr 203.0.113.10/32 --admin-cidr 198.51.100.7/32
  ./scripts/deploy.sh --location eastus2 --with-agent --agent-mode Review
  ./scripts/deploy.sh --location westus3 --admin-cidr 203.0.113.10/32 --tag SecurityControl=Ignore
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --suffix) SUFFIX="$2"; shift 2 ;;
    --admin-cidr) ADMIN_CIDR="${ADMIN_CIDR:+${ADMIN_CIDR},}$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --skip-apps) SKIP_APPS=true; shift ;;
    --with-agent) WITH_AGENT=true; shift ;;
    --agent-mode) AGENT_MODE="$2"; WITH_AGENT=true; shift 2 ;;
    --agent-location) AGENT_LOCATION="$2"; WITH_AGENT=true; shift 2 ;;
    --tag) EXTRA_TAGS="${EXTRA_TAGS:+${EXTRA_TAGS} }${2//,/ }"; shift 2 ;;
    --skip-dynatrace) SKIP_DYNATRACE=true; SKIP_SERVICENOW=true; shift ;;
    --skip-servicenow) SKIP_SERVICENOW=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

load_env_file
: "${LOCATION:=${AZURE_LOCATION:-eastus}}"
# Records whether the operator pinned a tag, so --skip-build knows not to
# override it with whatever is in the registry.
IMAGE_TAG_EXPLICIT="${IMAGE_TAG:-}"

START_TIME=$(date +%s)

# --- 1. Tooling -------------------------------------------------------------

step "1/20  Validating required tools"
require_core_tools
require_kubectl
require_tool git
ok "az $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo present), jq, openssl, kubectl, git"

# Fail fast on Dynatrace/ServiceNow credentials before anything is created in Azure.
integrations_preflight "${SKIP_DYNATRACE}" "${SKIP_SERVICENOW}"

# --- 2. Azure authentication ------------------------------------------------

step "2/20  Validating Azure authentication"
require_azure_login
CURRENT_USER="$(az account show --query user.name -o tsv)"
ok "Signed in as ${CURRENT_USER}"

# --- 3. Subscription --------------------------------------------------------

step "3/20  Selecting subscription"
if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
  info "No --subscription given; using the current one"
fi
az account set --subscription "${SUBSCRIPTION_ID}"
SUBSCRIPTION_NAME="$(az account show --query name -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
ok "${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"

# --- 4. Region --------------------------------------------------------------

step "4/20  Validating region '${LOCATION}'"
if ! az account list-locations --query "[?name=='${LOCATION}'].name" -o tsv | grep -qx "${LOCATION}"; then
  die "Region '${LOCATION}' is not available on this subscription. List them with: az account list-locations -o table"
fi
ok "Region ${LOCATION} is available"

# --- 5. Resource providers --------------------------------------------------

step "5/20  Ensuring resource providers are registered"
PROVIDERS=(
  Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.KeyVault
  Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.ManagedIdentity
  Microsoft.OperationalInsights Microsoft.Insights Microsoft.Monitor
  Microsoft.AlertsManagement Microsoft.Authorization
)
# Microsoft.App owns Microsoft.App/agents, and is only needed when an agent is requested.
[[ "${WITH_AGENT}" == "true" ]] && PROVIDERS+=(Microsoft.App)
PENDING=()
for provider in "${PROVIDERS[@]}"; do
  state="$(az provider show -n "${provider}" --query registrationState -o tsv 2>/dev/null || echo NotFound)"
  if [[ "${state}" != "Registered" ]]; then
    info "Registering ${provider} (currently ${state})"
    az provider register -n "${provider}" --only-show-errors >/dev/null 2>&1 || warn "Could not register ${provider}"
    PENDING+=("${provider}")
  fi
done
if (( ${#PENDING[@]} > 0 )); then
  info "Waiting for ${#PENDING[@]} provider registration(s)..."
  for provider in "${PENDING[@]}"; do
    for _ in $(seq 1 30); do
      state="$(az provider show -n "${provider}" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
      [[ "${state}" == "Registered" ]] && break
      sleep 10
    done
    [[ "${state}" == "Registered" ]] && ok "${provider}" || warn "${provider} is ${state}; deployment may fail"
  done
else
  ok "All required providers are registered"
fi

# --- 6. Administrator CIDRs -------------------------------------------------

if [[ "${WITH_AGENT}" == "true" ]]; then
  step "5b/20 Validating Azure SRE Agent options"

  case "${AGENT_MODE}" in
    ReadOnly|Review|Autonomous) ;;
    *) die "--agent-mode must be ReadOnly, Review or Autonomous (got '${AGENT_MODE}')" ;;
  esac

  [[ -n "${AGENT_LOCATION}" ]] || AGENT_LOCATION="${LOCATION}"

  # The provider reports display names ("East US 2") while --location is a slug
  # ("eastus2"), so both sides are squashed to a comparable form.
  slug() { tr -d ' ' | tr '[:upper:]' '[:lower:]'; }
  AGENT_REGIONS_RAW="$(az provider show -n Microsoft.App \
    --query "resourceTypes[?resourceType=='agents'].locations[]" -o tsv 2>/dev/null || true)"

  if [[ -z "${AGENT_REGIONS_RAW}" ]]; then
    warn "Could not read the regions offering SRE Agent; leaving the decision to ARM"
  elif printf '%s\n' "${AGENT_REGIONS_RAW}" | slug | grep -qx "$(printf '%s' "${AGENT_LOCATION}" | slug)"; then
    ok "SRE Agent is available in ${AGENT_LOCATION} (mode: ${AGENT_MODE})"
  else
    warn "SRE Agent is not offered in '${AGENT_LOCATION}'. Regions that do offer it:"
    printf '%s\n' "${AGENT_REGIONS_RAW}" | sed 's/^/         /'
    die "Re-run with --agent-location <supported-region>, or drop --with-agent. The agent may sit in a different region from the lab."
  fi
fi

step "6/20  Determining administrator access CIDRs"

# The machine running this script is very often NOT the machine the operator
# will browse from — a build agent, a jump box, CI. Silently allowing only the
# deploying host produces a lab that deploys perfectly and is unreachable, so
# ask rather than assume.
DETECTED_IP=""
if DETECTED_IP="$(detect_public_ip)"; then
  info "This machine's public IP is ${DETECTED_IP}"
else
  warn "Could not detect this machine's public IP"
fi

ADMIN_CIDRS=()
if [[ -n "${ADMIN_CIDR}" ]]; then
  # Accept a comma or space separated list from --admin-cidr or .env.
  IFS=', ' read -ra ADMIN_CIDRS <<< "${ADMIN_CIDR}"
  ok "Using supplied CIDR(s): ${ADMIN_CIDRS[*]}"
elif [[ -t 0 && "${ASSUME_YES}" != "true" ]]; then
  echo
  echo "  Which address(es) should be allowed to reach the lab?"
  echo "  This controls SSH, the Scenario Controller UI and Magic 8 Ball."
  echo
  echo "  Enter one or more CIDRs separated by commas. Include the address you"
  echo "  will browse from — find it at https://api.ipify.org"
  echo
  [[ -n "${DETECTED_IP}" ]] && echo "  Press Enter to accept this machine only: ${DETECTED_IP}/32"
  echo
  read -r -p "  Allowed CIDR(s): " reply
  if [[ -z "${reply}" ]]; then
    [[ -n "${DETECTED_IP}" ]] || die "No CIDR supplied and no public IP detected. Re-run with --admin-cidr."
    ADMIN_CIDRS=("${DETECTED_IP}/32")
  else
    IFS=', ' read -ra ADMIN_CIDRS <<< "${reply}"
  fi
else
  # Non-interactive: fall back to the detected address, but say plainly that it
  # may not be the one the operator needs.
  [[ -n "${DETECTED_IP}" ]] || die "Could not detect a public IP and none was supplied. Pass --admin-cidr <cidr>."
  ADMIN_CIDRS=("${DETECTED_IP}/32")
  warn "Non-interactive run: allowing only ${DETECTED_IP}/32 (this machine)."
  warn "If you browse from elsewhere, run: ./scripts/grant-access.sh --cidr <your-ip>/32"
fi

# Normalise and validate: a bare IP is a common and harmless mistake.
NORMALISED=()
for entry in "${ADMIN_CIDRS[@]}"; do
  [[ -z "${entry}" ]] && continue
  [[ "${entry}" =~ / ]] || entry="${entry}/32"
  [[ "${entry}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
    || die "Invalid CIDR '${entry}'. Expected something like 203.0.113.10/32."
  NORMALISED+=("${entry}")
done
ADMIN_CIDRS=("${NORMALISED[@]}")
(( ${#ADMIN_CIDRS[@]} > 0 )) || die "No valid administrator CIDR was resolved."

for entry in "${ADMIN_CIDRS[@]}"; do
  [[ "${entry}" == "0.0.0.0/0" ]] && warn "0.0.0.0/0 exposes the lab to the entire Internet."
done
ok "Allowing: ${ADMIN_CIDRS[*]}"

# JSON array for Bicep, YAML list for the Kubernetes Service.
ADMIN_CIDRS_JSON="$(printf '%s\n' "${ADMIN_CIDRS[@]}" | jq -R . | jq -sc .)"
ADMIN_CIDR_YAML=""
for entry in "${ADMIN_CIDRS[@]}"; do
  ADMIN_CIDR_YAML="${ADMIN_CIDR_YAML}    - ${entry}\\n"
done
ADMIN_CIDR_YAML="${ADMIN_CIDR_YAML%\\n}"
# Kept for the state file and messages.
ADMIN_CIDR="${ADMIN_CIDRS[*]}"

# --- 7. Sizing and quota ----------------------------------------------------

APP_VM_SIZE="${APP_VM_SIZE:-Standard_B2s}"
POSTGRES_VM_SIZE="${POSTGRES_VM_SIZE:-Standard_B2s}"
# Dynatrace (operator, webhook, CSI driver, ActiveGate, OneAgent) requests ~1.1
# vCPU, more than a 2 vCPU node has left after AKS system pods and the demo
# apps, so its pods would sit Pending. Use a 4 vCPU node when it is enabled.
if [[ "${DYNATRACE_ENABLED:-false}" == "true" ]]; then AKS_NODE_VCPU=4; else AKS_NODE_VCPU=2; fi
AKS_NODE_SIZE="${AKS_NODE_SIZE:-Standard_D${AKS_NODE_VCPU}as_v7}"
AKS_BASELINE_NODE_COUNT="${AKS_BASELINE_NODE_COUNT:-1}"

step "7/20  Validating VM SKU availability and quota"

# The SKU catalogue is large and the call is slow (~60s), so it is fetched ONCE
# and queried locally. --all is required: without it, SKUs that are restricted
# for this subscription are omitted entirely rather than returned with their
# restriction reason, which makes "unavailable" indistinguishable from
# "does not exist".
info "Fetching the VM SKU catalogue for ${LOCATION} (this takes up to a minute)"
# Held in a shell variable rather than a temp file: on some Windows/MSYS setups
# a freshly-written mktemp file can vanish before it is read back (observed
# during testing), which made every SKU look "unavailable". A variable has no
# such race.
if ! SKU_CACHE_JSON="$(az vm list-skus --location "${LOCATION}" --resource-type virtualMachines --all -o json 2>/dev/null)"; then
  SKU_CACHE_JSON='[]'
  warn "Could not read the SKU catalogue; skipping availability checks"
fi

# Only Location-type restrictions actually block a deployment. A Zone-type
# restriction means the SKU is unavailable in specific availability zones but is
# perfectly usable regionally — and this lab pins no zones, so treating those as
# blocking would reject working SKUs (Standard_B2s in several regions, for
# example).
sku_available() {
  local sku="$1"
  jq -e --arg n "${sku}" '
    any(.[];
      .name == $n
      and ([.restrictions[]? | select(.type == "Location")] | length) == 0)
  ' <<<"${SKU_CACHE_JSON}" >/dev/null 2>&1
}

sku_restriction() {
  local sku="$1"
  jq -r --arg n "${sku}" '
    first(.[] | select(.name == $n)
      | [.restrictions[]? | "\(.type):\(.reasonCode)"] | unique | join(", "))
    // "not offered in this region"
  ' <<<"${SKU_CACHE_JSON}" 2>/dev/null
}

sku_family() {
  local sku="$1"
  jq -r --arg n "${sku}" 'first(.[] | select(.name == $n) | .family) // empty' <<<"${SKU_CACHE_JSON}" 2>/dev/null
}

# v7 D-series first: current generation, widely available and the cheapest
# option at the required size (2 vCPU / 8 GB, or 4 vCPU / 16 GB with Dynatrace). Older generations follow as fallbacks for regions or
# subscriptions where v7 is not yet offered.
#
# B-series is deliberately excluded for AKS: burstable CPU credits make capacity
# behaviour non-deterministic, which would make scenario 02 inconsistent to
# demonstrate.
n="${AKS_NODE_VCPU}"
AKS_SKU_CANDIDATES=(
  "${AKS_NODE_SIZE}"
  "Standard_D${n}as_v7" "Standard_D${n}s_v7" "Standard_D${n}ads_v7" "Standard_D${n}ds_v7"
  "Standard_D${n}as_v6" "Standard_D${n}s_v6"
  "Standard_D${n}as_v5" "Standard_D${n}s_v5" "Standard_D${n}ads_v5"
  "Standard_D${n}s_v4" "Standard_D${n}as_v4" "Standard_DS$(( n == 4 ? 3 : 2 ))_v2"
)
unset n
SELECTED_AKS_SKU=""
for candidate in "${AKS_SKU_CANDIDATES[@]}"; do
  [[ -n "${candidate}" ]] || continue
  if sku_available "${candidate}"; then
    SELECTED_AKS_SKU="${candidate}"
    break
  fi
  info "SKU ${candidate} unavailable in ${LOCATION}: $(sku_restriction "${candidate}")"
done
[[ -n "${SELECTED_AKS_SKU}" ]] || die "No suitable AKS node SKU is available in ${LOCATION}. Try another region with --location."
if [[ "${SELECTED_AKS_SKU}" != "${AKS_NODE_SIZE}" ]]; then
  warn "Substituting AKS node SKU ${AKS_NODE_SIZE} -> ${SELECTED_AKS_SKU} (regional/subscription availability)"
else
  ok "AKS node SKU ${SELECTED_AKS_SKU} is available"
fi

if [[ "${DYNATRACE_ENABLED:-false}" == "true" ]]; then
  sel_vcpu="$(jq -r --arg n "${SELECTED_AKS_SKU}" \
    'first(.[] | select(.name == $n) | .capabilities[]? | select(.name == "vCPUs") | .value) // empty' \
    <<<"${SKU_CACHE_JSON}" 2>/dev/null)"
  if [[ "${sel_vcpu}" =~ ^[0-9]+$ ]] && (( sel_vcpu < 4 )); then
    warn "AKS node ${SELECTED_AKS_SKU} has ${sel_vcpu} vCPU; Dynatrace needs ~1.1 vCPU and its pods will likely stay Pending."
    warn "Remove AKS_NODE_SIZE from .env (deploy then picks a 4 vCPU SKU) or set a 4 vCPU SKU."
    confirm "Continue with ${SELECTED_AKS_SKU} anyway?" || die "Cancelled."
  fi
  unset sel_vcpu
fi

for candidate in "${APP_VM_SIZE}" "${POSTGRES_VM_SIZE}"; do
  sku_available "${candidate}" \
    || warn "SKU ${candidate} may be unavailable in ${LOCATION}: $(sku_restriction "${candidate}")"
done

# Per-family quota matters as much as the regional total: a family limit of zero
# fails the deployment even when plenty of regional cores remain.
USAGE_JSON="$(az vm list-usage --location "${LOCATION}" -o json 2>/dev/null || echo '[]')"
# az returns limit/currentValue as STRINGS, so they are coerced explicitly here.
family_headroom() {
  local family="$1"
  echo "${USAGE_JSON}" | jq -r --arg f "${family}" '
    [.[] | select((.name.value | ascii_downcase) == ($f | ascii_downcase))][0]
    | if . == null then "unknown"
      else ((.limit // 0 | tostring | tonumber) - (.currentValue // 0 | tostring | tonumber) | floor | tostring)
      end
  ' 2>/dev/null || echo "unknown"
}

AKS_FAMILY="$(sku_family "${SELECTED_AKS_SKU}")"
AKS_SKU_VCPUS="$(jq -r --arg n "${SELECTED_AKS_SKU}" \
  'first(.[] | select(.name == $n) | .capabilities[]? | select(.name == "vCPUs") | .value) // empty' \
  <<<"${SKU_CACHE_JSON}" 2>/dev/null)"
[[ "${AKS_SKU_VCPUS}" =~ ^[0-9]+$ ]] || AKS_SKU_VCPUS="${AKS_NODE_VCPU}"
AKS_VCPUS_NEEDED=$(( AKS_SKU_VCPUS * (AKS_BASELINE_NODE_COUNT + 1) ))   # +1 node for the scenario 02 scale-out
if [[ -n "${AKS_FAMILY}" ]]; then
  HEADROOM="$(family_headroom "${AKS_FAMILY}")"
  if [[ "${HEADROOM}" != "unknown" ]] && (( HEADROOM < AKS_VCPUS_NEEDED )); then
    fail "${AKS_FAMILY} quota is insufficient: ${HEADROOM} vCPU available, ${AKS_VCPUS_NEEDED} required."
    die "Request a quota increase for ${AKS_FAMILY} in ${LOCATION}, or deploy to another region."
  fi
  ok "${AKS_FAMILY}: ${HEADROOM} vCPU available, ${AKS_VCPUS_NEEDED} required"
fi

B_HEADROOM="$(family_headroom standardBSFamily)"
if [[ "${B_HEADROOM}" != "unknown" ]] && (( B_HEADROOM < 4 )); then
  fail "standardBSFamily quota is insufficient: ${B_HEADROOM} vCPU available, 4 required for the two lab VMs."
  die "Request a quota increase, or override APP_VM_SIZE and POSTGRES_VM_SIZE in .env."
fi
ok "standardBSFamily: ${B_HEADROOM} vCPU available, 4 required"

# Total regional vCPU headroom across all families.
REQUIRED_VCPUS=$(( 4 + AKS_VCPUS_NEEDED ))
TOTAL_LIMIT="$(echo "${USAGE_JSON}" | jq -r '[.[] | select(.name.value=="cores")][0].limit // 0')"
TOTAL_USED="$(echo "${USAGE_JSON}" | jq -r '[.[] | select(.name.value=="cores")][0].currentValue // 0')"
if [[ "${TOTAL_LIMIT}" != "0" ]]; then
  AVAILABLE=$(( TOTAL_LIMIT - TOTAL_USED ))
  if (( AVAILABLE < REQUIRED_VCPUS )); then
    fail "Regional vCPU quota is insufficient: ${AVAILABLE} available, ${REQUIRED_VCPUS} required in ${LOCATION}."
    die "Request a quota increase, or deploy to a different region with --location."
  fi
  ok "Regional vCPU quota: ${AVAILABLE} available, ${REQUIRED_VCPUS} required"
else
  warn "Could not read regional vCPU quota; continuing"
fi

# --- 8. Naming --------------------------------------------------------------

step "8/20  Resolving lab identity"
if [[ -z "${SUFFIX}" ]]; then
  SUFFIX="$(random_suffix)"
  ok "Generated lab suffix: ${SUFFIX}"
else
  ok "Using lab suffix: ${SUFFIX}"
fi
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-sre-demo-${SUFFIX}}"
ADMIN_USERNAME="${ADMIN_USERNAME:-sreadmin}"

echo
info "About to deploy:"
printf '     subscription : %s\n' "${SUBSCRIPTION_NAME}"
printf '     region       : %s\n' "${LOCATION}"
printf '     resource grp : %s\n' "${RESOURCE_GROUP}"
printf '     admin CIDR   : %s\n' "${ADMIN_CIDR}"
printf '     AKS node SKU : %s (%s node baseline)\n' "${SELECTED_AKS_SKU}" "${AKS_BASELINE_NODE_COUNT}"
printf '     Dynatrace    : %s\n' "$([[ "${DYNATRACE_ENABLED}" == "true" ]] && echo "${DT_APPS_URL}" || echo disabled)"
printf '     ServiceNow   : %s\n' "$([[ "${SERVICENOW_ENABLED}" == "true" ]] && echo "${SNOW_INSTANCE_URL} (group '${SNOW_ASSIGNMENT_GROUP}')" || echo disabled)"
echo
confirm "Proceed?" || die "Cancelled."

# --- 9. SSH key -------------------------------------------------------------

step "9/20  Preparing SSH key"
SSH_KEY_DIR="${REPO_ROOT}/.secrets"
SSH_KEY_PATH="${SSH_KEY_DIR}/lab_${SUFFIX}_ed25519"
mkdir -p "${SSH_KEY_DIR}"; chmod 700 "${SSH_KEY_DIR}"
if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  ssh-keygen -t ed25519 -N '' -C "sre-demo-lab-${SUFFIX}" -f "${SSH_KEY_PATH}" >/dev/null
  ok "Generated ${SSH_KEY_PATH} (git-ignored)"
else
  ok "Reusing existing key ${SSH_KEY_PATH}"
fi
ADMIN_PUBLIC_KEY="$(cat "${SSH_KEY_PATH}.pub")"

# --- 10. Credentials --------------------------------------------------------

step "10/20  Generating credentials"
PG_APP_PASSWORD="$(generate_password)"
PG_SCENARIO_PASSWORD="$(generate_password)"
RUNNER_TOKEN="$(generate_password)"
ok "Database and runner credentials generated (stored in Key Vault, never in git)"

# --- 11. Resource group -----------------------------------------------------

step "11/20  Creating resource group"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" \
  --tags project=azure-sre-agent-demo environment=demo managedBy=bicep purpose=sre-training ${EXTRA_TAGS} \
  --only-show-errors -o none
ok "Resource group ${RESOURCE_GROUP} ready"

# --- 12. Kubernetes version -------------------------------------------------

step "12/20  Selecting a supported GA Kubernetes version"
K8S_VERSION="${AKS_KUBERNETES_VERSION:-}"
if [[ -z "${K8S_VERSION}" ]]; then
  K8S_VERSION="$(az aks get-versions --location "${LOCATION}" -o json 2>/dev/null \
    | jq -r '[.values[]? | select(.isPreview != true) | .version]
             | sort_by(split(".") | map(tonumber)) | last // empty')"
fi
if [[ -n "${K8S_VERSION}" ]]; then
  ok "Kubernetes ${K8S_VERSION} (resolved at deploy time, no patch version pinned)"
else
  warn "Could not resolve a version; AKS will choose the regional default"
fi

# --- 12b. Dynatrace + ServiceNow (Terraform) -------------------------------
# Runs before Bicep: the VM OneAgent extension needs the PaaS token it creates.

DT_INGEST_TOKEN=""; DT_PAAS_TOKEN=""; DT_AKS_HOST_GROUP=""; DT_VM_HOST_GROUP=""
SNOW_INTEGRATION_PASSWORD=""
if [[ "${DYNATRACE_ENABLED}" == "true" ]]; then
  step "12b/20  Configuring Dynatrace$([[ "${SERVICENOW_ENABLED}" == "true" ]] && echo " and ServiceNow") (Terraform)"
  integrations_apply
fi

# --- 13. Infrastructure -----------------------------------------------------

step "13/20  Deploying Azure infrastructure (Bicep)"
DEPLOYER_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
[[ -n "${DEPLOYER_OBJECT_ID}" ]] || DEPLOYER_OBJECT_ID="$(az account show --query user.name -o tsv | xargs -I{} az ad sp show --id {} --query id -o tsv 2>/dev/null || true)"

# AKS cannot change a node pool's VM size in place, so redeploying an existing
# lab with a different node SKU (e.g. after enabling Dynatrace, which needs the
# 4 vCPU node) would fail inside Bicep. Detect it here and recreate the cluster:
# it holds no state that the rest of this script does not redeploy.
EXISTING_AKS_SKU="$(az aks nodepool show --subscription "${SUBSCRIPTION_ID}" -g "${RESOURCE_GROUP}" \
  --cluster-name "aks-sre-demo-${SUFFIX}" -n system --query vmSize -o tsv 2>/dev/null || true)"
if [[ -n "${EXISTING_AKS_SKU}" && "${EXISTING_AKS_SKU}" != "${SELECTED_AKS_SKU}" ]]; then
  warn "Existing AKS cluster uses ${EXISTING_AKS_SKU}; this deployment needs ${SELECTED_AKS_SKU}, which AKS cannot change in place."
  confirm "Delete and recreate AKS cluster aks-sre-demo-${SUFFIX}?" \
    || die "Cancelled. Set AKS_NODE_SIZE=${EXISTING_AKS_SKU} to keep the existing cluster."
  az aks delete --subscription "${SUBSCRIPTION_ID}" -g "${RESOURCE_GROUP}" -n "aks-sre-demo-${SUFFIX}" --yes \
    || die "Failed to delete AKS cluster aks-sre-demo-${SUFFIX}"
  ok "Deleted AKS cluster; Bicep will recreate it on ${SELECTED_AKS_SKU}"
fi

# A VM cannot change its disk SKU through the VM resource
# (OperationNotAllowed on osDisk.managedDisk.storageAccountType), and disks are
# sometimes converted outside the lab (e.g. subscription cost automation moving
# deallocated VMs to Standard_LRS). Redeploy with whatever SKU the disks have now.
existing_disk_sku() {
  local sku
  sku="$(az disk show --subscription "${SUBSCRIPTION_ID}" -g "${RESOURCE_GROUP}" -n "$1" \
    --query sku.name -o tsv 2>/dev/null | tr -d '\r' || true)"
  printf '%s' "${sku:-StandardSSD_LRS}"
}
APP_VM_DISK_SKU="$(existing_disk_sku "osdisk-sre-app-${SUFFIX}")"
POSTGRES_VM_DISK_SKU="$(existing_disk_sku "osdisk-sre-pg-${SUFFIX}")"
for disk_sku in "${APP_VM_DISK_SKU}" "${POSTGRES_VM_DISK_SKU}"; do
  [[ "${disk_sku}" == "StandardSSD_LRS" ]] \
    || warn "Existing VM disks use ${disk_sku} (lab default StandardSSD_LRS); keeping ${disk_sku} because a VM cannot change disk SKU in place"
done

# ARM rejects any change to an existing VM's osProfile.customData
# (PropertyChangeNotAllowed) - even a CRLF/LF difference from another checkout.
# cloud-init only runs on first boot, so existing VMs are deployed without it.
vm_exists() {
  [[ -n "$(az vm show --subscription "${SUBSCRIPTION_ID}" -g "${RESOURCE_GROUP}" -n "$1" \
    --query id -o tsv 2>/dev/null | tr -d '\r' || true)" ]] && echo true || echo false
}
APP_VM_EXISTS="$(vm_exists "vm-sre-app-${SUFFIX}")"
POSTGRES_VM_EXISTS="$(vm_exists "vm-sre-pg-${SUFFIX}")"

DEPLOYMENT_NAME="sre-demo-${SUFFIX}-$(date -u +%Y%m%d%H%M%S)"
deploy_infra() {
  local assign_roles="$1"
  az deployment group create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${DEPLOYMENT_NAME}" \
    --template-file "${REPO_ROOT}/infra/bicep/main.bicep" \
    --parameters \
      suffix="${SUFFIX}" \
      location="${LOCATION}" \
      adminCidrs="${ADMIN_CIDRS_JSON}" \
      adminUsername="${ADMIN_USERNAME}" \
      adminPublicKey="${ADMIN_PUBLIC_KEY}" \
      postgresAppPassword="${PG_APP_PASSWORD}" \
      postgresScenarioPassword="${PG_SCENARIO_PASSWORD}" \
      appVmSize="${APP_VM_SIZE}" \
      postgresVmSize="${POSTGRES_VM_SIZE}" \
      aksNodeVmSize="${SELECTED_AKS_SKU}" \
      aksBaselineNodeCount="${AKS_BASELINE_NODE_COUNT}" \
      kubernetesVersion="${K8S_VERSION}" \
      demoDataDiskSizeGb="${DEMO_DATA_DISK_GB:-16}" \
      appVmDiskSku="${APP_VM_DISK_SKU}" \
      postgresVmDiskSku="${POSTGRES_VM_DISK_SKU}" \
      appVmExists="${APP_VM_EXISTS}" \
      postgresVmExists="${POSTGRES_VM_EXISTS}" \
      postgresMaxConnections="${POSTGRES_MAX_CONNECTIONS:-50}" \
      deployerObjectId="${DEPLOYER_OBJECT_ID}" \
      assignRoles="${assign_roles}" \
      deploySreAgent="${WITH_AGENT}" \
      sreAgentLocation="${AGENT_LOCATION}" \
      sreAgentMode="${AGENT_MODE}" \
      enableDynatrace="${DYNATRACE_ENABLED}" \
      dynatraceEnvironmentId="${DT_ENV_ID}" \
      dynatraceApiUrl="${DT_CLASSIC_URL:+${DT_CLASSIC_URL}/api}" \
      dynatracePaasToken="${DT_PAAS_TOKEN}" \
      dynatraceVmHostGroup="${DT_VM_HOST_GROUP:-sre-demo-vm-${SUFFIX}}" \
    --only-show-errors -o none
}

info "This takes roughly 10-15 minutes (AKS and two VMs)."
DEPLOY_ERR="$(mktemp)"
if ! deploy_infra true 2>"${DEPLOY_ERR}"; then
  DEPLOY_ERROR_TEXT="$(cat "${DEPLOY_ERR}")"
  echo "${DEPLOY_ERROR_TEXT}" | head -20

  # Regional capacity is not something a retry can fix, and it is not a
  # permissions problem — distinguish it so the operator is not sent chasing RBAC.
  if echo "${DEPLOY_ERROR_TEXT}" | grep -qiE "AKSCapacityHeavyUsage|SkuNotAvailable|ZonalAllocationFailed|AllocationFailed|OutOfCapacity"; then
    rm -f "${DEPLOY_ERR}"
    fail "Azure reports insufficient capacity in ${LOCATION}."
    cat <<CAPACITY

This is a regional capacity condition, not a configuration or permission error.
Azure is temporarily refusing new resources of this type in ${LOCATION}.

What to do:

  1. Re-run in another region — everything else about the lab is unchanged:

       ./scripts/destroy-lab.sh --resource-group ${RESOURCE_GROUP} --yes
       ./scripts/deploy.sh --location eastus2

     Regions worth trying: eastus2, westus3, centralus, westus2, canadacentral,
     northeurope, uksouth.

  2. Or wait and retry the same region later — capacity conditions are transient:

       ./scripts/deploy.sh --location ${LOCATION} --suffix ${SUFFIX}

     The deployment is idempotent, so it will reuse everything already created.

The resource group ${RESOURCE_GROUP} has been left in place so you can choose.
CAPACITY
    exit 1
  fi

  # Role assignment failures ARE worth retrying without them: the lab still runs,
  # and the operator can grant the roles separately.
  if echo "${DEPLOY_ERROR_TEXT}" | grep -qiE "AuthorizationFailed|RoleAssignment|does not have permission|Forbidden"; then
    warn "Deployment failed on a permissions error. Retrying without role assignments."
    if deploy_infra false; then
      warn "Deployed WITHOUT role assignments. Grant them manually:"
      cat <<MANUAL

  # The App VM identity needs these for scenarios 02 and 05:
  IDENTITY_ID=\$(az identity show -g ${RESOURCE_GROUP} -n id-sre-demo-${SUFFIX} --query principalId -o tsv)
  az role assignment create --assignee \$IDENTITY_ID --role Contributor \\
     --scope /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}
  az role assignment create --assignee \$IDENTITY_ID --role AcrPull \\
     --scope \$(az acr show -g ${RESOURCE_GROUP} -n acrsredemo${SUFFIX} --query id -o tsv)
  az aks update -g ${RESOURCE_GROUP} -n aks-sre-demo-${SUFFIX} --attach-acr acrsredemo${SUFFIX}

MANUAL
    else
      rm -f "${DEPLOY_ERR}"
      die "Infrastructure deployment failed. Inspect: az deployment group show -g ${RESOURCE_GROUP} -n ${DEPLOYMENT_NAME}"
    fi
  else
    rm -f "${DEPLOY_ERR}"
    die "Infrastructure deployment failed. Inspect: az deployment group show -g ${RESOURCE_GROUP} -n ${DEPLOYMENT_NAME}"
  fi
fi
rm -f "${DEPLOY_ERR}"

OUTPUTS="$(az deployment group show -g "${RESOURCE_GROUP}" -n "${DEPLOYMENT_NAME}" --query properties.outputs -o json)"
out() { echo "${OUTPUTS}" | jq -r --arg k "$1" '.[$k].value // empty'; }

ACR_NAME="$(out acrName)"
ACR_LOGIN_SERVER="$(out acrLoginServer)"
SRE_AGENT_NAME="$(out sreAgentName)"
SRE_AGENT_ID="$(out sreAgentId)"
SRE_AGENT_REGION="$(out sreAgentRegion)"
SRE_AGENT_MODE="$(out sreAgentActionMode)"
SRE_AGENT_PRINCIPAL_ID="$(out sreAgentPrincipalId)"
SRE_AGENT_ENDPOINT="$(out sreAgentEndpoint)"
APPI_NAME="$(out appInsightsName)"
APPI_CONNECTION_STRING="$(out appInsightsConnectionString)"
# A @secure() Bicep output is redacted when the deployment is read back, so it
# returns empty here. Fetch it from the resource instead, otherwise both
# applications start with telemetry silently disabled.
if [[ -z "${APPI_CONNECTION_STRING}" ]]; then
  APPI_CONNECTION_STRING="$(az resource show -g "${RESOURCE_GROUP}" -n "${APPI_NAME}" \
    --resource-type Microsoft.Insights/components \
    --query properties.ConnectionString -o tsv 2>/dev/null || true)"
fi
[[ -n "${APPI_CONNECTION_STRING}" ]] || warn "Application Insights connection string could not be read; telemetry will be disabled"
LAW_NAME="$(out logAnalyticsWorkspaceName)"
LAW_ID="$(out logAnalyticsWorkspaceId)"
KEY_VAULT_NAME="$(out keyVaultName)"
IDENTITY_CLIENT_ID="$(out labIdentityClientId)"
APP_VM_NAME="$(out appVmName)"
APP_VM_IP="$(out appVmPublicIp)"
APP_VM_FQDN="$(out appVmFqdn)"
PG_VM_NAME="$(out postgresVmName)"
PG_PRIVATE_IP="$(out postgresPrivateIp)"
PG_DATABASE="$(out postgresDatabaseName)"
PG_APP_USER="$(out postgresAppUsername)"
PG_SCENARIO_USER="$(out postgresScenarioUsername)"
PG_MAX_CONNECTIONS="$(out postgresMaxConnections)"
AKS_NAME="$(out aksClusterName)"
AKS_NODE_RG="$(out aksNodeResourceGroup)"
AKS_K8S_VERSION="$(out aksKubernetesVersion)"
DB_NSG_NAME="$(out databaseNsgName)"
DEMO_MOUNT_PATH="$(out demoMountPath)"

ok "Infrastructure deployed"
printf '     ACR    : %s\n' "${ACR_LOGIN_SERVER}"
printf '     App VM : %s (%s)\n' "${APP_VM_NAME}" "${APP_VM_IP}"
printf '     PG VM  : %s (%s)\n' "${PG_VM_NAME}" "${PG_PRIVATE_IP}"
printf '     AKS    : %s (k8s %s)\n' "${AKS_NAME}" "${AKS_K8S_VERSION}"

# --- 13b. Agent read access --------------------------------------------------
#
# The agent's Bicep module deliberately grants it NO role assignments, so that
# investigate-only vs. write access is always a conscious choice rather than a
# side effect of deploying. Read access is the exception: without it the agent
# is created but can see nothing at all, which is not a useful default and is
# not a decision anyone would reasonably want to make by hand every time. Write
# access (Contributor) is granted by scripts/enable-sre-remediation.sh: manually
# in Review/ReadOnly mode, automatically only when --agent-mode Autonomous was
# passed, since asking for autonomy is that conscious choice (see below).
#
# This is also the role set the Azure portal's own "Managed resources" ->
# "Add resource group" flow grants for Permission level "Reader" — matching it
# here means that flow shows these as already granted instead of re-granting
# them (or worse, silently depending on knowledgeGraphConfiguration being set;
# see the fix on the agent Bicep module for the failure mode that produces).
if [[ "${WITH_AGENT}" == "true" && -n "${SRE_AGENT_PRINCIPAL_ID}" ]]; then
  step "13b/20 Granting the SRE Agent read access to the lab"
  AGENT_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"
  AGENT_READ_ROLES=(
    "Reader"
    "Monitoring Reader"
    "Log Analytics Reader"
    "Azure Kubernetes Service Cluster User Role"
    "Azure Kubernetes Service RBAC Reader"
    "HDInsight Cluster Operator"
  )
  AGENT_ROLE_FAILED=0
  for role in "${AGENT_READ_ROLES[@]}"; do
    # The agent's managed identity was created moments ago by the Bicep
    # deployment above. Azure AD replication can lag a new principal by up to
    # ~60s, and a role assignment created before it catches up fails with
    # PrincipalNotFound/does-not-exist-in-the-directory, not a permissions
    # error. Retry with backoff before treating it as a real failure.
    role_error=""
    role_granted=false
    for attempt in 1 2 3 4 5; do
      # --subscription is required here, not optional: az role assignment
      # create/list resolve context from the CLI's ambient default subscription
      # as well as --scope, and when that default is a different tenant (e.g.
      # the operator is normally logged into a different subscription/tenant
      # than the one being deployed to), the call fails with MissingSubscription
      # even though --scope already contains the full subscription path.
      if role_error="$(az role assignment create --assignee "${SRE_AGENT_PRINCIPAL_ID}" --role "${role}" \
           --scope "${AGENT_SCOPE}" --subscription "${SUBSCRIPTION_ID}" --only-show-errors -o none 2>&1)"; then
        role_granted=true
        break
      fi
      # Idempotent: an existing assignment from a prior run is success, not failure.
      if az role assignment list --assignee "${SRE_AGENT_PRINCIPAL_ID}" --scope "${AGENT_SCOPE}" \
           --subscription "${SUBSCRIPTION_ID}" \
           --query "[?roleDefinitionName=='${role}'] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]'; then
        role_granted=true
        break
      fi
      sleep $(( attempt * 10 ))
    done
    if [[ "${role_granted}" == "true" ]]; then
      continue
    fi
    AGENT_ROLE_FAILED=$(( AGENT_ROLE_FAILED + 1 ))
    warn "Could not grant '${role}' to the agent after retries: ${role_error}"
  done
  if (( AGENT_ROLE_FAILED == 0 )); then
    ok "Agent granted read access to ${RESOURCE_GROUP} (${#AGENT_READ_ROLES[@]} roles)"
  else
    warn "Agent read access incomplete: ${AGENT_ROLE_FAILED} of ${#AGENT_READ_ROLES[@]} role(s) could not be granted"
    warn "Retry manually once the agent's identity has replicated in Azure AD, e.g.:"
    warn "  az role assignment create --assignee ${SRE_AGENT_PRINCIPAL_ID} --role <role> --scope ${AGENT_SCOPE}"
  fi

  # None of the roles above cover Microsoft.Compute/virtualMachines/runCommand/action.
  # "Reader" only ever grants "*/read" actions, and runCommand is an action-type
  # permission, not a read -- so scenarios that need the agent to inspect VM-level
  # state (services, config files, logs on the App/Postgres VMs; e.g. scenario 04,
  # Database Connection Exhaustion) fail instantly with "Agent permissions were
  # used, but the action failed to run", even though every other read role is in
  # place. The only built-in roles that include runCommand/action bundle full VM
  # write/delete/start/stop/deallocate power (e.g. "Virtual Machine Contributor"),
  # which is deliberately kept separate as write access via
  # scripts/enable-sre-remediation.sh. So this is a purpose-built custom role that
  # grants only what a VM-diagnostic run-command needs and nothing else.
  VM_DIAG_ROLE_NAME="SRE Demo Lab VM Diagnostics - ${SUFFIX}"
  VM_DIAG_ROLE_FILE="$(mktemp)"
  cat > "${VM_DIAG_ROLE_FILE}" <<EOF
{
  "Name": "${VM_DIAG_ROLE_NAME}",
  "IsCustom": true,
  "Description": "Run diagnostic scripts on the SRE demo lab VMs via the platform run-command channel (az vm run-command), without any other virtual machine write, delete or lifecycle permission.",
  "Actions": [
    "Microsoft.Compute/virtualMachines/runCommand/action",
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/instanceView/read"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "${AGENT_SCOPE}"
  ]
}
EOF
  if ! az role definition list --name "${VM_DIAG_ROLE_NAME}" --subscription "${SUBSCRIPTION_ID}" \
       --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    if ! az role definition create --role-definition "${VM_DIAG_ROLE_FILE}" --subscription "${SUBSCRIPTION_ID}" \
         --only-show-errors -o none 2>vm_diag_role_err.log; then
      warn "Could not create custom role '${VM_DIAG_ROLE_NAME}': $(cat vm_diag_role_err.log)"
    fi
    rm -f vm_diag_role_err.log
  fi
  rm -f "${VM_DIAG_ROLE_FILE}"
  vm_diag_granted=false
  for attempt in 1 2 3 4 5; do
    if vm_diag_error="$(az role assignment create --assignee "${SRE_AGENT_PRINCIPAL_ID}" --role "${VM_DIAG_ROLE_NAME}" \
         --scope "${AGENT_SCOPE}" --subscription "${SUBSCRIPTION_ID}" --only-show-errors -o none 2>&1)"; then
      vm_diag_granted=true
      break
    fi
    if az role assignment list --assignee "${SRE_AGENT_PRINCIPAL_ID}" --scope "${AGENT_SCOPE}" \
         --subscription "${SUBSCRIPTION_ID}" \
         --query "[?roleDefinitionName=='${VM_DIAG_ROLE_NAME}'] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]'; then
      vm_diag_granted=true
      break
    fi
    sleep $(( attempt * 10 ))
  done
  if [[ "${vm_diag_granted}" == "true" ]]; then
    ok "Agent granted VM run-command diagnostics via custom role '${VM_DIAG_ROLE_NAME}'"
  else
    warn "Could not grant custom role '${VM_DIAG_ROLE_NAME}' to the agent after retries: ${vm_diag_error:-unknown error}"
    warn "Retry manually: az role assignment create --assignee ${SRE_AGENT_PRINCIPAL_ID} --role \"${VM_DIAG_ROLE_NAME}\" --scope ${AGENT_SCOPE}"
  fi
fi

# --- 14. Key Vault ----------------------------------------------------------

step "14/20  Storing secrets in Key Vault"
KV_STORED=0
KV_FAILED=0
KV_LAST_ERROR=""

kv_set() {
  local name="$1" value="$2" attempt
  # Retry: data-plane RBAC can take a minute to propagate after assignment.
  for attempt in 1 2 3; do
    if KV_LAST_ERROR="$(az keyvault secret set --vault-name "${KEY_VAULT_NAME}" \
         --name "$1" --value "$2" --only-show-errors -o none 2>&1)"; then
      KV_STORED=$(( KV_STORED + 1 ))
      return 0
    fi
    [[ ${attempt} -lt 3 ]] && sleep 15
  done
  KV_FAILED=$(( KV_FAILED + 1 ))
  return 0
}

kv_set postgres-app-password "${PG_APP_PASSWORD}"
kv_set postgres-scenario-password "${PG_SCENARIO_PASSWORD}"
kv_set scenario-runner-token "${RUNNER_TOKEN}"
[[ -n "${DT_INGEST_TOKEN}" ]] && kv_set dynatrace-ingest-token "${DT_INGEST_TOKEN}"
[[ -n "${SNOW_INTEGRATION_PASSWORD}" ]] && kv_set servicenow-integration-password "${SNOW_INTEGRATION_PASSWORD}"

if (( KV_FAILED == 0 )); then
  ok "Stored ${KV_STORED} secret(s) in ${KEY_VAULT_NAME}"
else
  # Report honestly. The lab is unaffected, but claiming success here would be a
  # lie the operator might rely on later.
  warn "Stored ${KV_STORED} of $(( KV_STORED + KV_FAILED )) secret(s) in ${KEY_VAULT_NAME}"
  if echo "${KV_LAST_ERROR}" | grep -qi "public network access is disabled\|ForbiddenByConnection"; then
    cat <<KVNOTE

  Key Vault data-plane access is blocked from this machine because the vault has
  public network access disabled. On governed subscriptions this is commonly
  enforced by Azure Policy, which overrides the template setting.

  THIS DOES NOT AFFECT THE LAB. Key Vault is a convenience store for operators;
  it is not in any runtime path. Credentials reach the workloads directly:
    - PostgreSQL VM  : Bicep @secure() parameter -> extension protectedSettings
                       (encrypted at rest by Azure)
    - AKS            : Kubernetes secrets created by this script
    - App VM         : /etc/sre-demo-controller.env, mode 0600

  To store them anyway, run from a permitted network, or:
    az keyvault update -g ${RESOURCE_GROUP} -n ${KEY_VAULT_NAME} --public-network-access Enabled

KVNOTE
  else
    warn "Last error: $(echo "${KV_LAST_ERROR}" | head -3)"
  fi
fi

# --- 15. Container images ---------------------------------------------------

GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IMAGE_TAG="${IMAGE_TAG:-${GIT_COMMIT}}"

# With --skip-build the images in ACR were tagged with whatever commit was
# current when they were built, which is not necessarily HEAD now. Deriving the
# tag from HEAD would reference an image that was never built, so resolve it
# from the registry instead. An explicit IMAGE_TAG always wins.
#
# Each repository is resolved on its own: a single image may have been rebuilt
# alone (e.g. a scenario-runner hotfix), and one shared tag would silently roll
# it back to the older build.
image_ref() {
  local repo="$1" tag="${IMAGE_TAG}"
  if [[ "${SKIP_BUILD}" == "true" && -z "${IMAGE_TAG_EXPLICIT:-}" ]]; then
    tag="$(az acr repository show-tags --name "${ACR_NAME}" \
      --repository "${repo}" --orderby time_desc --top 1 -o tsv 2>/dev/null | head -1 || true)"
  fi
  [[ -n "${tag}" ]] && printf '%s/%s:%s' "${ACR_LOGIN_SERVER}" "${repo}" "${tag}"
}

for _ref in CONTROLLER_IMAGE:scenario-controller MAGIC8BALL_STABLE_IMAGE:magic8ball \
            MAGIC8BALL_BAD_IMAGE:magic8ball-bad RUNNER_IMAGE:scenario-runner BURNER_IMAGE:resource-burner; do
  _img="$(image_ref "${_ref#*:}" || true)"
  [[ -n "${_img}" ]] || die "--skip-build was given but ${_ref#*:} has no image in ${ACR_NAME}. Run without --skip-build first."
  [[ "${_img##*:}" == "${IMAGE_TAG}" ]] || warn "Using ${_ref#*:}:${_img##*:} from ACR rather than current commit '${IMAGE_TAG}'"
  printf -v "${_ref%%:*}" '%s' "${_img}"
done
unset _ref _img
# Recorded in .lab-state.json and the controller's build info.
IMAGE_TAG="${CONTROLLER_IMAGE##*:}"

if [[ "${SKIP_BUILD}" == "true" ]]; then
  step "15/20  Skipping image build (--skip-build)"
else
  step "15/20  Building container images in ACR"
  info "Builds run in Azure, so no local Docker daemon or registry push is needed."

  acr_build() {
    local image="$1" dockerfile="$2" context="$3"; shift 3
    info "Building ${image##*/}"
    az acr build --registry "${ACR_NAME}" --image "${image#*/}" \
      --file "${dockerfile}" "${context}" \
      --build-arg APP_VERSION=0.1.0 \
      --build-arg IMAGE_TAG="${IMAGE_TAG}" \
      --build-arg GIT_COMMIT="${GIT_COMMIT}" \
      --build-arg BUILD_TIMESTAMP="${BUILD_TIMESTAMP}" \
      "$@" \
      --only-show-errors -o none --no-logs
    ok "${image}"
  }

  acr_build "${CONTROLLER_IMAGE}" "${REPO_ROOT}/apps/scenario-controller/Dockerfile" "${REPO_ROOT}/apps/scenario-controller"
  acr_build "${MAGIC8BALL_STABLE_IMAGE}" "${REPO_ROOT}/apps/magic8ball/Dockerfile" "${REPO_ROOT}/apps/magic8ball" --build-arg FAULT_MODE=stable
  # Same source, different build metadata and fault flag: a genuine second
  # deployment for scenario 03 to correlate against.
  acr_build "${MAGIC8BALL_BAD_IMAGE}" "${REPO_ROOT}/apps/magic8ball/Dockerfile" "${REPO_ROOT}/apps/magic8ball" --build-arg FAULT_MODE=bad --build-arg APP_VERSION=0.1.1
  acr_build "${RUNNER_IMAGE}" "${REPO_ROOT}/services/scenario-runner/Dockerfile" "${REPO_ROOT}/services/scenario-runner"
  acr_build "${BURNER_IMAGE}" "${REPO_ROOT}/services/resource-burner/Dockerfile" "${REPO_ROOT}/services/resource-burner"
fi

if [[ "${SKIP_APPS}" == "true" ]]; then
  warn "Skipping application deployment (--skip-apps)"
  warn ".lab-state.json was NOT refreshed and still describes the previous deployment."
  warn "Re-run without --skip-apps before using the other scripts."
  exit 0
fi

# --- 16. AKS credentials ----------------------------------------------------

step "16/20  Connecting to AKS"
KUBECONFIG_PATH="${REPO_ROOT}/.secrets/kubeconfig-${SUFFIX}"
az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" \
  --file "${KUBECONFIG_PATH}" --overwrite-existing --only-show-errors
export KUBECONFIG="${KUBECONFIG_PATH}"
chmod 600 "${KUBECONFIG_PATH}"
kubectl cluster-info >/dev/null 2>&1 || die "Could not reach the AKS API server"
ok "Connected to ${AKS_NAME}"

# --- 17. TLS certificates ---------------------------------------------------

step "17/20  Generating demo TLS certificates"
FORCE_REGENERATE=true bash "${REPO_ROOT}/scripts/gen-certs.sh" --force >/dev/null
CERT_DIR="${REPO_ROOT}/certs"
ok "Demo CA plus valid and expired server certificates created"

# --- 18. Kubernetes workloads ----------------------------------------------

# Scenario 02 needs two burner replicas to schedule (real CPU starvation) and the
# rest to stay Pending. The headroom that decides this differs by node SKU and by
# what else runs (Dynatrace adds ~1.1 vCPU), so the burner's CPU request is set
# from the measured headroom rather than hard-coded: 0.4 x free CPU, so two fit
# and a third does not. Must run after every baseline pod (OneAgent included) is
# scheduled.
calibrate_resource_pressure() {
  local nodes alloc used free req
  nodes="$(kubectl get nodes -o json)" || { warn "Could not read nodes; scenario 02 keeps its default sizing"; return 0; }
  alloc="$(jq '[.items[] | .status.allocatable.cpu
            | if endswith("m") then (.[:-1] | tonumber) else (tonumber * 1000) end] | max // 0' <<<"${nodes}")"
  used="$(kubectl get pods -A -o json | jq --arg node "$(jq -r '.items[0].metadata.name' <<<"${nodes}")" '
    def milli: if . == null then 0 elif endswith("m") then (.[:-1] | tonumber) else (tonumber * 1000) end;
    [.items[]
      | select(.spec.nodeName == $node)
      | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | select(.metadata.labels.app != "resource-burner")
      | [.spec.containers[].resources.requests.cpu | milli] | add // 0] | add // 0')" \
    || { warn "Could not read pod requests; scenario 02 keeps its default sizing"; return 0; }
  free=$(( alloc - used ))
  req=$(( free * 2 / 5 ))
  # >= 50m to stay a meaningful request; <= 550m so 6 replicas plus the apps stay
  # inside the sre-demo ResourceQuota (requests.cpu 4) and pods go Pending, not
  # FailedCreate.
  (( req < 50 )) && req=50
  (( req > 550 )) && req=550
  kubectl -n sre-demo set resources deployment/resource-burner -c resource-burner \
    --requests="cpu=${req}m" >/dev/null \
    || { warn "Could not size the scenario 02 burner"; return 0; }
  ok "Scenario 02 calibrated: ${free}m CPU free on the baseline node, burner requests ${req}m (2 of 6 replicas fit)"
  (( free < 125 )) && warn "Only ${free}m CPU is free at baseline; scenario 02 will show Pending pods but little CPU load."
  return 0
}

step "18/20  Deploying Kubernetes workloads"

# The operator's webhook must exist before sre-demo pods start, or they run
# uninstrumented until their next restart.
dynatrace_install_operator

kubectl apply -f "${REPO_ROOT}/k8s/namespace.yaml" --only-show-errors >/dev/null 2>&1 \
  || kubectl apply -f "${REPO_ROOT}/k8s/namespace.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/rbac/scenario-runner.yaml"

kubectl -n sre-demo create secret generic magic8ball-db \
  --from-literal=password="${PG_APP_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n sre-demo create secret generic magic8ball-telemetry \
  --from-literal=connectionString="${APPI_CONNECTION_STRING}" \
  --from-literal=dynatraceApiUrl="${DT_CLASSIC_URL}" \
  --from-literal=dynatraceIngestToken="${DT_INGEST_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n sre-demo create secret generic scenario-runner-auth \
  --from-literal=token="${RUNNER_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Both certificate pairs live in the cluster; scenario 06 only ever copies
# between them, so no private key passes through the runner or the controller.
VALID_NOT_AFTER="$(openssl x509 -in "${CERT_DIR}/valid.crt" -noout -enddate | cut -d= -f2)"
EXPIRED_NOT_AFTER="$(openssl x509 -in "${CERT_DIR}/expired.crt" -noout -enddate | cut -d= -f2)"

apply_tls_secret() {
  local name="$1" crt="$2" key="$3" variant="$4" not_after="$5"
  kubectl -n sre-demo create secret tls "${name}" --cert="${crt}" --key="${key}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n sre-demo annotate secret "${name}" \
    "sre-demo/cert-variant=${variant}" "sre-demo/cert-not-after=${not_after}" --overwrite >/dev/null
}
apply_tls_secret magic8ball-tls-valid   "${CERT_DIR}/valid.crt"   "${CERT_DIR}/valid.key"   valid   "${VALID_NOT_AFTER}"
apply_tls_secret magic8ball-tls-expired "${CERT_DIR}/expired.crt" "${CERT_DIR}/expired.key" expired "${EXPIRED_NOT_AFTER}"
apply_tls_secret magic8ball-tls         "${CERT_DIR}/valid.crt"   "${CERT_DIR}/valid.key"   valid   "${VALID_NOT_AFTER}"
ok "TLS secrets installed (active certificate: valid)"

render_manifest() {
  sed \
    -e "s|__MAGIC8BALL_STABLE_IMAGE__|${MAGIC8BALL_STABLE_IMAGE}|g" \
    -e "s|__MAGIC8BALL_BAD_IMAGE__|${MAGIC8BALL_BAD_IMAGE}|g" \
    -e "s|__SCENARIO_RUNNER_IMAGE__|${RUNNER_IMAGE}|g" \
    -e "s|__RESOURCE_BURNER_IMAGE__|${BURNER_IMAGE}|g" \
    -e "s|__POSTGRES_HOST__|${PG_PRIVATE_IP}|g" \
    -e "s|__POSTGRES_DB__|${PG_DATABASE}|g" \
    -e "s|__POSTGRES_USER__|${PG_APP_USER}|g" \
    -e "s|__ADMIN_CIDR_LIST__|${ADMIN_CIDR_YAML}|g" \
    -e "s|__APP_VM_CIDR__|${APP_VM_IP}/32|g" \
    -e "s|__LAB_SUFFIX__|${SUFFIX}|g" \
    "$1"
}

render_manifest "${REPO_ROOT}/k8s/resource-pressure/deployment.yaml" | kubectl apply -f -
render_manifest "${REPO_ROOT}/k8s/scenario-runner/deployment.yaml" | kubectl apply -f -
render_manifest "${REPO_ROOT}/k8s/magic8ball/deployment.yaml" | kubectl apply -f -

# Secrets are injected as environment variables, which Kubernetes does not
# refresh in a running pod. Credentials are regenerated on every deploy, so the
# runner must restart or it keeps validating against the previous token and
# rejects the controller with 401.
kubectl -n sre-demo rollout restart deployment/scenario-runner >/dev/null 2>&1 || true
# Same for the Dynatrace ingest token (and OneAgent injection on a re-run).
kubectl -n sre-demo rollout restart deployment/magic8ball >/dev/null 2>&1 || true

info "Waiting for workloads to become ready..."
kubectl -n sre-demo rollout status deployment/scenario-runner --timeout=300s || warn "scenario-runner rollout is slow"
kubectl -n sre-demo rollout status deployment/magic8ball --timeout=420s || warn "magic8ball rollout is slow"

info "Waiting for load balancer addresses..."
wait_for_lb() {
  local service="$1" attempts=60 ip=""
  for _ in $(seq 1 "${attempts}"); do
    ip="$(kubectl -n sre-demo get svc "${service}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "${ip}" ]] && { printf '%s' "${ip}"; return 0; }
    sleep 10
  done
  return 1
}
MAGIC8BALL_IP="$(wait_for_lb magic8ball)" || die "Magic 8 Ball load balancer did not receive an address"
MAGIC8BALL_INTERNAL_IP="$(wait_for_lb magic8ball-internal)" || die "Magic 8 Ball internal load balancer did not receive an address"
RUNNER_IP="$(wait_for_lb scenario-runner)" || die "scenario-runner internal load balancer did not receive an address"
ok "Magic 8 Ball at ${MAGIC8BALL_IP} (public) / ${MAGIC8BALL_INTERNAL_IP} (internal), scenario-runner at ${RUNNER_IP}"

# The certificate must cover BOTH addresses: the public one for the browser and
# the internal one the controller's TLS probe actually connects to.
step "18b/20  Reissuing certificates for the load balancer addresses"
FORCE_REGENERATE=true bash "${REPO_ROOT}/scripts/gen-certs.sh" --force \
  --ip "${MAGIC8BALL_IP}" --ip "${MAGIC8BALL_INTERNAL_IP}" >/dev/null
VALID_NOT_AFTER="$(openssl x509 -in "${CERT_DIR}/valid.crt" -noout -enddate | cut -d= -f2)"
EXPIRED_NOT_AFTER="$(openssl x509 -in "${CERT_DIR}/expired.crt" -noout -enddate | cut -d= -f2)"
apply_tls_secret magic8ball-tls-valid   "${CERT_DIR}/valid.crt"   "${CERT_DIR}/valid.key"   valid   "${VALID_NOT_AFTER}"
apply_tls_secret magic8ball-tls-expired "${CERT_DIR}/expired.crt" "${CERT_DIR}/expired.key" expired "${EXPIRED_NOT_AFTER}"
apply_tls_secret magic8ball-tls         "${CERT_DIR}/valid.crt"   "${CERT_DIR}/valid.key"   valid   "${VALID_NOT_AFTER}"
kubectl -n sre-demo rollout restart deployment/magic8ball >/dev/null
kubectl -n sre-demo rollout status deployment/magic8ball --timeout=300s || warn "magic8ball restart is slow"
ok "Certificates now valid for ${MAGIC8BALL_IP} and ${MAGIC8BALL_INTERNAL_IP}"

# --- 19. App VM -------------------------------------------------------------

step "19/20  Configuring the App VM"
CONTROLLER_ENV_FILE="$(mktemp)"
VM_SCRIPT="$(mktemp)"
trap 'rm -f "${CONTROLLER_ENV_FILE}" "${VM_SCRIPT}"' EXIT

cat > "${VM_SCRIPT}" <<VMSCRIPT
#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /var/log/sre-demo-controller-deploy.log) 2>&1
echo "=== controller deploy \$(date -Is) ==="

# cloud-init owns Docker and the demo disk; wait for it to finish.
for _ in \$(seq 1 120); do
  [ -f /var/log/sre-demo-bootstrap-complete ] && break
  sleep 5
done
[ -f /var/log/sre-demo-bootstrap-complete ] || { echo "cloud-init did not complete"; exit 1; }

mkdir -p ${DEMO_MOUNT_PATH}/logs ${DEMO_MOUNT_PATH}/state ${DEMO_MOUNT_PATH}/certs
chmod 0777 ${DEMO_MOUNT_PATH}/logs ${DEMO_MOUNT_PATH}/state

cat > ${DEMO_MOUNT_PATH}/certs/ca.crt <<'CACERT'
$(cat "${CERT_DIR}/ca.crt")
CACERT
chmod 0644 ${DEMO_MOUNT_PATH}/certs/ca.crt

# Pull from ACR with the VM's managed identity — no registry password anywhere.
# Azure CLI removed --username for managed identity login; --client-id is the
# current form. The fallback keeps this working on older CLI builds.
az login --identity --client-id ${IDENTITY_CLIENT_ID} --only-show-errors >/dev/null 2>&1 \
  || az login --identity --username ${IDENTITY_CLIENT_ID} --only-show-errors >/dev/null
TOKEN=\$(az acr login --name ${ACR_NAME} --expose-token --output tsv --query accessToken)
echo "\${TOKEN}" | docker login ${ACR_LOGIN_SERVER} --username 00000000-0000-0000-0000-000000000000 --password-stdin
docker pull ${CONTROLLER_IMAGE}

cat > /etc/sre-demo-controller.env <<'ENVFILE'
$(cat <<ENV
PORT=8080
LAB_SUFFIX=${SUFFIX}
AZURE_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}
AZURE_RESOURCE_GROUP=${RESOURCE_GROUP}
AZURE_LOCATION=${LOCATION}
AZURE_CLIENT_ID=${IDENTITY_CLIENT_ID}
KEY_VAULT_NAME=${KEY_VAULT_NAME}
APPLICATIONINSIGHTS_CONNECTION_STRING=${APPI_CONNECTION_STRING}
PGHOST=${PG_PRIVATE_IP}
PGPORT=5432
PGDATABASE=${PG_DATABASE}
PGUSER=${PG_APP_USER}
PGPASSWORD=${PG_APP_PASSWORD}
SCENARIO_PGUSER=${PG_SCENARIO_USER}
SCENARIO_PGPASSWORD=${PG_SCENARIO_PASSWORD}
POSTGRES_MAX_CONNECTIONS=${PG_MAX_CONNECTIONS}
DEMO_MOUNT_PATH=${DEMO_MOUNT_PATH}
DEMO_LOG_DIR=${DEMO_MOUNT_PATH}/logs
DEMO_STATE_DIR=${DEMO_MOUNT_PATH}/state
DEMO_CA_CERT_FILE=${DEMO_MOUNT_PATH}/certs/ca.crt
DISK_SCENARIO_TARGET_PERCENT=${DISK_SCENARIO_TARGET_PERCENT:-88}
AKS_CLUSTER_NAME=${AKS_NAME}
AKS_NODE_POOL=system
AKS_BASELINE_NODE_COUNT=${AKS_BASELINE_NODE_COUNT}
K8S_NAMESPACE=sre-demo
DB_NSG_NAME=${DB_NSG_NAME}
APP_SUBNET_PREFIX=10.20.1.0/24
AKS_SUBNET_PREFIX=10.20.3.0/24
SCENARIO_RUNNER_URL=http://${RUNNER_IP}:8090
SCENARIO_RUNNER_TOKEN=${RUNNER_TOKEN}
MAGIC8BALL_HTTP_URL=http://${MAGIC8BALL_INTERNAL_IP}
MAGIC8BALL_HTTPS_URL=https://${MAGIC8BALL_INTERNAL_IP}:443
MAGIC8BALL_PUBLIC_URL=http://${MAGIC8BALL_IP}
MAGIC8BALL_TLS_SERVERNAME=magic8ball.sre-demo.local
MAGIC8BALL_STABLE_IMAGE=${MAGIC8BALL_STABLE_IMAGE}
MAGIC8BALL_BAD_IMAGE=${MAGIC8BALL_BAD_IMAGE}
SCENARIO_TIMEOUT_MINUTES=${SCENARIO_TIMEOUT_MINUTES:-60}
ALLOW_CONCURRENT_SCENARIOS=${ALLOW_CONCURRENT_SCENARIOS:-false}
APP_VERSION=0.1.0
IMAGE_TAG=${IMAGE_TAG}
GIT_COMMIT=${GIT_COMMIT}
BUILD_TIMESTAMP=${BUILD_TIMESTAMP}
DT_API_URL=${DT_CLASSIC_URL}
DT_INGEST_TOKEN=${DT_INGEST_TOKEN}
DT_UI_URL=${DT_APPS_URL}
SNOW_INSTANCE_URL=$([[ "${SERVICENOW_ENABLED}" == "true" ]] && echo "${SNOW_INSTANCE_URL%/}")
SNOW_ASSIGNMENT_GROUP=$([[ "${SERVICENOW_ENABLED}" == "true" ]] && echo "${SNOW_ASSIGNMENT_GROUP}")
ENV
)
ENVFILE
chmod 0600 /etc/sre-demo-controller.env

docker rm -f sre-scenario-controller >/dev/null 2>&1 || true

# Host networking: the container needs IMDS (169.254.169.254) for its managed
# identity, which is not routable from the default bridge network.
docker run -d \\
  --name sre-scenario-controller \\
  --restart unless-stopped \\
  --network host \\
  --env-file /etc/sre-demo-controller.env \\
  -v ${DEMO_MOUNT_PATH}:${DEMO_MOUNT_PATH} \\
  --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \\
  ${CONTROLLER_IMAGE}

sleep 8
for _ in \$(seq 1 30); do
  if curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    echo "controller healthy"
    exit 0
  fi
  sleep 4
done
echo "controller did not become healthy"
docker logs --tail 60 sre-scenario-controller || true
exit 1
VMSCRIPT

info "Running configuration on ${APP_VM_NAME} (this can take a few minutes)..."
RUN_RESULT="$(az vm run-command invoke \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${APP_VM_NAME}" \
  --command-id RunShellScript \
  --scripts "@${VM_SCRIPT}" \
  --query "value[0].message" -o tsv 2>&1 || true)"

if echo "${RUN_RESULT}" | grep -q "controller healthy"; then
  ok "Scenario Controller is running on ${APP_VM_NAME}"
else
  warn "Controller health was not confirmed. Last output:"
  echo "${RUN_RESULT}" | tail -25
fi

# --- 20. Smoke tests and summary -------------------------------------------

# Reconcile the admin rules before testing. Two reasons this is not redundant
# with the Bicep deployment:
#   * Magic 8 Ball sits behind two independent gates (the AKS subnet NSG and the
#     Service's loadBalancerSourceRanges). If they drift, traffic is dropped
#     rather than refused and the browser hangs with no error.
#   * Defender for Cloud and similar governance tooling remove permissive
#     inbound rules after deployment; the SSH rule in particular can disappear.
step "20/20  Reconciling administrator access and running smoke tests"

reconcile_rule() {
  local nsg="$1" rule="$2" port="$3" priority="$4" description="$5"
  if az network nsg rule show -g "${RESOURCE_GROUP}" --nsg-name "${nsg}" -n "${rule}" -o none 2>/dev/null; then
    az network nsg rule update -g "${RESOURCE_GROUP}" --nsg-name "${nsg}" -n "${rule}" \
      --source-address-prefixes "${ADMIN_CIDRS[@]}" -o none 2>/dev/null \
      && ok "${nsg}/${rule}: ${ADMIN_CIDRS[*]}" \
      || warn "Could not update ${nsg}/${rule}"
  else
    warn "${nsg}/${rule} was missing (governance tooling may have removed it); recreating"
    az network nsg rule create -g "${RESOURCE_GROUP}" --nsg-name "${nsg}" -n "${rule}" \
      --priority "${priority}" --direction Inbound --access Allow --protocol Tcp \
      --source-address-prefixes "${ADMIN_CIDRS[@]}" \
      --destination-port-ranges ${port} --destination-address-prefixes '*' \
      --description "${description}" -o none 2>/dev/null \
      && ok "${nsg}/${rule}: recreated" \
      || warn "Could not recreate ${nsg}/${rule}"
  fi
}

reconcile_rule "nsg-app-${SUFFIX}" Allow-SSH-Admin 22 200 "Administrative SSH, restricted to the administrator CIDRs."
reconcile_rule "nsg-app-${SUFFIX}" Allow-Controller-UI-Admin "${CONTROLLER_PORT:-8080}" 210 "Scenario Controller UI and API, restricted to the administrator CIDRs."
reconcile_rule "nsg-aks-${SUFFIX}" Allow-Magic8Ball-From-Admin "80 443" 200 "HTTP/HTTPS to Magic 8 Ball, restricted to the administrator CIDRs."

# Keep the Service in step with the NSG so the two gates cannot disagree.
kubectl -n sre-demo patch svc magic8ball --type=merge \
  -p "{\"spec\":{\"loadBalancerSourceRanges\":${ADMIN_CIDRS_JSON}}}" >/dev/null 2>&1 \
  && ok "magic8ball load balancer: ${ADMIN_CIDRS[*]}" \
  || warn "Could not patch the magic8ball service source ranges"
CONTROLLER_URL="http://${APP_VM_IP}:8080"
MAGIC8BALL_URL="http://${MAGIC8BALL_IP}"

smoke() {
  local label="$1" url="$2"
  # Retries: right after the controller restarts, /api/lab/status gathers
  # component state from Azure and its first call can exceed the timeout.
  local attempt
  for attempt in 1 2 3; do
    if curl -fsS --max-time 30 "${url}" >/dev/null 2>&1; then ok "${label}"; return 0; fi
    sleep 10
  done
  fail "${label} (${url})"
}
smoke "Scenario Controller health" "${CONTROLLER_URL}/api/health"
smoke "Scenario Controller lab status" "${CONTROLLER_URL}/api/lab/status"
smoke "Magic 8 Ball health" "${MAGIC8BALL_URL}/healthz"
smoke "Magic 8 Ball version" "${MAGIC8BALL_URL}/api/version"
dynatrace_wait_dynakube
calibrate_resource_pressure

cat > "${STATE_FILE}" <<STATE
{
  "suffix": "${SUFFIX}",
  "subscriptionId": "${SUBSCRIPTION_ID}",
  "subscriptionName": "${SUBSCRIPTION_NAME}",
  "tenantId": "${TENANT_ID}",
  "location": "${LOCATION}",
  "resourceGroup": "${RESOURCE_GROUP}",
  "adminCidr": "${ADMIN_CIDR}",
  "acrName": "${ACR_NAME}",
  "acrLoginServer": "${ACR_LOGIN_SERVER}",
  "imageTag": "${IMAGE_TAG}",
  "gitCommit": "${GIT_COMMIT}",
  "keyVaultName": "${KEY_VAULT_NAME}",
  "appInsightsName": "${APPI_NAME}",
  "logAnalyticsName": "${LAW_NAME}",
  "logAnalyticsId": "${LAW_ID}",
  "appVmName": "${APP_VM_NAME}",
  "appVmPublicIp": "${APP_VM_IP}",
  "appVmFqdn": "${APP_VM_FQDN}",
  "postgresVmName": "${PG_VM_NAME}",
  "postgresPrivateIp": "${PG_PRIVATE_IP}",
  "postgresDatabase": "${PG_DATABASE}",
  "postgresAppUser": "${PG_APP_USER}",
  "postgresMaxConnections": "${PG_MAX_CONNECTIONS}",
  "aksName": "${AKS_NAME}",
  "aksNodeResourceGroup": "${AKS_NODE_RG}",
  "aksNodeSize": "${SELECTED_AKS_SKU}",
  "aksBaselineNodeCount": "${AKS_BASELINE_NODE_COUNT}",
  "aksKubernetesVersion": "${AKS_K8S_VERSION}",
  "databaseNsgName": "${DB_NSG_NAME}",
  "kubeconfig": "${KUBECONFIG_PATH}",
  "sshKey": "${SSH_KEY_PATH}",
  "adminUsername": "${ADMIN_USERNAME}",
  "controllerUrl": "${CONTROLLER_URL}",
  "magic8ballUrl": "${MAGIC8BALL_URL}",
  "magic8ballHttpsUrl": "https://${MAGIC8BALL_IP}",
  "magic8ballIp": "${MAGIC8BALL_IP}",
  "magic8ballInternalIp": "${MAGIC8BALL_INTERNAL_IP}",
  "scenarioRunnerIp": "${RUNNER_IP}",
  "sreAgentName": "${SRE_AGENT_NAME}",
  "sreAgentId": "${SRE_AGENT_ID}",
  "sreAgentLocation": "${SRE_AGENT_REGION}",
  "sreAgentMode": "${SRE_AGENT_MODE}",
  "sreAgentPrincipalId": "${SRE_AGENT_PRINCIPAL_ID}",
  "sreAgentEndpoint": "${SRE_AGENT_ENDPOINT}",
  "dynatraceEnabled": ${DYNATRACE_ENABLED},
  "dynatraceEnvironmentId": "${DT_ENV_ID}",
  "dynatraceUrl": "${DT_APPS_URL}",
  "dynatraceApiUrl": "${DT_CLASSIC_URL}",
  "dynatraceAksHostGroup": "${DT_AKS_HOST_GROUP}",
  "dynatraceVmHostGroup": "${DT_VM_HOST_GROUP}",
  "dynatraceProblemTitlePrefix": "${DT_TITLE_PREFIX:-}",
  "servicenowEnabled": ${SERVICENOW_ENABLED},
  "servicenowInstanceUrl": "$([[ "${SERVICENOW_ENABLED}" == "true" ]] && echo "${SNOW_INSTANCE_URL%/}")",
  "servicenowAssignmentGroup": "$([[ "${SERVICENOW_ENABLED}" == "true" ]] && echo "${SNOW_ASSIGNMENT_GROUP}")",
  "servicenowIntegrationUser": "$([[ "${SERVICENOW_ENABLED}" == "true" ]] && echo "${SNOW_INTEGRATION_USER}")",
  "deployedAt": "${BUILD_TIMESTAMP}"
}
STATE
chmod 600 "${STATE_FILE}"

# An Autonomous agent with read-only roles would investigate, decide on a fix
# and then fail to apply it. --agent-mode Autonomous is the explicit opt-in to
# write access, so grant Contributor at the demo resource group (never wider).
AGENT_REMEDIATION_OK=false
if [[ -n "${SRE_AGENT_NAME}" && -n "${SRE_AGENT_PRINCIPAL_ID}" && "${SRE_AGENT_MODE}" == "Autonomous" ]]; then
  step "Granting the Autonomous SRE Agent remediation access (Contributor, resource group scope)"
  if ASSUME_YES=true "${REPO_ROOT}/scripts/enable-sre-remediation.sh" --agent-principal-id "${SRE_AGENT_PRINCIPAL_ID}"; then
    AGENT_REMEDIATION_OK=true
  else
    warn "Could not grant Contributor; re-run ./scripts/enable-sre-remediation.sh --agent-principal-id ${SRE_AGENT_PRINCIPAL_ID}"
  fi
fi

AGENT_INTEGRATIONS_OK=false
if [[ -n "${SRE_AGENT_NAME}" && "${DYNATRACE_ENABLED}" == "true" ]]; then
  step "Connecting the SRE Agent to Dynatrace and ServiceNow"
  # Runs in a child process: a failure here must not hide the deploy summary.
  if "${REPO_ROOT}/scripts/configure-sre-agent-integrations.sh"; then
    AGENT_INTEGRATIONS_OK=true
  else
    warn "Agent integration setup failed; re-run ./scripts/configure-sre-agent-integrations.sh"
  fi
fi
ELAPSED=$(( $(date +%s) - START_TIME ))
INTEGRATIONS_SUMMARY=""
if [[ "${DYNATRACE_ENABLED}" == "true" ]]; then
  INTEGRATIONS_SUMMARY+="  Dynatrace           : ${DT_APPS_URL} (host groups ${DT_AKS_HOST_GROUP}, ${DT_VM_HOST_GROUP})
  Dynatrace problems  : ${DT_APPS_URL}/ui/apps/dynatrace.davis.problems/
"
fi
if [[ "${SERVICENOW_ENABLED}" == "true" ]]; then
  INTEGRATIONS_SUMMARY+="  ServiceNow          : ${SNOW_INSTANCE_URL%/} (group '${SNOW_ASSIGNMENT_GROUP}', user ${SNOW_INTEGRATION_USER})
  ServiceNow password : az keyvault secret show --subscription ${SUBSCRIPTION_ID} --vault-name ${KEY_VAULT_NAME} -n servicenow-integration-password --query value -o tsv
"
fi
if [[ -n "${SRE_AGENT_NAME}" ]]; then
  SRE_AGENT_SUMMARY="  SRE Agent           : ${SRE_AGENT_NAME} (${SRE_AGENT_REGION}, mode ${SRE_AGENT_MODE})
  SRE Agent UI        : ${SRE_AGENT_ENDPOINT}
"
  if [[ "${AGENT_REMEDIATION_OK}" == "true" ]]; then
    SRE_AGENT_NEXT_STEP="  4. The agent is Autonomous with Contributor on this resource group. Revoke after the demo:
     ./scripts/enable-sre-remediation.sh --agent-principal-id ${SRE_AGENT_PRINCIPAL_ID} --revoke
"
  else
    SRE_AGENT_NEXT_STEP="  4. Grant the agent access to this resource group:
     ./scripts/enable-sre-remediation.sh --agent-principal-id ${SRE_AGENT_PRINCIPAL_ID}
"
  fi
  SRE_AGENT_NEXT_STEP+="  5. Follow docs/AZURE-SRE-AGENT-SETUP.md to connect GitHub and run the first investigation.
"
  if [[ "${SERVICENOW_ENABLED}" == "true" ]]; then
    if [[ "${AGENT_INTEGRATIONS_OK}" != "true" ]]; then
      SRE_AGENT_NEXT_STEP+="  6. Connect the agent to ServiceNow and Dynatrace (docs/SERVICENOW-SETUP.md):
     ./scripts/configure-sre-agent-integrations.sh
"
    fi
  fi
else
  SRE_AGENT_SUMMARY=""
  SRE_AGENT_NEXT_STEP="  4. Follow docs/AZURE-SRE-AGENT-SETUP.md to connect an Azure SRE Agent,
     or redeploy with --with-agent to have one created for you.
"
fi

cat <<SUMMARY

${C_BOLD}${C_GREEN}Azure SRE Agent Demo Lab deployed in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s${C_RESET}

  Scenario Controller : ${CONTROLLER_URL}
  Magic 8 Ball        : ${MAGIC8BALL_URL}
  Magic 8 Ball (TLS)  : https://${MAGIC8BALL_IP}

  Subscription        : ${SUBSCRIPTION_NAME}
  Region              : ${LOCATION}
  Resource group      : ${RESOURCE_GROUP}
  AKS                 : ${AKS_NAME} (${SELECTED_AKS_SKU}, ${AKS_BASELINE_NODE_COUNT} node, k8s ${AKS_K8S_VERSION})
  Application Insights: ${APPI_NAME}
  Log Analytics       : ${LAW_NAME}
  Key Vault           : ${KEY_VAULT_NAME}
${SRE_AGENT_SUMMARY}${INTEGRATIONS_SUMMARY}
  SSH                 : ssh -i ${SSH_KEY_PATH} ${ADMIN_USERNAME}@${APP_VM_IP}
  kubectl             : export KUBECONFIG=${KUBECONFIG_PATH}

Next steps:
  1. Open the Scenario Controller and confirm all components are HEALTHY.
  2. Wait 5-10 minutes for telemetry to reach Application Insights.
  3. Run ./scripts/validate.sh to confirm the whole lab end to end.
${SRE_AGENT_NEXT_STEP}
Lab state written to .lab-state.json (git-ignored).
SUMMARY
