/**
 * uZora → Claude-Code channel shim.
 *
 * A tiny stdio MCP server that Claude Code spawns as a subprocess. It subscribes
 * to uZora's `GET /stream` (loopback SSE) and re-emits each event as a
 * `notifications/claude/channel` notification — the proprietary Claude-Code
 * "channel" capability. This is the ONE production path for "uZora makes Claude
 * act while you're away"; every other client keeps pulling `/status`, `/findings`
 * etc.
 *
 * The shim is a PURE EXTERNAL CONSUMER of uZora's already-shipped HTTP surface —
 * it modifies no uZora Swift code. One-way for v1 (no reply tool).
 *
 * Contract (Claude-Code Channels, research preview):
 *  - Declares `experimental: { 'claude/channel': {} }` in its Server capabilities.
 *  - Pushes via a fire-and-forget JSON-RPC notification:
 *      { method: 'notifications/claude/channel',
 *        params: { content: '<tag body>', meta: { <tag attributes> } } }
 *  - `meta` keys MUST be identifier-safe (letters/digits/underscore) — hyphenated
 *    keys are silently dropped. uZora's keys are snake_case, so we are safe; we
 *    additionally filter defensively.
 *
 * Env:
 *  - UZORA_STREAM_URL   (default http://127.0.0.1:39842/stream)
 *  - UZORA_MIN_SEVERITY (info|warn|critical, default warn)
 *  - UZORA_TOKEN        (optional; sent as `Authorization: Bearer` — future-proofs
 *                        a gated /stream; harmless today since /stream is ungated)
 */

import { realpathSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { EventSource, type EventSourceFetchInit } from 'eventsource';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const DEFAULT_STREAM_URL = 'http://127.0.0.1:39842/stream';
const CHANNEL_METHOD = 'notifications/claude/channel';

/** SSE event names emitted by uZora's `GET /stream`. */
const EVENT_NAMES = [
  'appeared',
  'escalated',
  'cleared',
  'diagnosed',
  'rediagnosed',
  'resolved',
  'verdict_changed',
] as const;

const INITIAL_BACKOFF_MS = 500;
const MAX_BACKOFF_MS = 15_000;

// stdout is the MCP JSON-RPC channel — ALL logging MUST go to stderr.
function log(...args: unknown[]): void {
  process.stderr.write(`[uzora-channel] ${args.map(String).join(' ')}\n`);
}

// ---------------------------------------------------------------------------
// Severity filter (noise control)
// ---------------------------------------------------------------------------

export type MinSeverity = 'info' | 'warn' | 'critical';

const SEVERITY_RANK: Record<string, number> = { info: 0, warn: 1, critical: 2 };

export function severityRank(sev: string | undefined): number {
  return sev !== undefined && sev in SEVERITY_RANK ? SEVERITY_RANK[sev] : 0;
}

export function parseMinSeverity(raw: string | undefined): MinSeverity {
  const v = (raw ?? '').trim().toLowerCase();
  return v === 'info' || v === 'warn' || v === 'critical' ? v : 'warn';
}

/**
 * Decide whether an SSE event survives the severity filter.
 *
 * Rule (documented in README.md):
 *  - Diagnosis-layer events (diagnosed / rediagnosed / resolved / verdict_changed)
 *    are ALWAYS forwarded — high-value, low-volume proactive-diagnosis signals.
 *  - Raw watchdog transitions are severity-gated:
 *      · appeared / escalated → forward iff alert.severity >= minSeverity
 *      · cleared (no severity, treated as info) → forward only when min == info
 * At the default `warn`: warn+critical appeared/escalated + all diagnosis/verdict
 * events pass; info-level alerts and raw `cleared` are suppressed as chatter.
 */
export function passesSeverity(
  name: string,
  data: Record<string, unknown>,
  min: MinSeverity,
): boolean {
  const minRank = SEVERITY_RANK[min];
  switch (name) {
    case 'diagnosed':
    case 'rediagnosed':
    case 'resolved':
    case 'verdict_changed':
      return true;
    case 'appeared':
    case 'escalated': {
      const alert = (data.alert ?? {}) as Record<string, unknown>;
      return severityRank(alert.severity as string | undefined) >= minRank;
    }
    case 'cleared':
      return minRank <= SEVERITY_RANK.info;
    default:
      return false;
  }
}

// ---------------------------------------------------------------------------
// Event → channel-notification mapping (pure, unit-testable)
// ---------------------------------------------------------------------------

export interface ChannelPayload {
  content: string;
  meta: Record<string, string>;
}

/** Keep only identifier-safe keys with non-empty string values. */
function safeMeta(entries: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(entries)) {
    if (v === undefined || v === null) continue;
    if (!/^[A-Za-z0-9_]+$/.test(k)) continue; // never emit a hyphenated key
    const s = String(v);
    if (s.length === 0) continue;
    out[k] = s;
  }
  return out;
}

function str(v: unknown): string | undefined {
  return typeof v === 'string' ? v : v === undefined || v === null ? undefined : String(v);
}

