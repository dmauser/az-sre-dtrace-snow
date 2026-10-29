/**
 * Cross-file consistency tests.
 *
 * These check the seams where this project is most likely to break silently.
 * A metric renamed in the controller but not in the alert rule, a Kubernetes
 * placeholder that deploy.sh never substitutes, or a scenario added without
 * documentation would all leave the lab looking healthy while quietly failing
 * to do its job. Type checking cannot catch any of them because the mismatch
 * spans TypeScript, Bicep, YAML and Bash.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
// Normalise line endings: Windows checkouts with core.autocrlf=true see CRLF.
const read = (path) => readFileSync(join(repoRoot, path), 'utf8').replace(/\r\n/g, '\n');

/**
 * Removes YAML comment lines. These tests must analyse configuration, not the
 * prose explaining it — otherwise a comment mentioning "cluster-admin" or a
 * placeholder reads as the real thing.
 */
const stripComments = (yaml) =>
  yaml
    .split('\n')
    .filter((line) => !/^\s*#/.test(line))
    .join('\n');

test('every sre_demo_ metric queried by an alert rule is emitted by the controller', () => {
  const alerts = read('infra/bicep/modules/alerts.bicep');
  const telemetry = read('apps/scenario-controller/backend/src/telemetry.ts');

  const queried = new Set([...alerts.matchAll(/"(sre_demo_[a-z0-9_]+)"/g)].map((m) => m[1]));
  const emitted = new Set([...telemetry.matchAll(/'(sre_demo_[a-z0-9_]+)'/g)].map((m) => m[1]));

  assert.ok(queried.size > 0, 'alerts.bicep should query at least one custom metric');

  for (const metric of queried) {
    assert.ok(
      emitted.has(metric),
      `Alert rule queries "${metric}" but the controller never emits it. ` +
        `Emitted: ${[...emitted].join(', ')}`,
    );
  }
});

test('every registered scenario has an implementation, a document and an id', () => {
  const registry = read('apps/scenario-controller/backend/src/scenarios/index.ts');
  const registered = [...registry.matchAll(/new (\w+Scenario)\(\)/g)].map((m) => m[1]);

  assert.equal(registered.length, 6, `expected 6 registered scenarios, found ${registered.length}`);

  const scenarioDir = join(repoRoot, 'apps/scenario-controller/backend/src/scenarios');
  const sources = readdirSync(scenarioDir).filter((f) => f.endsWith('.ts'));
  const combined = sources.map((f) => readFileSync(join(scenarioDir, f), 'utf8')).join('\n');

  for (const className of registered) {
    assert.ok(
      combined.includes(`class ${className}`),
      `${className} is registered but no class definition was found`,
    );
  }

  const ids = [...combined.matchAll(/readonly id = '(\d{2})'/g)].map((m) => m[1]).sort();
  assert.deepEqual(ids, ['01', '02', '03', '04', '05', '06'], 'scenario IDs must be 01-06 and unique');

  const docs = readdirSync(join(repoRoot, 'docs/scenarios'));
  for (const id of ids) {
    assert.ok(
      docs.some((doc) => doc.startsWith(id)),
      `Scenario ${id} has no document in docs/scenarios/`,
    );
  }
});

test('every Kubernetes manifest placeholder is substituted by deploy.sh', () => {
  // The DynaKube is rendered by dynatrace_install_operator, which deploy.sh sources.
  const deploy = read('scripts/deploy.sh') + read('scripts/lib-integrations.sh');
  const manifestDir = join(repoRoot, 'k8s');

  const collect = (dir) =>
    readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) return collect(full);
      return entry.name.endsWith('.yaml') ? [full] : [];
    });

  const placeholders = new Set();
  for (const file of collect(manifestDir)) {
    const content = stripComments(readFileSync(file, 'utf8'));
    for (const match of content.matchAll(/__([A-Z0-9_]+)__/g)) {
      placeholders.add(match[1]);
    }
  }

  assert.ok(placeholders.size > 0, 'expected the manifests to contain placeholders');

  for (const placeholder of placeholders) {
    assert.ok(
      deploy.includes(`__${placeholder}__`),
      `Manifests use __${placeholder}__ but deploy.sh never substitutes it, ` +
        'so it would be applied to the cluster literally.',
    );
  }
});

