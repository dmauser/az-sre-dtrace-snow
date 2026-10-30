# Azure SRE Agent — setup for the demo lab

This document covers the Azure SRE Agent for a deployed lab: creating the agent, connecting the
GitHub repository, granting scoped access, verifying it can see the telemetry, and running the
first investigation.

> **What is automated, and what is not.** `scripts/deploy.sh --with-agent` creates the agent
> for you, wires it to the lab's Application Insights and prints the command to grant it
> access. Two things remain human decisions rather than script steps: **GitHub connector
> consent**, which requires an interactive OAuth approval, and **granting the agent write
> access**, which is deliberately a separate command.
>
> The agent is opt-in. Without `--with-agent` nothing is created, and the lab still deploys
> and runs completely — `scripts/deploy.sh` never fails because no agent is connected.
>
> **It is also the most expensive part of the lab.** Azure SRE Agent bills a fixed always-on
> charge of 4 Azure Agent Units per hour (~$0.40/hour), plus token-based usage while it works.
> That is more than every other resource combined, and `stop-lab.sh` does **not** stop it —
> the agent has no stopped state. Delete it or destroy the lab if it will sit idle.

---

## Before you start

You need:

- a deployed lab (`./scripts/deploy.sh` completed, `./scripts/validate.sh` green);
- **Owner** or **User Access Administrator** on the demo resource group, to grant the agent access;
- a region where Azure SRE Agent is available — it is **not** offered in `eastus`, the default
  lab region, so `--with-agent` requires `--location`/`--agent-location` to name one that is;
- 10–15 minutes of telemetry accumulated, so the agent has something to read.

Collect your lab details:

```bash
jq -r '{subscriptionId, resourceGroup, location, appInsightsName, logAnalyticsName, aksName}' .lab-state.json
```

If you deployed with `--with-agent`, the agent's own details are there too:

```bash
jq -r '{sreAgentName, sreAgentLocation, sreAgentMode, sreAgentPrincipalId}' .lab-state.json
```

---

## 1. Create or select an Azure SRE Agent

### With the deployment (recommended)

`deploy.sh` can create the agent for you. It is opt-in because the agent is chargeable and is
not offered in every region the lab runs in:

```bash
./scripts/deploy.sh --location eastus2 --with-agent --agent-mode Review
```

`--agent-mode` is `ReadOnly` (investigate only), `Review` (default — pause for human approval
before each remediation) or `Autonomous` (act unattended). Use `--agent-location` when the lab
region does not offer SRE Agent; the agent may sit in a different region from the lab.

SRE Agent is **not available in `eastus`**, the default lab region. `deploy.sh` checks before
deploying and prints the regions that do offer it.

The agent is created with a system-assigned identity and no role assignments. Its name,
region, mode and principal ID are written to `.lab-state.json`, and the principal ID is
printed at the end of the deployment for step 3.

An existing lab can gain an agent by re-running the deployment with the same `--suffix` and
adding `--with-agent`; the deployment is idempotent.

### Portal

