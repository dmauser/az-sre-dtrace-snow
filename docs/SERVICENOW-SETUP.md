# ServiceNow setup

ServiceNow is the lab's incident platform. Dynatrace opens incidents in it, and Azure SRE
Agent picks them up from it. Terraform (`infra/terraform/integration/servicenow.tf`)
creates the ServiceNow objects. Connecting the agent to ServiceNow is one portal step.

## 1. Instance and admin credentials

A [Personal Developer Instance](https://developer.servicenow.com/) works. PDIs **hibernate**
after inactivity, so wake yours from the developer portal before deploying. `deploy.sh`
preflight fails fast with a clear message if the instance is asleep or the credentials are
wrong.

Put these in `.env`:

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

- **Dynatrace problem webhook.** It sends `POST /api/now/table/incident` with impact 2 /
  urgency 1, which gives **priority 2 – High**, and sets `correlation_id = dynatrace-<problem id>`.
- **Azure SRE Agent** incident platform (basic auth, below).

`destroy-lab.sh` deletes the group and the user. Incidents are kept as history.
`reset-lab.sh` resolves the lab's open incidents.

## 3. Connect Azure SRE Agent (portal)

The ARM API has no basic-auth fields for the ServiceNow incident platform, so this step is
manual. `deploy.sh --with-agent` (or `./scripts/configure-sre-agent-integrations.sh`) prints
the exact values and saves the password to `.secrets/servicenow-integration-<suffix>.txt`,
which is git-ignored.

1. Open the agent at [sre.azure.com](https://sre.azure.com) → **Builder** → **Incident platform**.
2. Choose **ServiceNow**.
3. **ServiceNow endpoint**: `https://<instance>.service-now.com`.
4. **Authentication**: *Basic*. Username `sre_demo_integration`; password from the file above.
5. **Assignment group**: `SRE Demo Lab`.
6. Tick **Quickstart response plan**. It indexes **High (P2)** incidents, which is why the
   webhook sets urgency 1.
7. Save. The agent polls ServiceNow every minute.

> **Only one incident platform can be active.** If the agent was connected to Azure Monitor
> alerts, connecting ServiceNow replaces that. Azure Monitor alerts still fire and are still
> visible in the portal; they just no longer reach the agent as incidents.

## 4. End-to-end check

```bash
./scripts/validate.sh                       # ServiceNow section: login + group
```

Then inject scenario 03 or 05 from the console. Within roughly 5 minutes you should see:

1. a Dynatrace problem titled `[sre-demo-<suffix>] ...`
2. a ServiceNow incident in **SRE Demo Lab**, priority 2, correlation ID `dynatrace-<PID>`
3. the agent's work note on the incident and a new investigation thread in the agent

## Troubleshooting

| Symptom | Cause |
|---|---|
| Preflight: `HTTP 401` from ServiceNow | wrong admin password, or the PDI is hibernating (it may also redirect to a login page) |
| Problem raised, no incident | Dynatrace → **Settings → Integration → Problem notifications** → `sre-demo-<suffix>-servicenow` → **Send test notification** |
| Incident created, agent ignores it | priority not 2, wrong assignment group, or the quickstart plan is not enabled |
| Incident priority is 3 | the instance's priority lookup was customised; change `urgency` in `dynatrace.tf` |