test('scenario-runner endpoints called by the controller exist in the runner', () => {
  const client = read('apps/scenario-controller/backend/src/runner.ts');
  const server = read('services/scenario-runner/src/index.ts');

  const called = [...client.matchAll(/call<[^>]*>\('(GET|POST)', '([^']+)'/g)].map((m) => ({
    method: m[1],
    path: m[2],
  }));

  assert.ok(called.length > 0, 'expected the controller to call the runner');

  for (const { method, path } of called) {
    const handler = `app.${method.toLowerCase()}('${path}'`;
    assert.ok(
      server.includes(handler),
      `Controller calls ${method} ${path} but scenario-runner has no handler for it`,
    );
  }
});

test('lifecycle scripts referenced in the README exist and are executable shell', () => {
  const readme = read('README.md');
  const referenced = new Set(
    [...readme.matchAll(/scripts\/([a-z-]+\.(?:sh|ps1))/g)].map((m) => m[1]),
  );

  assert.ok(referenced.size > 0, 'README should reference the lifecycle scripts');

  for (const script of referenced) {
    assert.ok(existsSync(join(repoRoot, 'scripts', script)), `README references missing scripts/${script}`);
  }

  // Every Bash script must have a PowerShell counterpart, and vice versa.
  for (const name of ['deploy', 'validate', 'reset-lab', 'stop-lab', 'start-lab', 'destroy-lab']) {
    assert.ok(existsSync(join(repoRoot, 'scripts', `${name}.sh`)), `missing scripts/${name}.sh`);
    assert.ok(existsSync(join(repoRoot, 'scripts', `${name}.ps1`)), `missing scripts/${name}.ps1`);
  }
});

test('the disk scenario can never be configured to fill the disk completely', () => {
  const config = read('apps/scenario-controller/backend/src/config.ts');

  const maxPercent = Number(/maxPercent:\s*(\d+)/.exec(config)?.[1]);
  assert.ok(Number.isFinite(maxPercent), 'config must define disk.maxPercent');
  assert.ok(maxPercent < 100, `disk.maxPercent is ${maxPercent}; it must stay below 100`);
  assert.ok(maxPercent <= 95, `disk.maxPercent of ${maxPercent} leaves too little headroom`);

  const disk = read('apps/scenario-controller/backend/src/scenarios/disk.ts');
  assert.ok(
    disk.includes('Math.min(config.disk.targetPercent, config.disk.maxPercent)'),
    'the disk scenario must clamp its target to the hard ceiling',
  );
  assert.ok(disk.includes('guardBytes'), 'the disk scenario must enforce an absolute free-space floor');
});

test('database session termination is always filtered to this lab', () => {
  const db = read('apps/scenario-controller/backend/src/db.ts');

  const terminates = db.includes('pg_terminate_backend');
  assert.ok(terminates, 'expected a termination path to exist');

  // An unfiltered pg_terminate_backend would turn a partial incident into a
  // total outage, and could kill sessions this lab does not own.
  const filtered = /pg_terminate_backend\(pid\)[\s\S]{0,200}application_name LIKE 'sre-demo-scenario%'/.test(db);
  assert.ok(filtered, 'pg_terminate_backend must be filtered on application_name');
  assert.ok(db.includes('pid <> pg_backend_pid()'), 'termination must exclude the calling session');
});

test('the resource-burner cannot preempt application workloads', () => {
  const manifest = stripComments(read('k8s/resource-pressure/deployment.yaml'));

  assert.ok(manifest.includes('priorityClassName: sre-demo-low-priority'), 'burner must use the low priority class');
  assert.ok(manifest.includes('preemptionPolicy: Never'), 'burner must never preempt other pods');
  assert.match(manifest, /value:\s*-\d+/, 'burner priority value must be negative');
  assert.ok(manifest.includes('replicas: 0'), 'burner must be dormant at baseline');
});