1. Sign in to the [Azure portal](https://portal.azure.com).
2. Search for **SRE Agent** and open the service.
3. Select **Create**.
4. Configure:
   - **Subscription** — the subscription hosting the lab.
   - **Resource group** — create `rg-sre-agent-<suffix>` to keep the agent separate from the
     resources it observes, so a `destroy-lab` of the demo group does not remove the agent.
   - **Name** — for example `sre-agent-demo-<suffix>`.
   - **Region** — a region where the service is offered; it does not have to match the lab.
5. Create, and wait for provisioning to finish.

### Checking availability yourself

`deploy.sh --with-agent` performs this check for you and refuses to continue with the list of
valid regions. To check by hand:

```bash
az provider register --namespace Microsoft.App --wait
az provider show --namespace Microsoft.App \
  --query "resourceTypes[?resourceType=='agents'].locations[]" -o tsv
```

If that returns nothing, the provider is unavailable in your tenant and the agent has to be
created in the portal.

The same behaviour is available from `.env` via `WITH_AGENT`, `AGENT_MODE` and
`AGENT_LOCATION`, so a saved configuration deploys an agent without repeating the flags.

### Both managed identities are required

The agent is created with **system-assigned and user-assigned identities together**. The
user-assigned identity carries connector authentication and Azure RBAC; the system-assigned one
backs the agent's own infrastructure.

This is not cosmetic. An agent created with `type: 'UserAssigned'` alone provisions
successfully and runs, but lands on the **Public Preview generation**, and the portal then
offers:

> *A newer version of SRE Agent is available. This agent was created during Public Preview.
> Migrate to get an improved sandbox, code and file access, log-to-code investigation, better
> memory, and updated approval controls.*

Nothing in the resource reveals this. `upgradeChannel` reads `Stable`, the template already
targets the generally available API (`Microsoft.App/agents@2026-01-01`), both API versions
return an identical property set, and the properties behind the newer experience
(`sandboxConfiguration`, `experimentalSettings`, `firstPartyConfiguration`) are read-only and
null. The banner in the agent UI is the only signal.

With `type: 'SystemAssigned,UserAssigned'` the agent is created on the current generation and
the banner does not appear — verified by deleting a preview-generation agent and redeploying.

If you have an older agent showing that banner, either select **Migrate** in the portal, or
delete it and redeploy with `--with-agent`. Redeploying loses the agent's accumulated memory
and connections, and issues a new principal ID, so re-run `enable-sre-remediation.sh`
afterwards.

---

## 2. Connect the private GitHub repository

Connecting the repository lets the agent correlate an incident with the code and configuration
that caused it — which is what makes scenario 03 land properly.

`scripts/configure-sre-agent-integrations.sh` (run by `deploy.sh`) registers `GITHUB_REPO`
(default `dmauser/az-sre-dtrace-snow`) under **Builder → Code access** with the same data-plane
call the portal makes (`PUT /api/v2/repos/<name>`, type `GitHub`). Registering is not enough:
the repository is private, so until the agent holds a GitHub credential it cannot clone it and
the script prints:

```text
WARN Agent cannot read dmauser/az-sre-dtrace-snow yet: GitHub API returned NotFound ... "status":"404"
```

GitHub answers 404, not 403, for a private repository the caller cannot see. Authenticate the
agent once, using one of the two options below.

### Option A — authorize GitHub in the portal (OAuth, recommended)

This is how the reference lab is authenticated. It is a one-time, interactive step per agent.

1. Open the [Azure SRE Agent portal](https://sre.azure.com) and select your agent
   (`sre-agent-<suffix>`).
2. Go to **Builder → Code access**. The repository `az-sre-dtrace-snow` is already listed
   (added by the script).
3. Select the repository and choose **Authorize** (or **Sign in with GitHub**).
4. In the GitHub pop-up, sign in as an account that can read the repository (the owner, e.g.
   `dmauser`), and approve the requested access. If GitHub asks which repositories to grant,
   include `az-sre-dtrace-snow` — a private repository must be selected explicitly.
5. Back in the portal, confirm the repository shows as connected and its clone completes.
6. Verify from the command line:

   ```bash
   ./scripts/configure-sre-agent-integrations.sh   # GitHub section: PASS Agent can read dmauser/az-sre-dtrace-snow
   ./scripts/validate.sh                           # PASS Agent can read dmauser/az-sre-dtrace-snow
   ```

The authorization is stored on the agent (connection `github.com|<your-github-user>`, auth
type `OAuth`), not in `.env`, so it survives re-running `deploy.sh` and the configure script.
It is lost only if the agent itself is deleted and recreated — then repeat these steps.

### Option B — fine-grained personal access token (scripted)

Use this where interactive consent is not possible (automation, or GitHub org policy blocks the
OAuth app).

1. GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens →
   Generate new token**.
2. **Repository access:** *Only select repositories* → `az-sre-dtrace-snow`.
3. **Permissions:** *Contents: Read-only* and *Metadata: Read-only*. Nothing else.
4. Put it in `.env` as `GITHUB_PAT=` (or paste it when `scripts/setup-integrations.ps1` asks —
   it checks the token can read the repository before saving it). `.env` is git-ignored.
5. Run `./scripts/configure-sre-agent-integrations.sh`. It stores the token on the agent
   (`PUT /api/v2/github/domains/github_com`) and tests access.

Fine-grained tokens expire; when access starts failing, rotate the token and re-run step 5.

### Checking the connection

| Signal | Authenticated | Not authenticated |
|--------|---------------|-------------------|
| Configure script, GitHub section | `PASS Agent can read ...` | `WARN Agent cannot read ... yet` (404) |
| `validate.sh` | `PASS Agent can read ...` | `SKIP Agent cannot read ... yet` |
| `GET /api/v2/repos` on the agent | `cloneStatus: Ready`, `connection.authType: OAuth` (or PAT) | no connection, clone fails |

`validate.sh` treats missing authorization as a skip, not a failure, because only a human can
grant it; the lab is fully functional without code access, the agent just cannot cite source.

What the agent gains: the Bicep templates, Kubernetes manifests, application source and
`docs/scenarios/` — so it can reason about intended state, not just observed state.

---

## 3. Give the agent access to the demo resource group

### First: your own access to the agent

Azure SRE Agent has **two independent permission planes**, and this catches people out:

| Plane | Governs | Roles |
|---|---|---|
| Control plane | Creating, reading and deleting the `Microsoft.App/agents` **resource** | Owner, Contributor, Reader |
| Data plane | Opening and using the **agent itself** at its `*.azuresre.ai` endpoint | SRE Agent Reader / Standard User / Author / Administrator |

**Subscription Owner grants you none of the data-plane roles.** Without one, the agent endpoint
returns HTTP 401 and the UI reports *"Taking longer than usual… Your agent may be cold-starting,
or there may be network issues"* — which is misleading, since the agent is running fine.

`deploy.sh --with-agent` assigns the deploying principal **SRE Agent Administrator** on the
agent, so this is already done for you. For anyone else who needs access:

```bash
AGENT_ID=$(jq -r .sreAgentId .lab-state.json)
az role assignment create --assignee <user-object-id> \
  --role "SRE Agent Administrator" --scope "$AGENT_ID"
```

Use **SRE Agent Reader** or **Standard User** for people who should watch but not configure.

To confirm access from the command line:

```bash
TOKEN=$(az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  "$(jq -r .sreAgentEndpoint .lab-state.json)"     # 200 = you have access, 401 = you do not
```

### Then: the agent's access to the lab

The agent needs a managed identity with read access to the lab. **`deploy.sh --with-agent`
grants this automatically** (step 13b), so if you deployed that way there is nothing to do here
— skip to Verify below. The six roles it grants are also exactly what the Azure portal's own
**Managed resources -> Add resource group** flow (Permission level: Reader) requires, so that
flow shows them as already granted instead of asking you to add them again.

If you need to grant them by hand — an existing agent gaining access to a new lab, or a lab
deployed before this was automated — run:

```bash
RG=$(jq -r .resourceGroup .lab-state.json)
SUB=$(jq -r .subscriptionId .lab-state.json)
SCOPE="/subscriptions/${SUB}/resourceGroups/${RG}"

# Deployed with --with-agent? The principal ID is already recorded.
# Otherwise take it from the portal: your agent -> Identity -> Object ID.
AGENT_PRINCIPAL_ID=$(jq -r '.sreAgentPrincipalId // empty' .lab-state.json)

# Read-only to begin with — enough for detection and investigation.
az role assignment create --assignee "$AGENT_PRINCIPAL_ID" --role "Reader"                      --scope "$SCOPE"
az role assignment create --assignee "$AGENT_PRINCIPAL_ID" --role "Monitoring Reader"           --scope "$SCOPE"
az role assignment create --assignee "$AGENT_PRINCIPAL_ID" --role "Log Analytics Reader"        --scope "$SCOPE"
az role assignment create --assignee "$AGENT_PRINCIPAL_ID" --role "Azure Kubernetes Service Cluster User Role" --scope "$SCOPE"
az role assignment create --assignee "$AGENT_PRINCIPAL_ID" --role "Azure Kubernetes Service RBAC Reader" --scope "$SCOPE"
az role assignment create --assignee "$AGENT_PRINCIPAL_ID" --role "HDInsight Cluster Operator"  --scope "$SCOPE"
```

> The last two roles (AKS RBAC Reader, HDInsight Cluster Operator) are not otherwise used by
> this lab — there is no HDInsight resource here — but they are part of the fixed role set the
> portal's "Managed resources" flow expects, so they are granted for consistency with it.

None of the six roles above cover `Microsoft.Compute/virtualMachines/runCommand/action`.
`Reader` only ever grants `*/read` actions, and running a diagnostic script on a VM
(`az vm run-command invoke`) is an action, not a read — so scenarios that need the agent to
inspect VM-level state (services, config files, logs on the App/Postgres VMs; e.g. **Scenario
04, Database Connection Exhaustion**) fail instantly with *"Agent permissions were used, but
the action failed to run"*, even with all six read roles in place. The only built-in roles that
include `runCommand/action` (e.g. Virtual Machine Contributor) bundle full VM write/delete/
start/stop/deallocate power, which this lab deliberately keeps separate as write access via
`scripts/enable-sre-remediation.sh`. So `deploy.sh --with-agent` also creates and grants a
purpose-built **custom role**, `SRE Demo Lab VM Diagnostics - <suffix>`, scoped to the lab
resource group, containing only:

- `Microsoft.Compute/virtualMachines/runCommand/action`
- `Microsoft.Compute/virtualMachines/read`
- `Microsoft.Compute/virtualMachines/instanceView/read`

### Permission level (accessLevel): why RBAC alone is not enough

Granting the roles above is necessary but **not sufficient** for action-type diagnostics such
as Scenario 04. The Azure SRE Agent resource itself carries a separate authorization gate,
`actionConfiguration.accessLevel`, independent of Azure RBAC:

- **Low (Reader)** — the conservative choice, but it means the agent's own managed identity is
  *never* used to execute action-type calls (like `runCommand/action`), no matter what RBAC you
  grant it directly. Every such call is instead routed through an on-behalf-of (OBO) elevation
  of whichever human is approving the action in the UI at that moment. If that human lacks the
  underlying permission, the call fails with *"Agent permissions were used, but the action
  failed to run"* — which looks like a missing-RBAC error but isn't.
- **High (Privileged)** — the agent's own identity (and the RBAC granted to it, including the
  custom VM Diagnostics role above) is used directly. `deploy.sh --with-agent` sets this by
  default (`infra/bicep/modules/sre-agent.bicep`, `accessLevel` parameter).

`accessLevel` is independent of `mode` (ReadOnly/Review/Autonomous): raising it to High does
**not** bypass Review mode's human-approval pause — it only changes *whose identity* runs the
action once a human approves it.

To check or change it on an existing agent:

```bash
AGENT_ID=$(az resource list -g "$RESOURCE_GROUP" --resource-type Microsoft.App/agents --query "[0].id" -o tsv)
az resource show --ids "$AGENT_ID" --query properties.actionConfiguration -o json

# Patch to High — must include mode and identity in the same call; ARM does not
# deep-merge actionConfiguration, so omitting them nulls them out.
az rest --method patch --uri "https://management.azure.com${AGENT_ID}?api-version=2026-01-01" \
  --body '{"properties":{"actionConfiguration":{"accessLevel":"High","mode":"Review","identity":"<identity-resource-id-from-above>"}}}'
```

If you need to grant it by hand:

```bash
SUFFIX=$(jq -r .suffix .lab-state.json)
ROLE_NAME="SRE Demo Lab VM Diagnostics - ${SUFFIX}"

cat > /tmp/vm-diag-role.json <<EOF
{
  "Name": "${ROLE_NAME}",
  "IsCustom": true,
  "Description": "Run diagnostic scripts on the SRE demo lab VMs via the platform run-command channel, without any other VM write/delete/lifecycle permission.",
  "Actions": [
    "Microsoft.Compute/virtualMachines/runCommand/action",
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/instanceView/read"
  ],
  "AssignableScopes": [ "$SCOPE" ]
}
EOF
az role definition create --role-definition /tmp/vm-diag-role.json
az role assignment create --assignee "$AGENT_PRINCIPAL_ID" --role "$ROLE_NAME" --scope "$SCOPE"
```

Verify:

```bash
az role assignment list --assignee "$AGENT_PRINCIPAL_ID" --scope "$SCOPE" -o table
```

**Scope discipline:** grant at the demo resource group, never at the subscription. If your
agent covers several environments, add each resource group individually.

---

## 4. Verify Application Insights access

```bash
APPI=$(jq -r .appInsightsName .lab-state.json)
RG=$(jq -r .resourceGroup .lab-state.json)

az monitor app-insights component show -g "$RG" -a "$APPI" --query "{name:name, appId:appId}" -o table
```

Confirm telemetry is arriving:

```bash
az monitor app-insights query -g "$RG" -a "$APPI" \
  --analytics-query "AppRequests | where TimeGenerated > ago(30m) | summarize count() by AppRoleName" -o table
```

You should see rows for `scenario-controller` and `magic8ball`. If empty, wait a further five
minutes — first ingestion can lag.

In the agent, confirm Application Insights appears as a discovered data source.

---

## 5. Verify Log Analytics access

```bash
LAW=$(jq -r .logAnalyticsName .lab-state.json)
RG=$(jq -r .resourceGroup .lab-state.json)
WORKSPACE_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query customerId -o tsv)

az monitor log-analytics query --workspace "$WORKSPACE_ID" \
  --analytics-query "union AppMetrics, AppRequests, Perf, KubePodInventory | where TimeGenerated > ago(30m) | summarize Rows=count() by Type" -o table
```

Expect `AppMetrics`, `AppRequests`, `Perf` and `KubePodInventory`. The custom demo metrics live
in `AppMetrics`:

```bash
az monitor log-analytics query --workspace "$WORKSPACE_ID" \
  --analytics-query 'AppMetrics | where Name startswith "sre_demo_" | summarize Latest=max(TimeGenerated) by Name' -o table
```

You should see `sre_demo_disk_percent_used`, `sre_demo_postgres_connection_percent`,
`sre_demo_postgres_connectivity`, `sre_demo_magic8ball_tls_valid`,
`sre_demo_magic8ball_http_success` and others.

---

## 6. Verify Azure Monitor access

The lab creates six scheduled query alert rules:

```bash
az monitor scheduled-query list -g "$RG" --query "[].{Name:name, Enabled:enabled, Severity:severity}" -o table
```

Expect rules for disk capacity, AKS node pressure, pending pods, HTTP failure rate, PostgreSQL
connections, PostgreSQL connectivity and TLS validation.

Confirm the agent can enumerate them — this is how it learns what "abnormal" means in this
environment. Check fired alerts during a scenario with:

```bash
az monitor activity-log alert list -g "$RG" -o table
az rest --method get --url "https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview" \
  --query "value[].{name:properties.essentials.alertRule, state:properties.essentials.monitorCondition, fired:properties.essentials.startDateTime}" -o table
```

---

## 7. Verify AKS diagnostics

```bash
AKS=$(jq -r .aksName .lab-state.json)

az aks show -g "$RG" -n "$AKS" --query "addonProfiles.omsagent.enabled"
```

This must return `true` — Container Insights is what gives the agent pod state, node capacity
and container logs.

```bash
az monitor log-analytics query --workspace "$WORKSPACE_ID" \
  --analytics-query 'KubePodInventory | where TimeGenerated > ago(15m) | where Namespace == "sre-demo" | summarize by Name, PodStatus' -o table
```

For the agent to inspect the cluster directly, it needs
**Azure Kubernetes Service Cluster User Role** (granted in step 3) and, if the cluster uses
Azure RBAC for Kubernetes authorisation, also
**Azure Kubernetes Service RBAC Reader**.

---

## 8. Run the first investigation

Start with scenario 01 — self-contained, fast and unambiguous.

1. Open the Scenario Controller and confirm every component is **HEALTHY**.
2. Inject **01 — Disk Capacity Exhaustion**.
3. Watch the App VM card climb past 85%; this takes about 60–90 seconds.
4. Wait 3–5 minutes for `SRE Demo 01 - App VM demo disk capacity` to fire.
5. Give the agent:

   ```
   Investigate why the application VM is reporting low disk capacity.
   Identify the root cause and propose a safe mitigation.
   ```

6. A good investigation identifies the VM, the mount point `/var/sre-demo`, the growing
   `logs` directory, the largest files, `app=checkout-suite` with `retry_storm=true` in the log
   lines, and an approximate growth rate — then proposes stopping the logger and reclaiming the
   files rather than simply enlarging the disk.
7. Press **Verify**, then **Reset**.

Prompts and expected findings for all six scenarios:
**[SRE-DEMO-RUNBOOK.md](SRE-DEMO-RUNBOOK.md)**.

---

## 9. Connect Dynatrace and ServiceNow

Run automatically by `deploy.sh --with-agent` when Dynatrace is enabled; re-run any time:

```bash
./scripts/configure-sre-agent-integrations.sh
```

**Dynatrace (automated).** The script checks that `DT_PLATFORM_TOKEN` can reach the Dynatrace
remote MCP gateway, then creates an MCP connector on the agent through ARM:

```text
PUT .../providers/Microsoft.App/agents/<agent>/connectors/dynatrace-mcp
    dataConnectorType: Mcp · transport: http · authType: BearerToken · partnerType: DynatraceMcp
    endpoint: https://<env-id>.apps.dynatrace.com/platform-reserved/mcp-gateway/v0.1/servers/dynatrace-mcp/mcp
```

Once connected, the agent can call tools such as `query-problems`, `get-problem-by-id`,
`execute-dql` and `get-events-for-kubernetes-cluster`. Token scopes:
[DYNATRACE-SETUP.md](DYNATRACE-SETUP.md#3-platform-token--dt_platform_token-dt0s16).
The API version can be overridden with `SRE_AGENT_CONNECTOR_API_VERSION`.

This is the same body the portal sends from **Builder → Connectors → Dynatrace**; `partnerType`
makes the portal list it as the Dynatrace connector rather than a generic MCP server.

The script then confirms from the agent's side that the connector is **Connected** and lists
its tools (`GET /api/v2/extendedAgent/connectors/dynatrace-mcp/tools`). ARM returns the
connector's endpoint as `null`; that is redaction, not a missing value.

**Exposing the tools to the agent.** A connected MCP server is not enough: its tools reach chat
and incident investigations only when they are selected for the agent
([MCP connector, step 2](https://learn.microsoft.com/azure/sre-agent/mcp-connector#step-2-select-tools-for-your-agent)).
The portal pre-selects them when you add a connector by hand; a connector created through ARM has
none, and the agent then reports that `dynatrace-mcp` is connected but its tool search finds
nothing. The script writes all discovered tools back to the connector, as the portal's
**Edit → MCP Tools** picker does:

```text
extendedProperties.toolsVisibleToMetaAgent: ["dynatrace-mcp_execute-dql", "dynatrace-mcp_query-problems", ...]
extendedProperties.selectedTools:           ["execute-dql", "query-problems", ...]
```

`validate.sh` checks that list is not empty. To fix it by hand: **Builder → Connectors →
dynatrace-mcp → Edit → MCP Tools → Select all → Save** (the agent has an 80-tool limit; the
Dynatrace server has 21).

**Scenario logs in Dynatrace.** OneAgent only discovers system logs on its own, so Terraform
(`infra/terraform/integration/dynatrace-logs.tf`) adds a custom log source for the scenario 01
log files in `/var/sre-demo/logs`. A run writes about 2 GB, so storage rules keep only the
`retry_storm=true` error lines and drop the rest; `deploy.sh` moves both rules above the built-in
ones, because storage rules are first-match-wins. The agent finds them with:

```text
fetch logs | filter contains(log.source, "sre-demo-scenario-01") or contains(content, "retry_storm=true")
```

Storage rules are pulled by OneAgent every few minutes; lines read before then follow the
built-in rules, so the first run after a fresh deploy can still store INFO/WARN lines.

The other scenarios need no extra log source: their evidence is already in container and
database logs that OneAgent ingests by default. Both apps print one JSON line per failure to
stdout/stderr (Application Insights alone is invisible to Dynatrace), and the controller's probe
loop logs every degraded signal with its cause every 20 seconds, tagged `scenario.id`.

| Scenario | Log evidence in Dynatrace | Find it with |
| --- | --- | --- |
| 01 Disk | scenario log files + controller `signal=disk` | `contains(content, "retry_storm=true")` |
| 02 AKS capacity | controller `signal=aks.pending`; Kubernetes `Insufficient cpu` scheduling events (in `fetch events`, not logs) | `contains(content, "aks.pending")` |
| 03 Bad deployment | magic8ball pod errors `oracle backend returned null` | `k8s.container.name == "magic8ball" and loglevel == "ERROR"` |
| 04 Postgres connections | controller `signal=postgres.connections` naming `sre-demo-scenario-04`; PostgreSQL server log | `contains(content, "postgres.connections")` |
| 05 NSG | controller `signal=postgres.tcp` (TCP 5432 unreachable) | `contains(content, "postgres.tcp")` |
| 06 Certificate | controller `signal=magic8ball.tls` with the expiry reason | `contains(content, "magic8ball.tls")` |

**ServiceNow (automated).** The script sets the agent's incident platform to ServiceNow with
the `sre_demo_integration` user, waits for the agent to connect, scopes indexing to the
**SRE Demo Lab** group and creates the `servicenow-lab-response-plan` response plan
(priority 1–2, review mode). See [SERVICENOW-SETUP.md](SERVICENOW-SETUP.md#3-connect-azure-sre-agent-automated).
Incidents that Dynatrace raises then reach the agent with no prompting, within about a minute.

> Only one incident platform can be active. Connecting ServiceNow replaces Azure Monitor as the
> agent's incident source; the Azure Monitor alerts keep firing for side-by-side comparison.

---

## Enabling remediation (optional)

Investigation needs read access only. To let the agent *act*, grant Contributor — still scoped
to the demo resource group:

```bash
./scripts/enable-sre-remediation.sh --agent-principal-id <agent-managed-identity-object-id>
```

or manually:

```bash
az role assignment create --assignee "$AGENT_PRINCIPAL_ID" --role "Contributor" --scope "$SCOPE"
```

**What this permits, and what it does not:**

- Permits: scaling the AKS node pool, removing the NSG rule, restarting workloads, rolling back
  a deployment — everything the six scenarios require, within this resource group.
- Does not permit: anything outside the demo resource group. There is no subscription-scope
  grant anywhere in this lab.

> In **Review** mode (the default) mitigation actions remain **approval-controlled**: the agent
> proposes a change and waits for a human to approve it. Contributor makes the action
> *possible*; it does not make it automatic. Watching the agent propose a precise,
> well-reasoned change and ask for consent is usually the most persuasive demo.
>
> In **Autonomous** mode (`deploy.sh --agent-mode Autonomous`) the agent applies the fix itself,
> and the deployment runs this script for you — see the next section.

To revoke afterwards:

```bash
az role assignment delete --assignee "$AGENT_PRINCIPAL_ID" --role "Contributor" --scope "$SCOPE"
```

---

## Autonomous end-to-end test (Scenario 05)

Issue → Dynatrace problem → ServiceNow incident → agent investigates → agent fixes → incident
updated, with no human in the loop.

### Enable it

```bash
./scripts/deploy.sh ... --with-agent --agent-mode Autonomous --yes
```

`--agent-mode Autonomous` does three things, all from the deployment scripts:

| What | Where |
|---|---|
| Agent `actionConfiguration.mode = Autonomous` | Bicep (`sreAgentMode`) |
| ServiceNow response plan `agentMode = autonomous` (follows the agent mode recorded in `.lab-state.json`; override with `SRE_RESPONSE_PLAN_MODE`) | `configure-sre-agent-integrations.sh` |
| **Contributor** on the demo resource group only, granted *before* the response plan starts routing incidents | `deploy.sh` → `enable-sre-remediation.sh` |

Without the Contributor grant an autonomous agent still investigates, decides on the fix, and
then fails to apply it with `AuthorizationFailed`.

### Why Scenario 05

The fix is a single, safe, reversible ARM call inside the resource group — delete the injected
NSG rule — so it works with Contributor alone:

| Scenario | Autonomous fix possible? |
|---|---|
| 05 NSG blocks PostgreSQL | **Yes** — `az network nsg rule delete -g <rg> --nsg-name nsg-db-<suffix> -n sre-demo-deny-postgres` |
| 02 CPU / pending pods | Yes, but slow (node pool scale-out) and adds cost |
| 03, 06 | Need Kubernetes write (rollback / restart); the agent holds AKS *read* roles only |
| 04 | Needs killing database sessions — not an ARM operation |
| 01 | Needs deleting files on the VM — run-command is diagnostic-only by design |

### Run it

1. Activate Scenario 05 in the controller UI (or `POST /api/scenarios/05/activate`).
2. Within ~5–10 minutes Dynatrace opens **`[sre-demo-<suffix>] 05 PostgreSQL dependency
   failures`**, and the workflow creates a **P2** incident in group **SRE Demo Lab**.
3. The response plan hands the incident to the agent; it confirms the failure in Dynatrace,
   finds `sre-demo-deny-postgres` on `nsg-db-<suffix>`, and neutralises it.
4. The controller shows PostgreSQL healthy again; the agent writes its findings and the action
   taken back to the incident.
5. Reset the scenario in the controller (removes the rule), then resolve the incident.

**Verified run (2026-10-30, no human input):** fault injected 22:35Z → Dynatrace problem 22:37Z →
workflow creates the P2 incident 22:39Z → agent acknowledges 22:40Z and posts the root cause
(rule, priority, activity-log caller) 22:41Z → mitigation 22:42Z → PostgreSQL healthy, validated
from Dynatrace logs, 22:43Z. About 8 minutes from injection to recovery.

> **The agent does not delete.** Its autonomous write path refuses delete operations even with
> Contributor, so it mitigates non-destructively: it moves the rule to priority **4096**, below the
> Allow rules (200/210) and `Deny-Other-Vnet-Inbound` (4000), where it matches no traffic. It
> leaves the incident **In Progress** and writes the exact `az network nsg rule delete` command
> for a human to finish. Step 5 completes it.

When finished, return to the safer default:

```bash
./scripts/enable-sre-remediation.sh --agent-principal-id <id> --revoke
./scripts/deploy.sh ... --with-agent --agent-mode Review --yes
```

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Agent sees no resources | Role assignment missing or not yet propagated | Re-check step 3; allow up to 5 minutes |
| No Application Insights data | Telemetry has not arrived yet | Wait 10 minutes; confirm with the step 4 query |
| No AKS data | Container Insights disabled | `az aks enable-addons -a monitoring -g $RG -n $AKS --workspace-resource-id <id>` |
| GitHub connection fails | Consent not granted, or no repository access | Reconnect as a repository/organisation owner |
| Agent UI spins, then "Taking longer than usual… cold-starting, or there may be network issues" | Almost always **not** cold start. You lack an SRE Agent data-plane role; the endpoint is returning 401 | Assign yourself **SRE Agent Administrator** on the agent (see §3). Subscription Owner does not cover this |
| Alerts never fire | Evaluation window not yet elapsed | Rules evaluate every 5 minutes over a 10-minute window; allow 5–10 minutes |
| Agent cannot query the cluster | Cluster User role missing | Grant it, plus RBAC Reader if Azure RBAC is enabled |
| ServiceNow incident never picked up | Wrong priority or group, or quickstart plan off | Must be P2 in **SRE Demo Lab**; see [SERVICENOW-SETUP.md](SERVICENOW-SETUP.md#troubleshooting) |
| Agent says it has no Dynatrace tools | Connector missing or token rejected | Re-run `configure-sre-agent-integrations.sh`; check platform token scopes |
| Autonomous agent finds the fix but `AuthorizationFailed` applying it | No Contributor on the resource group | `enable-sre-remediation.sh --agent-principal-id <id>`; `deploy.sh --agent-mode Autonomous` does this automatically |
| Autonomous run: problem opens but no incident; workflow execution `403: The requested credential details cannot be accessed by the current user or entity` | The ServiceNow credential does not allow contextless requests (problem-triggered runs have no user) | Terraform sets `allow_contextless_requests = true`; re-run `deploy.sh` (or `terraform apply` in `infra/terraform/integration`) |
| Agent moved the NSG rule to priority 4096 instead of deleting it | Expected: the agent does not run deletes autonomously | Reset the scenario (removes the rule), then resolve the incident |
| Agent is Autonomous but still waits for approval | Response plan still `review` | Re-run `configure-sre-agent-integrations.sh` (it follows the agent mode) |

Lab-level problems: **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**.

---

## What is automated, and what is not

Automated by `scripts/deploy.sh --with-agent`:

1. **Creating the SRE Agent** — a `Microsoft.App/agents` resource, with its mode and region
   validated before the deployment starts.
2. **Wiring it to telemetry** — the lab's Application Insights is attached at creation.
3. **Creating its identity** — a dedicated user-assigned identity, holding no roles at creation.
4. **Granting you access to the agent** — the deploying principal receives **SRE Agent
   Administrator** on the agent, without which the agent exists but cannot be opened.
5. **Granting the agent read access to the lab** — Reader, Monitoring Reader, Log Analytics
   Reader, AKS Cluster User Role, AKS RBAC Reader and HDInsight Cluster Operator, scoped to the
   demo resource group only. This is read-only: it lets the agent see resources, metrics and
   logs, nothing more. It is also exactly the role set the Azure portal's own **Managed
   resources -> Add resource group** flow expects, so that flow requires no extra grants.
6. **Granting the agent VM run-command diagnostics** — a purpose-built custom role,
   `SRE Demo Lab VM Diagnostics - <suffix>`, scoped to the demo resource group, containing only
   `Microsoft.Compute/virtualMachines/runCommand/action` plus the two VM read actions. Needed
   because `Reader` does not cover running a diagnostic script on a VM (e.g. Scenario 04);
   deliberately does not include VM write/delete/start/stop, which stays behind
   `enable-sre-remediation.sh`.
7. **Setting the permission level to Privileged (High)** — so the agent's own identity (and the
   roles above) actually execute action-type calls like Scenario 04's, instead of every such
   call silently requiring OBO elevation of the approving human. See "Permission level
   (accessLevel)" above.
8. **Recording it** — name, region, mode, endpoint and principal ID land in `.lab-state.json`
   and the deployment summary.

Still yours to do, on purpose:

1. **Authorize GitHub** — the repository is registered automatically, but reading a private
   repository needs interactive OAuth consent in the portal or a `GITHUB_PAT`
   (see [section 2](#2-connect-the-private-github-repository)).
2. **Grant the agent write access** — `scripts/enable-sre-remediation.sh`, kept a separate
   command so that giving an automated agent write access is never a side effect of deploying
   a demo. The one exception is `--agent-mode Autonomous`: asking for an unattended agent is
   the explicit opt-in, so the deployment grants Contributor (resource group scope) for you.

Everything else — infrastructure, applications, telemetry, alert rules, scenarios — is fully
automated.