/**
 * Map one SSE (event-name, parsed-data) into a human/LLM-readable one-liner
 * `content` plus an identifier-safe `meta`. Returns null for malformed/unknown
 * events (skip). Pure — no I/O — so it is unit-testable in isolation.
 */
export function mapEvent(name: string, data: Record<string, unknown>): ChannelPayload | null {
  switch (name) {
    case 'appeared': {
      const alert = (data.alert ?? {}) as Record<string, unknown>;
      const id = alertId(alert);
      const sev = str(alert.severity);
      const msg = str(alert.message) ?? '(no message)';
      return {
        content: `uZora alert appeared: ${msg} [severity=${sev ?? '?'}, id=${id ?? '?'}]`,
        meta: safeMeta({ kind: 'appeared', alert_id: id, severity: sev }),
      };
    }
    case 'escalated': {
      const alert = (data.alert ?? {}) as Record<string, unknown>;
      const id = alertId(alert);
      const sev = str(alert.severity);
      const prev = str(data.previous_severity);
      const msg = str(alert.message) ?? '(no message)';
      return {
        content: `uZora alert escalated: ${msg} [${prev ?? '?'} -> ${sev ?? '?'}, id=${id ?? '?'}]`,
        meta: safeMeta({ kind: 'escalated', alert_id: id, severity: sev, previous_severity: prev }),
      };
    }
    case 'cleared': {
      const id = str(data.alert_id);
      return {
        content: `uZora alert cleared: ${id ?? '?'}`,
        meta: safeMeta({ kind: 'cleared', alert_id: id }),
      };
    }
    case 'diagnosed': {
      const id = findingId(data);
      const sev = str(data.severity);
      const subject = str(data.subject);
      const title = str(data.title) ?? '(finding)';
      const action = str(data.suggested_action);
      const conf = str(data.confidence);
      return {
        content:
          `uZora diagnosed: ${title}` +
          (action ? ` — suggested: ${action}` : '') +
          ` [severity=${sev ?? '?'}, confidence=${conf ?? '?'}, subject=${subject ?? '?'}]`,
        meta: safeMeta({ kind: 'diagnosed', finding_id: id, severity: sev, subject }),
      };
    }
    case 'rediagnosed': {
      const id = findingId(data);
      const sev = str(data.severity);
      const prevSev = str(data.previous_severity);
      const subject = str(data.subject);
      const title = str(data.title) ?? '(finding)';
      const action = str(data.suggested_action);
      const conf = str(data.confidence);
      return {
        content:
          `uZora re-diagnosed: ${title}` +
          (action ? ` — suggested: ${action}` : '') +
          ` [${prevSev ?? '?'} -> ${sev ?? '?'}, confidence=${conf ?? '?'}, subject=${subject ?? '?'}]`,
        meta: safeMeta({
          kind: 'rediagnosed',
          finding_id: id,
          severity: sev,
          subject,
          previous_severity: prevSev,
        }),
      };
    }
    case 'resolved': {
      const id = str(data.finding_id);
      return {
        content: `uZora finding resolved: ${id ?? '?'}`,
        meta: safeMeta({ kind: 'resolved', finding_id: id }),
      };
    }
    case 'verdict_changed': {
      const prev = str(data.previous_level);
      const level = str(data.level);
      const headline = str(data.headline) ?? '';
      return {
        content: `uZora system verdict ${prev ?? '?'} -> ${level ?? '?'}${headline ? `: ${headline}` : ''}`,
        meta: safeMeta({ kind: 'verdict_changed', level, previous_level: prev }),
      };
    }
    default:
      return null;
  }
}

/** Reconstruct an alert id (`probe:key`) — uZora's `Alert.id` is a computed
 *  property and is NOT encoded in the SSE JSON, so we rebuild it. */
function alertId(alert: Record<string, unknown>): string | undefined {
  const probe = str(alert.probe);
  const key = str(alert.key);
  if (probe === undefined || key === undefined) return undefined;
  return `${probe}:${key}`;
}

/** Diagnosis finding id (`detector:subject`) — mirrors uZora's `resolved`
 *  `finding_id` format so diagnosed/resolved correlate. */
function findingId(data: Record<string, unknown>): string | undefined {
  const detector = str(data.detector);
  const subject = str(data.subject);
  if (detector === undefined || subject === undefined) return undefined;
  return `${detector}:${subject}`;
}

// ---------------------------------------------------------------------------
// SSE client with self-owned exponential-backoff reconnection
// ---------------------------------------------------------------------------

const CHANNEL_INSTRUCTIONS = [
  'This channel relays live system-health events from uZora (the Mac watchdog running on this machine).',
  'Each notification arrives as a <uzora> tag whose body is a one-line event summary and whose attributes are:',
  '  kind (appeared|escalated|cleared|diagnosed|rediagnosed|resolved|verdict_changed),',
  '  alert_id or finding_id, severity (info|warn|critical), subject,',
  '  and previous_severity / previous_level where applicable.',
  'Events are proactive and one-way (you cannot reply on this channel). Treat escalated/critical alerts',
  'and verdict_changed -> degraded/problem as signals the operator likely wants acted on while they are away.',
].join('\n');

