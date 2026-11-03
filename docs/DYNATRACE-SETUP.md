# Dynatrace setup

The lab needs two credentials from your Dynatrace environment. Everything else — the
per-lab tokens, the alert definitions and the Dynatrace → ServiceNow routing — is created by
Terraform (`infra/terraform/integration/`) and destroyed with the lab. To create those objects
by hand, see [MANUAL-SETUP.md](MANUAL-SETUP.md).

## 0. Get a Dynatrace environment (free trial)

Dynatrace is **required** (unless you deploy with `--skip-dynatrace`). If you don't have an
environment, a free trial is enough for the whole lab:

1. Sign up at <https://www.dynatrace.com/signup/> with a work email.
2. When provisioning finishes, note the environment URL
   (`https://<env-id>.apps.dynatrace.com`). That is `DT_ENV_URL` below.
3. Create the two tokens in sections 2 and 3 as the trial's admin user.

New trials are on the latest Dynatrace platform, which the deploy detects and handles (see
the next section). Trials are **time-limited** (currently 15 days): plan your demos inside
that window, or ask Dynatrace to extend it or convert it. When the trial ends, problems stop
reaching ServiceNow and the SRE Agent's Dynatrace tools stop answering.

## Classic vs latest Dynatrace

The deploy detects which alerting model your environment has and builds the matching one.
Both raise the same problems and the same ServiceNow incidents.

| | Classic environment | Latest Dynatrace (no classic metric events) |
|---|---|---|
| Detected by | `builtin:anomaly-detection.metric-events` schema exists | that schema returns 404 |
| Alert definitions | 8 metric events (`dynatrace.tf`) | 8 Davis anomaly detectors on DQL (`dynatrace-platform.tf`) |
| Problem → ServiceNow | alerting profile + problem-notification webhook | AutomationEngine workflow `sre-demo-<suffix>-servicenow` running `workflow/servicenow-incident.js` |
| ServiceNow password stored in | the webhook definition | the Dynatrace credential vault (read by the workflow at run time) |
| `DT_PLATFORM_TOKEN` | optional (SRE Agent only) | **required** |

Put the values in `.env` (git-ignored). Never paste them into chat, issues or commits. On
Windows, `.\scripts\setup-integrations.ps1` prompts for them with hidden input, checks the
API token scopes and the platform token against the MCP gateway, and writes `.env` for you.

## 1. Environment URL — `DT_ENV_URL`

Either form works; `deploy.sh` derives the other:

| Form | Example | Used for |
|---|---|---|
| Platform UI | `https://<env-id>.apps.dynatrace.com` | links in the console, MCP gateway |
| Classic API | `https://<env-id>.live.dynatrace.com` | Terraform, OneAgent, Metrics API v2 |

## 2. API token — `DT_API_TOKEN` (`dt0c01.*`)

**Access tokens → Generate new token.** Used by Terraform and `deploy.sh`/`validate.sh` only.

| Scope | Why | Required |
|---|---|---|
| `apiTokens.read`, `apiTokens.write` | create the lab's four scoped tokens | yes (checked by preflight) |
| `settings.read`, `settings.write` | metric events, alerting profile, webhook; mode detection; outbound allowlist | yes (checked by preflight) |
| `credentialVault.read`, `credentialVault.write` | latest Dynatrace + ServiceNow: the workflow's ServiceNow credential | yes in that mode — **added to the token automatically** by setup/preflight (it holds `apiTokens.write`) |
| `metrics.read`, `entities.read` | `validate.sh` checks (skipped with 403 otherwise) | recommended |
| `metrics.ingest`, `logs.ingest`, `openTelemetryTrace.ingest`, `InstallerDownload`, `DataExport`, `activeGateTokenManagement.create` | some tenants only let a token create tokens whose scopes it holds itself | recommended |

Tokens Terraform creates from it, each named `sre-demo-<suffix>-*`:

| Token | Scopes | Consumer |
|---|---|---|
| `metrics-ingest` | `metrics.ingest` | Scenario Controller and Magic 8 Ball (`sre_demo.*` metrics) |
| `oneagent-installer` | `InstallerDownload` | OneAgent VM extension (lands in public extension settings, hence installer-only) |
| `operator` | `activeGateTokenManagement.create`, `entities.read`, `settings.*`, `DataExport`, `InstallerDownload` | Dynatrace Operator on AKS |
| `operator-ingest` | `metrics.ingest`, `logs.ingest`, `openTelemetryTrace.ingest` | DynaKube data ingest |

## 3. Platform token — `DT_PLATFORM_TOKEN` (`dt0s16.*`)

Required on latest Dynatrace (it creates the anomaly detectors and the workflow); otherwise
needed only with `--with-agent`. It authenticates Azure SRE Agent's `dynatrace-mcp`
connector to the Dynatrace **remote MCP server**:

```text
https://<env-id>.apps.dynatrace.com/platform-reserved/mcp-gateway/v0.1/servers/dynatrace-mcp/mcp
```

Install **Dynatrace MCP Server** from Dynatrace Hub if it is not already present, then
**Account Management → Identity & access management → Platform tokens → Generate**:

