# ---------------------------------------------------------------------------
# Scenario 01 application logs -> Dynatrace Grail.
#
# OneAgent only auto-discovers system logs (syslog, journald, files open by
# monitored processes). The runaway logger in scenario 01 writes to
# /var/sre-demo/logs, so without a custom log source the SRE Agent finds
# nothing there when it runs `fetch logs` through the Dynatrace MCP server.
#
# The logger writes ~2 GB per run, so only its ERROR lines (the ones carrying
# retry_storm=true, which is the root-cause evidence) are stored. Storage rules
# are first-match-wins and the built-in "Ingest logs from custom log sources"
# rule is near the top. The provider always appends new rules at the end, so
# dt_log_storage_rules_first (scripts/lib-integrations.sh) moves both to the
# top after every apply.
# ---------------------------------------------------------------------------

locals {
  # Matches sre-demo-scenario-01-<epoch ms>.log only, not the fallocated
  # sre-demo-scenario-01-archive-*.log ballast (gigabytes of zero bytes).
  scenario01_log_path = "/var/sre-demo/logs/sre-demo-scenario-01-1*.log"
}

resource "dynatrace_log_custom_source" "scenario01" {
  name    = "${local.title_prefix} scenario 01 application logs"
  enabled = true

  custom_log_source {
    type = "LOG_PATH_PATTERN"
    values_and_enrichment {
      custom_log_source_with_enrichment {
        path = local.scenario01_log_path
        enrichment {
          enrichment {
            type  = "attribute"
            key   = "lab.suffix"
            value = var.lab_suffix
          }
        }
      }
    }
  }
}

resource "dynatrace_log_storage" "scenario01_errors" {
  name            = "${local.title_prefix} keep scenario 01 retry-storm errors"
  enabled         = true
  send_to_storage = true

  matchers {
    matcher {
      attribute = "log.source"
      operator  = "MATCHES"
      values    = [local.scenario01_log_path]
    }
    matcher {
      attribute = "log.content"
      operator  = "MATCHES"
      values    = ["*retry_storm=true*"]
    }
  }
}

resource "dynatrace_log_storage" "scenario01_rest" {
  name            = "${local.title_prefix} drop other scenario 01 log lines"
  enabled         = true
  send_to_storage = false
  insert_after    = dynatrace_log_storage.scenario01_errors.id

  matchers {
    matcher {
      attribute = "log.source"
      operator  = "MATCHES"
      values    = [local.scenario01_log_path]
    }
  }
}
