# ServiceNow setup

ServiceNow is the lab's incident platform. Dynatrace opens incidents in it, and Azure SRE
Agent picks them up from it. Terraform (`infra/terraform/integration/servicenow.tf`)
creates the ServiceNow objects. Connecting the agent to ServiceNow is one portal step.

## 1. Instance and admin credentials

A [Personal Developer Instance](https://developer.servicenow.com/) works. PDIs **hibernate**
after inactivity, so wake yours from the developer portal before deploying. `deploy.sh`
preflight fails fast with a clear message if the instance is asleep or the credentials are
wrong.

Put these in `.env` (on Windows, `.\scripts\setup-integrations.ps1` prompts for them, checks the
login, the admin role and hibernation, and writes the file):

```bash
SNOW_INSTANCE_URL=https://<instance>.service-now.com
SNOW_ADMIN_USER=admin
SNOW_ADMIN_PASSWORD=...           # never committed; used only by Terraform
SNOW_ASSIGNMENT_GROUP=SRE Demo Lab
SNOW_INTEGRATION_USER=sre_demo_integration
```

The admin account is used **only** to create the objects below. Neither Dynatrace nor the
agent ever sees it.

## 2. What Terraform creates

| Object | Detail |
|---|---|
| Assignment group | `SRE Demo Lab` (`SNOW_ASSIGNMENT_GROUP`) |
| Integration user | `sre_demo_integration`, a web-service-only account with a generated 24-character password |
| Role | `itil` on the integration user, which is enough to create, read and update incidents |
| Group membership | integration user ∈ assignment group |

The integration user's password is stored in the lab Key Vault as
`servicenow-integration-password` and is used in two places:

- **Dynatrace problem routing** — the problem webhook (classic) or the workflow, which reads
  it from the Dynatrace credential vault (latest Dynatrace). Either sends `POST /api/now/table/incident` with impact 2 /
  urgency 1, which gives **priority 2 – High**, and sets `correlation_id = dynatrace-<problem id>`.
  The workflow also runs when the problem closes and resolves that incident (state 6,
  `Resolved by caller`) unless it is already resolved.
- **Azure SRE Agent** incident platform (basic auth, below).

`destroy-lab.sh` deletes the group and the user. Incidents are kept as history.
`reset-lab.sh` resolves the lab's open incidents.

## 3. Connect Azure SRE Agent (automated)

`deploy.sh --with-agent` runs `./scripts/configure-sre-agent-integrations.sh`, which makes the
same calls as the portal's **Builder → Incident platform → ServiceNow** dialog:

1. **ARM** `PATCH Microsoft.App/agents/<agent>` (api `2026-01-01`) →
   `incidentManagementConfiguration`: `type: ServiceNow`, the instance URL, and
   `connectionKey` set to the JSON document `{"username":"sre_demo_integration","password":"..."}`
   (write-only; ARM returns it empty). `oboUser` carries a `sreagent-config-revision:<uuid>`
   marker, as the portal sends.
2. **Agent data plane** `GET /api/v2/incidentManagement/checkConnectivityDetailed`, polled
   until `success: true` (up to 3 minutes).
3. `PUT /api/v2/incidents/indexing/servicenow/configuration` → assignment group
   `SRE Demo Lab`, 30-day lookback (`SNOW_ASSIGNMENT_GROUP`, `SNOW_LOOKBACK_DAYS`).
4. `PUT /api/v2/incidentManagement/incidentFilters/servicenow-lab-response-plan` → a response
   plan that hands **priority 1–2** ServiceNow incidents to the agent in **review** mode
   (`SNOW_RESPONSE_PRIORITIES`, `SRE_RESPONSE_PLAN_MODE=autonomous` to let it act unprompted).
   The Dynatrace routing sets urgency 1 so its incidents are priority 2.

Re-running the script is safe. Every redeploy re-applies it, because the Bicep deployment
resets the agent's incident platform. `validate.sh` checks the result from the agent's side
(**Azure SRE Agent integrations** section).

If a step fails the script prints the portal fallback: **Builder → Incident platform →
ServiceNow**, *Basic* auth, user `sre_demo_integration`, password from
`.secrets/servicenow-integration-<suffix>.txt` (git-ignored; `--show-password` prints it),
assignment group `SRE Demo Lab`, **Quickstart response plan** ticked.

> **Only one incident platform can be active.** If the agent was connected to Azure Monitor
> alerts, connecting ServiceNow replaces that. Azure Monitor alerts still fire and are still
> visible in the portal; they just no longer reach the agent as incidents.

## 4. End-to-end check

```bash
./scripts/validate.sh    # ServiceNow: login + group; SRE Agent: connected + response plan
```

Then inject scenario 03 or 05 from the console. Within roughly 5 minutes you should see:

1. a Dynatrace problem titled `[sre-demo-<suffix>] ...`
2. a ServiceNow incident in **SRE Demo Lab**, priority 2, correlation ID `dynatrace-<PID>`
3. the agent's work note on the incident and a new investigation thread in the agent

## Troubleshooting

| Symptom | Cause |
|---|---|
| Preflight: `HTTP 401` from ServiceNow | wrong admin password, or the PDI is hibernating (it may also redirect to a login page) |
| Problem raised, no incident | Classic: **Settings → Integration → Problem notifications** → `sre-demo-<suffix>-servicenow` → **Send test notification**. Latest: **Workflows** → `sre-demo-<suffix>-servicenow` → executions |
| Incident created, agent ignores it | priority not 1–2, wrong assignment group, or the response plan is not enabled — `validate.sh` shows which; re-run `configure-sre-agent-integrations.sh` |
| Incident priority is 3 | the instance's priority lookup was customised; change `urgency` in `dynatrace.tf` |