test('Dynatrace gets a node big enough for it, and scenario 02 is calibrated after it schedules', () => {
  const deploy = read('scripts/deploy.sh');

  assert.match(
    deploy,
    /DYNATRACE_ENABLED:-false}" == "true" \]\]; then AKS_NODE_VCPU=4; else AKS_NODE_VCPU=2; fi/,
    'a Dynatrace-enabled lab must use a 4 vCPU AKS node; ~1.1 vCPU of Dynatrace pods does not fit a 2 vCPU node',
  );
  assert.match(deploy, /AKS_NODE_SIZE:-Standard_D\$\{AKS_NODE_VCPU\}as_v7/, 'the default node SKU must follow AKS_NODE_VCPU');
  assert.ok(
    /az aks delete[^\n]*aks-sre-demo-\$\{SUFFIX\}/.test(deploy) && deploy.includes('EXISTING_AKS_SKU}" != "${SELECTED_AKS_SKU}"'),
    'redeploying with a different node SKU must recreate the cluster; AKS cannot resize a pool in place',
  );

  const smokeSection = deploy.slice(deploy.indexOf('step "20/20'));
  const wait = smokeSection.indexOf('\ndynatrace_wait_dynakube\n');
  const calibrate = smokeSection.indexOf('\ncalibrate_resource_pressure\n');
  assert.ok(wait >= 0 && calibrate > wait, 'scenario 02 must be calibrated after the DynaKube (OneAgent) pods are scheduled');
  assert.match(deploy, /set resources deployment\/resource-burner -c resource-burner/, 'calibration must resize the burner');
});

test('scenario-runner RBAC is namespace-scoped and secret access is enumerated', () => {
  const rbac = stripComments(read('k8s/rbac/scenario-runner.yaml'));

  assert.ok(!rbac.includes('cluster-admin'), 'scenario-runner must never bind cluster-admin');
  assert.ok(rbac.includes('resourceNames:'), 'secret access must be restricted to named secrets');

  for (const verb of ['create', 'delete', 'deletecollection']) {
    assert.ok(
      !new RegExp(`verbs:.*["']${verb}["']`).test(rbac),
      `scenario-runner must not be granted the "${verb}" verb`,
    );
  }
});

test('Magic 8 Ball probes use HTTP so scenario 06 does not restart the pods', () => {
  const manifest = stripComments(read('k8s/magic8ball/deployment.yaml'));

  // If liveness used the HTTPS port, an expired certificate would cause a
  // CrashLoopBackOff and destroy the evidence scenario 06 depends on.
  const livenessBlock = /livenessProbe:[\s\S]*?failureThreshold: \d+/.exec(manifest)?.[0] ?? '';
  assert.ok(livenessBlock.includes('port: http'), 'liveness probe must target the HTTP port');

  const readinessBlock = /readinessProbe:[\s\S]*?failureThreshold: \d+/.exec(manifest)?.[0] ?? '';
  assert.ok(readinessBlock.includes('port: http'), 'readiness probe must target the HTTP port');
});

test('both Magic 8 Ball access gates are kept in sync by deploy and grant-access', () => {
  const deploy = read('scripts/deploy.sh');
  const grant = read('scripts/grant-access.sh');
  const manifest = stripComments(read('k8s/magic8ball/deployment.yaml'));
  const network = read('infra/bicep/modules/network.bicep');

  // Magic 8 Ball is reachable only if BOTH the AKS subnet NSG rule and the
  // Service's loadBalancerSourceRanges permit the caller. An NSG drops rather
  // than refuses, so drift between them presents as a hang with no error —
  // which is exactly what makes it worth pinning down in a test.
  assert.ok(
    manifest.includes('loadBalancerSourceRanges'),
    'the magic8ball Service must restrict source ranges',
  );
  assert.ok(
    network.includes('Allow-Magic8Ball-From-Admin'),
    'the AKS subnet NSG must carry the matching rule',
  );

  for (const [name, script] of [['deploy.sh', deploy], ['grant-access.sh', grant]]) {
    assert.ok(
      script.includes('Allow-Magic8Ball-From-Admin'),
      `${name} must maintain the AKS subnet NSG rule`,
    );
    assert.ok(
      script.includes('loadBalancerSourceRanges'),
      `${name} must maintain the Service source ranges`,
    );
  }
});

test('administrator access is a list and deploy prompts rather than assuming', () => {
  const deploy = read('scripts/deploy.sh');
  const main = read('infra/bicep/main.bicep');
  const network = read('infra/bicep/modules/network.bicep');

  assert.ok(main.includes('param adminCidrs array'), 'main.bicep must accept a list of admin CIDRs');
  assert.ok(network.includes('param adminCidrs array'), 'network.bicep must accept a list of admin CIDRs');
  assert.ok(
    !network.includes('sourceAddressPrefix: adminCidr\n'),
    'network rules must use sourceAddressPrefixes with the list',
  );

  // The deploying host is frequently not the browsing host, so a silent
  // auto-detect strands the operator outside their own lab.
  assert.ok(
    deploy.includes('Allowed CIDR(s):'),
    'deploy.sh must prompt for the administrator CIDRs when they are not supplied',
  );
  assert.ok(
    deploy.includes('reconcile_rule'),
    'deploy.sh must reconcile the admin NSG rules after deployment',
  );
});

