// "create_incident" task of the sre-demo-<suffix>-servicenow workflow
// (Dynatrace AutomationEngine, dynatrace.automations:run-javascript).
//
// Terraform substitutes the CONFIG placeholder with non-secret settings. The ServiceNow
// credentials are read from the Dynatrace credential vault at run time, so they
// never appear in the workflow definition.
//
// Incident contract (shared with the classic webhook in dynatrace.tf, consumed by
// scripts/lib-integrations.sh, reset-lab.sh and the SRE Agent):
//   assignment_group = CONFIG.assignmentGroup, impact 2 + urgency 1 (priority 2 - High),
//   correlation_id   = "dynatrace-" + problem display id.
//
// The trigger fires on open and on close. Open creates the incident (once); close
// resolves it, unless a human or the SRE Agent already did. Nothing else resolves it:
// the agent leaves it In Progress after a mitigation, and the scenario reset only
// reverts the fault.
import { execution } from '@dynatrace-sdk/automation-utils';
import { credentialVaultClient } from '@dynatrace-sdk/client-classic-environment-v2';

const CONFIG = __CONFIG__;

export default async function ({ execution_id }) {
  const ex = await execution(execution_id);
  // Event-triggered runs carry the problem; manual runs (the deploy smoke test)
  // pass one in params.event instead. ex.event() is async and rejects (403/404)
  // when the run has no trigger event, so it must be awaited inside the try.
  let problem;
  try {
    problem = typeof ex.event === 'function' ? await ex.event() : undefined;
  } catch {
    problem = undefined;
  }
  problem = problem ?? ex.params?.event ?? {};

  // The trigger already filters on the prefix; this guards against edits to it.
  const title = String(problem['event.name'] ?? '');
  if (!title.toLowerCase().startsWith(CONFIG.titlePrefix.toLowerCase())) {
    return { created: false, skipped: 'not a ' + CONFIG.titlePrefix + ' problem', title };
  }
  const closed = String(problem['event.status'] ?? '').toUpperCase() === 'CLOSED';

  const problemId = String(problem['event.id'] ?? '');
  const displayId = String(problem['display_id'] ?? problemId);
  const correlationId = 'dynatrace-' + displayId;

  const cred = await credentialVaultClient.getCredentialsDetails({ id: CONFIG.credentialId });
  const headers = {
    Authorization: 'Basic ' + btoa(cred.username + ':' + cred.password),
    Accept: 'application/json',
    'Content-Type': 'application/json',
  };
  const table = CONFIG.instanceUrl + '/api/now/table/incident';

  // Retries and re-triggers must not open a second incident for one problem.
  const lookup = await fetch(
    table + '?sysparm_fields=number,sys_id,state&sysparm_limit=1&sysparm_query=' +
      encodeURIComponent('correlation_id=' + correlationId),
    { headers },
  );
  if (!lookup.ok) {
    throw new Error('ServiceNow incident lookup failed: HTTP ' + lookup.status + ' ' + (await lookup.text()));
  }
  const existing = (await lookup.json()).result ?? [];

  if (closed) {
    const inc = existing[0];
    // 6 Resolved, 7 Closed, 8 Canceled: leave whoever closed it in charge.
    if (!inc || Number(inc.state) >= 6) {
      return { resolved: false, skipped: inc ? 'already resolved' : 'no incident', number: inc?.number, correlationId };
    }
    const upd = await fetch(table + '/' + inc.sys_id, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({
        state: '6',
        close_code: 'Resolved by caller',
        close_notes: 'Dynatrace problem ' + displayId + ' closed: the monitored condition recovered. ' +
          'Resolved automatically by the Dynatrace workflow ' + CONFIG.workflowName + '.',
      }),
    });
    if (!upd.ok) {
      throw new Error('ServiceNow incident resolve failed: HTTP ' + upd.status + ' ' + (await upd.text()));
    }
    return { resolved: true, number: inc.number, sys_id: inc.sys_id, correlationId };
  }

  if (existing.length > 0) {
    return { created: false, number: existing[0].number, sys_id: existing[0].sys_id, correlationId };
  }

  const problemUrl = CONFIG.appsUrl + '/ui/apps/dynatrace.davis.problems/problem/' + encodeURIComponent(problemId);
  const impacted = []
    .concat(problem['root_cause_entity_name'] ?? [], problem['affected_entity_ids'] ?? [])
    .slice(0, 10)
    .join(', ');

  const incident = {
    short_description: title,
    description:
      'Dynatrace problem ' + displayId + ' (' + (problem['event.status'] ?? 'ACTIVE') +
      ', category ' + (problem['event.category'] ?? 'unknown') + ')\n' +
      'Impacted: ' + (impacted || 'n/a') + '\n' +
      'Problem: ' + problemUrl,
    assignment_group: CONFIG.assignmentGroup,
    correlation_id: correlationId,
    correlation_display: 'Dynatrace',
    category: 'software',
    impact: '2',
    urgency: '1',
    work_notes: 'Raised automatically by the Dynatrace workflow ' + CONFIG.workflowName + '.',
  };

  // sysparm_input_display_value lets assignment_group be given by name.
  const res = await fetch(table + '?sysparm_input_display_value=true', {
    method: 'POST',
    headers,
    body: JSON.stringify(incident),
  });
  if (!res.ok) {
    throw new Error('ServiceNow incident create failed: HTTP ' + res.status + ' ' + (await res.text()));
  }
  const created = (await res.json()).result;
  return { created: true, number: created.number, sys_id: created.sys_id, correlationId };
}