| Scope | Purpose |
|---|---|
| `mcp-gateway:servers:invoke`, `mcp-gateway:servers:read` | reach the MCP server (required) |
| `storage:buckets:read`, `storage:events:read`, `storage:logs:read`, `storage:metrics:read`, `storage:entities:read`, `storage:spans:read` | `execute-dql`, problems, Kubernetes events |
| `davis:analyzers:read`, `davis:analyzers:execute` | anomaly / forecast tools |
| `document:documents:read` | `find-documents`, troubleshooting guides |
| `davis-copilot:nl2dql:execute`, `davis-copilot:dql2nl:execute`, `davis-copilot:conversations:execute` | `create-dql`, `explain-dql`, `ask-dynatrace-docs` |
| `settings:objects:read`, `settings:objects:write` | latest Dynatrace: Davis anomaly detectors |
| `automation:workflows:read`, `automation:workflows:write`, `automation:workflows:run` | latest Dynatrace: ServiceNow workflow and its deploy-time test run (checked by preflight) |
| `app-engine:apps:run`, `app-engine:functions:run` | latest Dynatrace: run the workflow's JavaScript task |

### Latest Dynatrace: allow workflows to run as you (one time)

The workflow runs as the user who owns `DT_PLATFORM_TOKEN`. Dynatrace will not run any
workflow task until that user consents once per environment — this cannot be done by API:

1. Open **Workflows** (`https://<env-id>.apps.dynatrace.com/ui/apps/dynatrace.automations`).
2. **Settings** (top right) → **Authorization settings**.
3. Enable the **Primary permissions** and save. The workflow needs at least
   `automation:workflows:read` (the task reads its own execution),
   `app-engine:functions:run`, `environment-api:credentials:read` and `storage:events:read`.

The deploy and `validate.sh` run the workflow once with a non-lab title (it exits before
calling ServiceNow) and print these steps if the consent is missing.

The deploy also adds your ServiceNow host to **Settings → General → External requests**
(the JavaScript outbound allowlist) when that list is enforced. It never removes entries.

`configure-sre-agent-integrations.sh` sends an MCP `initialize` to the gateway before it
creates the connector, so a wrong token fails there with a clear message.

## What gets created

| Object | Name |
|---|---|
| Metric events (8) — classic | title prefix `[sre-demo-<suffix>]`, covering scenarios 01–06 |
| Alerting profile — classic | `sre-demo-<suffix>` — matches only events with the lab's title prefix |
| Problem notification (webhook) — classic | `sre-demo-<suffix>-servicenow` — POSTs to `/api/now/table/incident` as the integration user, impact 2 / urgency 1 (priority **2 – High**), `correlation_id` `dynatrace-<problem id>` |
| Davis anomaly detectors (8) — latest | same titles, thresholds and aggregations as the metric events, as DQL |
| Credential `sre-demo-<suffix>-servicenow` — latest | integration user + password, owner-only, App Engine scope |
| Workflow `sre-demo-<suffix>-servicenow` — latest | Davis problem trigger on `event.name` matching the prefix; creates the same incident as the webhook (idempotent on `correlation_id`) |
| OneAgent | both VMs (host group `sre-demo-vm-<suffix>`), AKS cloud-native full stack on namespace `sre-demo` (host group `sre-demo-aks-<suffix>`) |

The Dynatrace pods request ~1.1 vCPU, so a Dynatrace-enabled lab runs AKS on one 4 vCPU node
(`Standard_D4as_v7`, ~$0.10/hr more than the 2 vCPU default). Scenario 02 is calibrated to the
remaining headroom at deploy time, so it behaves the same on either size.

Because the alerting profile / workflow trigger filters on the title prefix, several labs (or other workloads)
can share one Dynatrace environment without paging each other's ServiceNow queue.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Preflight: `missing scope(s)` | add the listed scopes to `DT_API_TOKEN` |
| `terraform apply` 403 creating a token | the API token lacks a scope the new token needs — see the "recommended" row above |
| No `sre_demo.*` metrics | `validate.sh` → Dynatrace section; check `DT_API_URL` / `DT_INGEST_TOKEN` in the app environment |
| No hosts in host group | OneAgent extension status: `az vm extension list ... --subscription <id>` |
| MCP `initialize` 401/403 | platform token missing `mcp-gateway:*` scopes or expired |
| `No schema with topic identifier 'builtin:anomaly-detection.metric-events'` | latest Dynatrace with an older checkout of this repo; pull and re-run — the mode is now detected |
| Workflow execution: `Uncaught (in promise) 403: Forbidden` | a permission is missing from the authorization settings — usually `automation:workflows:read`; see the list above |
| Deploy/validate: "has not been allowed to run workflows on your behalf" | do the one-time [authorization settings](#latest-dynatrace-allow-workflows-to-run-as-you-one-time) step |
| Workflow execution (problem-triggered only): `403: The requested credential details cannot be accessed by the current user or entity` | the credential lacks `allow_contextless_requests`; manual runs carry a user context and pass. Terraform sets it — re-apply |
| No `sre_demo.*` metrics; scenarios 02–06 never open a problem | app sinks posted to `/api/api/v2/metrics/ingest` (404). Fixed: `DT_API_URL` is the environment root. `validate.sh` reports "Controller metrics accepted by Dynatrace" |
| Workflow execution: `credentialVault` 403 / credential not found | the workflow actor must be the API token's owner (credential is owner-only); create both tokens as the same user |
| Workflow execution: fetch blocked / host not allowed | add the ServiceNow host under **Settings → General → External requests** |
