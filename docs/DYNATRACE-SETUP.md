# Dynatrace setup

The lab needs two credentials from your Dynatrace environment. Everything else — the
per-lab tokens, the metric events, the alerting profile and the ServiceNow webhook — is
created by Terraform (`infra/terraform/integration/dynatrace.tf`) and destroyed with the lab.

Put the values in `.env` (git-ignored). Never paste them into chat, issues or commits.

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
| `settings.read`, `settings.write` | metric events, alerting profile, webhook | yes (checked by preflight) |
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

Optional; needed only with `--with-agent`. It authenticates Azure SRE Agent's
`dynatrace-mcp` connector to the Dynatrace **remote MCP server**:

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

`configure-sre-agent-integrations.sh` sends an MCP `initialize` to the gateway before it
creates the connector, so a wrong token fails there with a clear message.

## What gets created

| Object | Name |
|---|---|
| Metric events (8) | title prefix `[sre-demo-<suffix>]`, covering scenarios 01–06 |
| Alerting profile | `sre-demo-<suffix>` — matches only events with the lab's title prefix |
| Problem notification (webhook) | `sre-demo-<suffix>-servicenow` — POSTs to `/api/now/table/incident` as the integration user, impact 2 / urgency 1 (priority **2 – High**), `correlation_id` `dynatrace-<problem id>` |
| OneAgent | both VMs (host group `sre-demo-vm-<suffix>`), AKS cloud-native full stack on namespace `sre-demo` (host group `sre-demo-aks-<suffix>`) |

Because the alerting profile filters on the title prefix, several labs (or other workloads)
can share one Dynatrace environment without paging each other's ServiceNow queue.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Preflight: `missing scope(s)` | add the listed scopes to `DT_API_TOKEN` |
| `terraform apply` 403 creating a token | the API token lacks a scope the new token needs — see the "recommended" row above |
| No `sre_demo.*` metrics | `validate.sh` → Dynatrace section; check `DT_API_URL` / `DT_INGEST_TOKEN` in the app environment |
| No hosts in host group | OneAgent extension status: `az vm extension list ... --subscription <id>` |
| MCP `initialize` 401/403 | platform token missing `mcp-gateway:*` scopes or expired |