interface SseOptions {
  url: string;
  token?: string;
  min: MinSeverity;
  onPayload: (payload: ChannelPayload) => void;
}

function startSse(opts: SseOptions): () => void {
  let es: EventSource | null = null;
  let backoffMs = INITIAL_BACKOFF_MS;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let stopped = false;

  const authedFetch = opts.token
    ? (url: string | URL, init: EventSourceFetchInit) =>
        fetch(url, {
          ...init,
          headers: { ...init.headers, Authorization: `Bearer ${opts.token}` },
        } as RequestInit)
    : undefined;

  function scheduleReconnect(): void {
    if (stopped || reconnectTimer) return;
    const delay = backoffMs;
    backoffMs = Math.min(backoffMs * 2, MAX_BACKOFF_MS);
    log(`SSE disconnected; reconnecting in ${delay}ms (${opts.url})`);
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, delay);
  }

  function handle(name: string, raw: string): void {
    // NEVER throw out of the SSE handler.
    try {
      const data = JSON.parse(raw) as Record<string, unknown>;
      if (!passesSeverity(name, data, opts.min)) return;
      const payload = mapEvent(name, data);
      if (payload) opts.onPayload(payload);
    } catch (err) {
      log(`failed to handle '${name}' event:`, (err as Error).message);
    }
  }

  function connect(): void {
    if (stopped) return;
    try {
      const source = new EventSource(opts.url, authedFetch ? { fetch: authedFetch } : undefined);
      es = source;
      source.onopen = () => {
        backoffMs = INITIAL_BACKOFF_MS; // reset backoff on a healthy connection
        log(`SSE connected: ${opts.url}`);
      };
      for (const name of EVENT_NAMES) {
        source.addEventListener(name, (ev) => handle(name, (ev as MessageEvent).data as string));
      }
      source.onerror = () => {
        // Take over reconnection with OUR exponential backoff: close the native
        // retrying connection so we never end up with duplicates, then reschedule.
        try {
          source.close();
        } catch {
          /* ignore */
        }
        if (es === source) es = null;
        scheduleReconnect();
      };
    } catch (err) {
      log('SSE connect threw:', (err as Error).message);
      scheduleReconnect();
    }
  }

  connect();

  return () => {
    stopped = true;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    try {
      es?.close();
    } catch {
      /* ignore */
    }
  };
}

// ---------------------------------------------------------------------------
// Main: wire the MCP stdio server to the SSE client
// ---------------------------------------------------------------------------

export async function main(): Promise<void> {
  const url = process.env.UZORA_STREAM_URL || DEFAULT_STREAM_URL;
  const min = parseMinSeverity(process.env.UZORA_MIN_SEVERITY);
  const token = process.env.UZORA_TOKEN || undefined;

  const server = new Server(
    { name: 'uzora', version: '0.1.0' },
    {
      capabilities: {
        // REQUIRED for the Claude-Code channel capability. Always `{}`.
        experimental: { 'claude/channel': {} },
      },
      instructions: CHANNEL_INSTRUCTIONS,
    },
  );

  let mcpReady = false;

  function emit(payload: ChannelPayload): void {
    if (!mcpReady) return; // no open session yet — nothing to push to
    // Fire-and-forget: never block, never throw.
    server
      .notification({ method: CHANNEL_METHOD, params: { content: payload.content, meta: payload.meta } })
      .catch((err: unknown) => log('notification failed:', (err as Error).message));
  }

  // Keep the SSE client alive regardless of uZora availability — a dead stdio
  // server shows as "Failed to connect" in Claude Code, so we must NOT crash if
  // uZora is unreachable at spawn. startSse retries with backoff.
  const stopSse = startSse({ url, token, min, onPayload: emit });

  const transport = new StdioServerTransport();
  await server.connect(transport);
  mcpReady = true;
  log(`MCP stdio server connected (stream=${url}, min_severity=${min}, token=${token ? 'yes' : 'no'})`);

  const shutdown = () => {
    stopSse();
    server.close().catch(() => undefined);
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

// Only auto-start when executed directly (`node dist/uzora-channel.js`), so the
// pure mapping functions can be imported by the smoke/unit tests without booting
// the server. Compare REALPATHS: Node realpaths the main module for
// `import.meta.url`, but `process.argv[1]` is left as-passed, so a symlinked run
// dir (macOS `/var`→`/private/var`, or any symlinked install path) would
// otherwise mismatch and never boot.
function isDirectRun(): boolean {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    // Fall back to a plain URL comparison if realpath is unavailable.
    return import.meta.url === pathToFileURL(entry).href;
  }
}

if (isDirectRun()) {
  main().catch((err) => {
    log('fatal:', (err as Error).message);
    process.exit(1);
  });
}