test('the architecture diagram and docs state the real number of alert rules', () => {
  const declared = (read('infra/bicep/modules/alerts.bicep').match(/key: '/g) ?? []).length;
  assert.ok(declared > 0, 'expected alerts.bicep to declare at least one rule');

  for (const path of [
    'docs/sre-demo-architecture.svg',
    'README.md',
    'docs/ARCHITECTURE.md',
  ]) {
    const claims = [...read(path).matchAll(/(\d+)\s+scheduled query (?:alert )?rules/g)];
    assert.ok(claims.length > 0, `${path} should state the alert rule count`);
    for (const [, claimed] of claims) {
      assert.equal(
        Number(claimed),
        declared,
        `${path} claims ${claimed} alert rules but alerts.bicep declares ${declared}`,
      );
    }
  }
});

test('the SRE agent is opt-in and its modes agree across Bicep and deploy.sh', () => {
  const main = read('infra/bicep/main.bicep');
  const module = read('infra/bicep/modules/sre-agent.bicep');
  const deploy = read('scripts/deploy.sh');

  assert.match(
    main,
    /param deploySreAgent bool = false/,
    'the agent must default to off so an ordinary deploy never creates a chargeable agent',
  );
  assert.match(main, /module sreAgent .* = if \(deploySreAgent\)/);

  assert.ok(deploy.includes('--with-agent'), 'deploy.sh should expose --with-agent');
  assert.ok(
    deploy.includes('deploySreAgent="${WITH_AGENT}"'),
    'the flag must actually reach the template',
  );

  // The module enumerates the allowed modes; deploy.sh rejects anything else
  // before deploying. If one list grows, the other has to.
  const allowed = [...module.matchAll(/^\s{2}'(ReadOnly|Review|Autonomous)'$/gm)].map((m) => m[1]);
  assert.deepEqual(allowed, ['ReadOnly', 'Review', 'Autonomous']);
  for (const mode of allowed) {
    assert.ok(
      new RegExp(`\\b${mode}\\b`).test(deploy.match(/case "\$\{AGENT_MODE\}" in[\s\S]*?esac/)[0]),
      `deploy.sh should accept --agent-mode ${mode}`,
    );
  }
});

test('every deploy.sh flag named in the docs actually exists in deploy.sh', () => {
  const deploy = read('scripts/deploy.sh');
  const parser = deploy.match(/while \[\[ \$# -gt 0 \]\]; do[\s\S]*?\ndone/)[0];
  const usage = deploy.match(/usage\(\) \{[\s\S]*?\nUSAGE\n\}/)[0];
  const flagsIn = (text) => new Set([...text.matchAll(/(?<![-\w])(--[a-z][a-z-]{2,})/g)].map((m) => m[1]));

  // deploy.sh must accept everything its own help advertises.
  for (const flag of flagsIn(usage)) {
    assert.ok(parser.includes(flag), `deploy.sh --help advertises ${flag} but does not parse it`);
  }

  // ...and so must the Options block in the deployment guide.
  const options = read('docs/DEPLOYMENT.md').match(/## Options\n+```\n([\s\S]*?)```/)[1];
  for (const flag of flagsIn(options)) {
    assert.ok(parser.includes(flag), `DEPLOYMENT.md documents ${flag} but deploy.sh does not parse it`);
  }
});

test('the SRE agent settings in .env.example are the ones deploy.sh reads', () => {
  const env = read('.env.example');
  const deploy = read('scripts/deploy.sh');

  const declared = [...env.matchAll(/^([A-Z_]*AGENT[A-Z_]*)=/gm)].map((m) => m[1]);
  assert.ok(declared.length > 0, '.env.example should document the agent settings');

  for (const name of declared) {
    assert.ok(
      new RegExp(`\\$\\{${name}:?-`).test(deploy),
      `.env.example declares ${name} but deploy.sh never reads it`,
    );
  }
});

test('the deploying user is granted access to the agent it creates', () => {
  const module = read('infra/bicep/modules/sre-agent.bicep');
  const main = read('infra/bicep/main.bicep');

  // Control-plane Owner does not reach the agent data plane, so without this
  // assignment the agent deploys but nobody can open it.
  assert.match(module, /sreAgentAdministratorRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'/);
  assert.match(module, /resource deployerAgentAdmin 'Microsoft\.Authorization\/roleAssignments/);
  assert.match(module, /scope: agent/, 'the grant must be scoped to the agent, not the group');
  assert.match(
    main,
    /deployerObjectId: assignRoles \? deployerObjectId : ''/,
    'the grant must honour assignRoles',
  );
});

test('the agent enables both managed identities', () => {
  const module = read('infra/bicep/modules/sre-agent.bicep');

  // UserAssigned alone still deploys, but the service then creates the agent on
  // the Public Preview generation. Nothing in the resource reveals it, so this
  // regression is invisible without the test.
  assert.match(
    module,
    /type: 'SystemAssigned,UserAssigned'/,
    'dropping the system-assigned identity silently downgrades the agent generation',
  );
});

// --- Dynatrace / ServiceNow integration -------------------------------------

test('every sre_demo.* metric a Dynatrace metric event selects is emitted by an app', () => {
  const tf = read('infra/terraform/integration/dynatrace.tf');
  const emitters =
    read('apps/scenario-controller/backend/src/telemetry.ts') + read('apps/magic8ball/backend/src/index.ts');

  const selected = new Set([...tf.matchAll(/"sre_demo\.([a-z0-9_]+):/g)].map((m) => m[1]));
  // The apps emit sre_demo_<name>; dynatrace.ts maps it to sre_demo.<name>.
  const emitted = new Set([...emitters.matchAll(/'sre_demo_([a-z0-9_]+)'/g)].map((m) => m[1]));

  assert.ok(selected.size >= 6, `expected the metric events to select custom metrics, found ${selected.size}`);
  for (const metric of selected) {
    assert.ok(
      emitted.has(metric),
      `dynatrace.tf selects sre_demo.${metric} but no app emits sre_demo_${metric}, ` +
        'so the metric event can never fire.',
    );
  }
});

test('every Dynatrace metric event is a lab-prefixed problem the alerting profile forwards', () => {
  const tf = read('infra/terraform/integration/dynatrace.tf');
  const events = [...tf.matchAll(/^\s+title\s+=\s+"(\d\d [^"]+)"/gm)].map((m) => m[1]);
  assert.equal(events.length, 8, `expected 8 metric events, found ${events.length}`);
  for (const id of ['01', '02', '03', '04', '05', '06']) {
    assert.ok(events.some((t) => t.startsWith(`${id} `)), `scenario ${id} has no Dynatrace metric event`);
  }
  assert.match(tf, /title\s+=\s+"\$\{local\.title_prefix\} \$\{each\.value\.title\}"/);
  assert.match(tf, /value\s+=\s+local\.title_prefix/, 'the alerting profile must filter on the lab title prefix');
});

test('Dynatrace raises ServiceNow incidents the SRE Agent quickstart plan indexes', () => {
  // ServiceNow's default lookup gives priority 2 (High) only for impact+urgency <= 3.
  // The agent's quickstart response plan ignores anything lower.
  const tf = read('infra/terraform/integration/dynatrace.tf');
  const impact = Number(tf.match(/"impact":\s*"(\d)"/)[1]);
  const urgency = Number(tf.match(/"urgency":\s*"(\d)"/)[1]);
  assert.ok(
    impact + urgency <= 3,
    `impact ${impact} + urgency ${urgency} gives priority 3 or lower; the quickstart response plan would ignore it`,
  );
  assert.match(tf, /"assignment_group":\s*"\$\{var\.assignment_group\}"/);
  assert.match(tf, /"correlation_id":\s*"dynatrace-\{PID\}"/, 'reset-lab.sh resolves incidents by this prefix');
  assert.match(read('scripts/lib-integrations.sh'), /correlation_idSTARTSWITHdynatrace-/);
});

test('the ServiceNow webhook payload stays valid JSON after Dynatrace substitution', () => {
  // Dynatrace substitutes placeholders verbatim, without JSON escaping.
  const tf = read('infra/terraform/integration/dynatrace.tf');
  const payload = tf.match(/snow_incident_payload = <<-EOT\n([\s\S]*?)\n\s*EOT/)[1];
  const multiLine = ['ProblemDetailsText', 'ProblemDetailsHTML', 'ProblemDetailsMarkdown', 'ProblemDetailsJSON', 'ImpactedEntities'];
  for (const p of multiLine) {
    assert.ok(!payload.includes(`{${p}}`), `{${p}} is multi-line or JSON; unescaped it breaks the incident body`);
  }
  const rendered = payload.replace(/\$\{[^}]+\}/g, 'x').replace(/\{[A-Za-z]+\}/g, 'x');
  assert.doesNotThrow(() => JSON.parse(rendered), 'payload must be JSON once placeholders are filled');
});

test('each Davis anomaly detector queries the same metric and aggregation as its classic metric event', () => {
  // Latest-platform environments alert on `dql`, classic ones on `selector`;
  // a scenario must fire identically on both.
  const tf = read('infra/terraform/integration/dynatrace.tf');
  const entries = [...tf.matchAll(/^\s+"(\d\d-[a-z0-9-]+)" = \{([\s\S]*?)^\s+\}/gm)];
  assert.equal(entries.length, 8, `expected 8 alert definitions, found ${entries.length}`);
  for (const [, key, body] of entries) {
    const selector = body.match(/selector\s+=\s+"([^"]+)"/)[1];
    const dql = body.match(/dql\s+=\s+"([^"]+)"/)?.[1];
    assert.ok(dql, `${key} has no dql, so it never alerts on the latest Dynatrace platform`);
    const [, dqlAgg, dqlMetric] = dql.match(/value = (min|max|avg)\(([\w.]+)\)/);
    const selAgg = selector.match(/:(min|max|avg)$/)[1];
    const grailNames = { 'dt.host.mem.usage': 'dt.host.memory.usage' };
    const classicMetric = selector.replace(/^builtin:host\./, 'dt.host.').split(':')[0];
    const selMetric = grailNames[classicMetric] ?? classicMetric;
    assert.equal(dqlMetric, selMetric, `${key}: dql queries ${dqlMetric} but the metric event selects ${selMetric}`);
    assert.equal(dqlAgg, selAgg, `${key}: dql aggregates with ${dqlAgg} but the metric event with ${selAgg}`);
  }
  const platform = read('infra/terraform/integration/dynatrace-platform.tf');
  assert.match(platform, /for_each = var\.dynatrace_platform \? local\.metric_events : \{\}/);
  assert.match(tf, /for_each = var\.dynatrace_platform \? \{\} : local\.metric_events/);
  assert.match(platform, /value = "\$\{local\.title_prefix\} \$\{each\.value\.title\}"/, 'detector problems must carry the lab prefix');
});

test('the platform workflow only routes lab problems and raises the same incident as the webhook', () => {
  const platform = read('infra/terraform/integration/dynatrace-platform.tf');
  assert.match(platform, /custom_filter = "matchesValue\(event\.name, \\"\$\{local\.title_prefix\}\*\\"\)"/);
  const js = read('infra/terraform/integration/workflow/servicenow-incident.js');
  assert.match(js, /const correlationId = 'dynatrace-' \+ displayId;/, 'reset-lab.sh resolves incidents by this prefix');
  const impact = Number(js.match(/impact: '(\d)'/)[1]);
  const urgency = Number(js.match(/urgency: '(\d)'/)[1]);
  assert.ok(impact + urgency <= 3, `impact ${impact} + urgency ${urgency} is below priority 2; the quickstart plan ignores it`);
  assert.match(js, /startsWith\(CONFIG\.titlePrefix/, 'the deploy smoke test relies on non-lab titles being skipped');
  assert.match(js, /credentialVaultClient\.getCredentialsDetails/, 'credentials must come from the vault, not the script');
  assert.ok(!/password\s*[:=]\s*['"]/.test(js), 'no literal password in the workflow script');
  // ex.event() rejects with 403 on manual runs; un-awaited, that escapes the try as an
  // unhandled rejection and fails the task before the title check (seen live).
  for (const call of js.split('\n').filter((l) => /ex\.event\(\)/.test(l) && !l.trim().startsWith('//'))) {
    assert.match(call, /await ex\.event\(\)/, `ex.event() must be awaited: ${call.trim()}`);
  }
});

test('the workflow script is valid JavaScript once Terraform fills in CONFIG', () => {
  const js = read('infra/terraform/integration/workflow/servicenow-incident.js');
  assert.equal(js.split('__CONFIG__').length, 2, 'exactly one __CONFIG__ placeholder (Terraform replaces every occurrence)');
  const dir = mkdtempSync(join(tmpdir(), 'wf-'));
  const file = join(dir, 'task.mjs');
  writeFileSync(file, js.replace('__CONFIG__', JSON.stringify({ titlePrefix: '[sre-demo-x]', credentialId: 'c' })));
  const r = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' });
  rmSync(dir, { recursive: true, force: true });
  assert.equal(r.status, 0, `node --check failed:\n${r.stderr}`);
});

test('every Terraform output the deploy reads is declared', () => {
  const outputs = read('infra/terraform/integration/outputs.tf');
  const scripts = read('scripts/lib-integrations.sh') + read('scripts/configure-sre-agent-integrations.sh');
  const declared = new Set([...outputs.matchAll(/^output "([a-z0-9_]+)"/gm)].map((m) => m[1]));
  const used = new Set([...scripts.matchAll(/output -(?:raw|json) ([a-z0-9_]+)/g)].map((m) => m[1]));
  assert.ok(used.size >= 9, `expected the scripts to read the Terraform outputs, found ${used.size}`);
  for (const name of used) {
    assert.ok(declared.has(name), `scripts read terraform output "${name}" but outputs.tf does not declare it`);
  }
});

test('integration credentials never reach curl argv or compete with it for stdin', () => {
  const files = [
    'scripts/lib-integrations.sh',
    'scripts/configure-sre-agent-integrations.sh',
    'scripts/validate.sh',
    'scripts/reset-lab.sh',
  ];
  for (const file of files) {
    const lines = read(file).split('\n');
    lines.forEach((line, i) => {
      if (/^\s*#/.test(line)) return;
      const where = `${file}:${i + 1}`;
      assert.ok(!/\bcurl\b.*\s(-u|--user)\s/.test(line), `${where} passes credentials to curl with -u`);
      assert.ok(
        !/\bcurl\b.*-H\s+["']Authorization/.test(line),
        `${where} passes an Authorization header on curl argv; use _curl_auth`,
      );
      // _curl_auth feeds the credential to `curl -K -`, so piping a body into
      // dt_api/snow_api/_curl_auth would replace the credential with the body.
      assert.ok(
        !/\|\s*\\?\s*(dt_api|snow_api|_curl_auth)\b/.test(line) && !/^\s*\|\s*(dt_api|snow_api|_curl_auth)\b/.test(line),
        `${where} pipes into a credentialed curl helper; write the body to a file instead`,
      );
    });
  }
});

test('the DynaKube only instruments the lab namespace', () => {
  const dynakube = stripComments(read('k8s/dynatrace/dynakube.yaml'));
  assert.match(dynakube, /cloudNativeFullStack:(\n {6}.*)*\n {6}namespaceSelector:/);
  assert.match(dynakube, /key:\s*kubernetes\.io\/metadata\.name\s+operator:\s*In\s+values:\s+-\s*sre-demo\s/);
});

test('the OneAgent init container injected into lab pods satisfies the sre-demo LimitRange', () => {
  const toMi = (q) => (q.endsWith('Gi') ? parseFloat(q) * 1024 : parseFloat(q));
  const dynakube = stripComments(read('k8s/dynatrace/dynakube.yaml'));
  const init = /initResources:\s+requests:\s+cpu:\s*\S+\s+memory:\s*(\S+)/.exec(dynakube);
  assert.ok(init, 'set cloudNativeFullStack.initResources; the operator default (30Mi) is below the LimitRange minimum and every lab pod is rejected');
  const limitRange = stripComments(read('k8s/namespace.yaml'));
  const min = /min:\s+cpu:\s*\S+\s+memory:\s*(\S+)/.exec(limitRange);
  assert.ok(min, 'sre-demo LimitRange min memory not found');
  assert.ok(toMi(init[1]) >= toMi(min[1]), `init container requests ${init[1]}, LimitRange minimum is ${min[1]}`);

  const lib = read('scripts/lib-integrations.sh');
  assert.ok(dynakube.includes('image: __DT_ONEAGENT_IMAGE__'), 'the OneAgent image must be resolved at deploy time');
  assert.ok(
    lib.includes('s|__DT_ONEAGENT_IMAGE__|') && lib.includes('/__DT_ONEAGENT_IMAGE__/d'),
    'the image placeholder must be substituted, or its line dropped when no image resolves',
  );
});
test('deploy.ps1 runs the credential setup before deploy.sh, and .env tolerates CRLF', () => {
  const deploy = read('scripts/deploy.ps1');
  const setupAt = deploy.indexOf("'setup-integrations.ps1'");
  assert.ok(setupAt > 0, 'deploy.ps1 must call setup-integrations.ps1');
  assert.ok(setupAt < deploy.indexOf("Invoke-LabScript -ScriptName 'deploy.sh'"), 'setup must run before deploy.sh');
  assert.match(deploy, /-NonInteractive:\$Yes/, '-Yes must make the setup non-interactive');

  const setup = read('scripts/setup-integrations.ps1');
  assert.match(setup, /Read-Host[^\n]*-AsSecureString/, 'secrets must be read with hidden input');
  assert.match(setup, /UTF8Encoding\]::new\(\$false\)/, '.env must be written without a BOM');
  assert.match(setup, /-join "`n"/, '.env must be written with LF line endings');

  const loader = read('scripts/lib.sh');
  assert.match(loader, /line="\$\{line%\$'\\r'\}"/, 'load_env_file must strip a trailing CR');

  // System32\\bash.exe is the WSL launcher: it cannot run C:\\ paths, so Git Bash must win.
  assert.match(read('scripts/lib.ps1'), /isWslLauncher[\s\S]*SystemRoot[\s\S]*-not \$isWslLauncher/, 'Find-Bash must skip the System32 WSL launcher');
});
test('lib.ps1 argument builders accept the initially empty argument list', () => {
  const lib = read('scripts/lib.ps1');
  const params = lib.match(/\[Parameter\(Mandatory\)\][^\n]*List\[string\]\][^\n]*\$Arguments/g) ?? [];
  assert.ok(params.length >= 2, 'expected Add-LabSwitch and Add-LabOption -Arguments parameters');
  for (const p of params) assert.match(p, /\[AllowEmptyCollection\(\)\]/, `missing [AllowEmptyCollection()]: ${p}`);
});

test('AKS keeps the OIDC issuer on, because governance may enable it and it cannot be turned off', () => {
  const aks = read('infra/bicep/modules/aks.bicep');
  const block = aks.match(/oidcIssuerProfile:\s*\{([^}]*)\}/);
  assert.ok(block, 'aks.bicep must declare oidcIssuerProfile explicitly');
  assert.match(block[1], /enabled:\s*true/,
    'oidcIssuerProfile.enabled must be true: once policy enables it, false fails every redeploy with OIDCIssuerFeatureCannotBeDisabled');
});

test('ServiceNow password is read through the Terraform-first helper, not straight from Key Vault', () => {
  const lib = read('scripts/lib-integrations.sh');
  const helper = lib.match(/snow_integration_password\(\) \{([\s\S]*?)\n\}/);
  assert.ok(helper, 'lib-integrations.sh must define snow_integration_password');
  assert.ok(helper[1].indexOf('servicenow_integration_password') < helper[1].indexOf('az keyvault'),
    'Terraform state must be tried before Key Vault (policy often disables the vault\'s public access)');
  for (const script of ['scripts/validate.sh', 'scripts/reset-lab.sh']) {
    const body = read(script);
    assert.doesNotMatch(body, /keyvault secret show[^\n]*\n?[^\n]*servicenow-integration-password/,
      `${script} must use snow_integration_password instead of reading Key Vault directly`);
    assert.match(body, /snow_integration_password /, `${script} must call snow_integration_password`);
  }
});

test('grant-access.sh strips CR from jq output so Windows jq cannot corrupt CIDR lists', () => {
  const body = read('scripts/grant-access.sh');
  const jqLines = body.split('\n').filter((l) => /jq -r/.test(l));
  assert.ok(jqLines.length >= 2);
  for (const start of jqLines) {
    const idx = body.indexOf(start);
    const stmt = body.slice(idx, body.indexOf(')', body.indexOf("2>/dev/null", idx)) + 40);
    assert.match(stmt, /tr -d '\\r'/, `jq output must pass through tr -d '\\r': ${start.trim()}`);
  }
});

