/**
 * Dynatrace Metrics API v2 sink.
 *
 * Every custom `sre_demo_*` metric the controller sends to Application Insights
 * is also sent here, so the Dynatrace metric events in
 * infra/terraform/integration/dynatrace.tf see exactly the same signal the
 * Azure Monitor alert rules do. OneAgent covers the native signal (hosts,
 * processes, Kubernetes, request failure rates); these custom metrics only
 * shorten the detection window to something a live demo can accommodate.
 *
 * Like the Application Insights sink, this is best-effort: a monitoring
 * endpoint being unreachable must never take the control plane down.
 */

export interface DynatraceSinkConfig {
  /** Classic environment API base, e.g. https://abc12345.live.dynatrace.com */
  apiUrl: string;
  /** Access token with the metrics.ingest scope. */
  token: string;
  /** Dimensions stamped onto every data point. */
  dimensions?: Record<string, string>;
}

/** Maps an App Insights metric name to its Dynatrace metric key. Keep in step with dynatrace.tf. */
export function toDynatraceKey(name: string): string {
  return name.startsWith('sre_demo_') ? `sre_demo.${name.slice('sre_demo_'.length)}` : `sre_demo.${name}`;
}

function cleanDimensionKey(key: string): string {
  const cleaned = key.toLowerCase().replace(/[^a-z0-9_.-]/g, '_').replace(/^[^a-z]+/, '');
  return cleaned.slice(0, 100) || 'dim';
}

function cleanDimensionValue(value: string): string {
  // Line protocol: quote the value and escape quotes/backslashes; strip newlines.
  const trimmed = value.replace(/[\r\n]/g, ' ').slice(0, 250);
  return `"${trimmed.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

export function formatLine(name: string, value: number, dimensions: Record<string, string>): string | undefined {
  if (!Number.isFinite(value)) return undefined;
  const dims = Object.entries(dimensions)
    .filter(([, v]) => v !== undefined && v !== '')
    .map(([k, v]) => `${cleanDimensionKey(k)}=${cleanDimensionValue(v)}`);
  const head = [toDynatraceKey(name), ...dims].join(',');
  return `${head} ${value}`;
}

class DynatraceSink {
  private endpoint: string | undefined;
  private token = '';
  private dimensions: Record<string, string> = {};
  private queue: string[] = [];
  private timer: NodeJS.Timeout | undefined;
  private flushing = false;
  lastStatus: { ok: boolean; at: string; detail: string } | undefined;

  configure(config: DynatraceSinkConfig): void {
    if (!config.apiUrl || !config.token) return;
    // Accept the environment root with or without the /api suffix OneAgent uses;
    // doubling it (/api/api/v2/...) returns 404 and silently drops every metric.
    this.endpoint = `${config.apiUrl.replace(/\/+$/, '').replace(/\/api$/, '')}/api/v2/metrics/ingest`;
    this.token = config.token;
    this.dimensions = config.dimensions ?? {};
    if (!this.timer) {
      this.timer = setInterval(() => void this.flush(), 10_000);
      this.timer.unref();
    }
  }

  get enabled(): boolean {
    return this.endpoint !== undefined;
  }

  push(name: string, value: number, dimensions: Record<string, string> = {}): void {
    if (!this.endpoint) return;
    const line = formatLine(name, value, { ...this.dimensions, ...dimensions });
    if (!line) return;
    this.queue.push(line);
    if (this.queue.length > 2000) this.queue.splice(0, this.queue.length - 2000);
    // The ingest API accepts up to 1000 lines per request.
    if (this.queue.length >= 500) void this.flush();
  }

  async flush(): Promise<void> {
    if (!this.endpoint || this.flushing || this.queue.length === 0) return;
    this.flushing = true;
    const batch = this.queue.splice(0, 1000);
    try {
      const response = await fetch(this.endpoint, {
        method: 'POST',
        headers: {
          authorization: `Api-Token ${this.token}`,
          'content-type': 'text/plain; charset=utf-8',
        },
        body: batch.join('\n'),
        signal: AbortSignal.timeout(10_000),
      });
      const detail = response.ok ? `${response.status}` : `${response.status} ${(await response.text()).slice(0, 300)}`;
      this.lastStatus = { ok: response.ok, at: new Date().toISOString(), detail };
      if (response.status >= 500 || response.status === 429) this.queue.unshift(...batch.slice(0, 500));
    } catch (error) {
      this.lastStatus = { ok: false, at: new Date().toISOString(), detail: String(error) };
      this.queue.unshift(...batch.slice(0, 500));
    } finally {
      this.flushing = false;
    }
  }
}

export const dynatrace = new DynatraceSink();
