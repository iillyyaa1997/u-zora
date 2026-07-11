#!/usr/bin/env node
/**
 * End-to-end smoke test for the uZora → Claude-Code channel shim.
 *
 * 1. Copies the built bundle to a scratch dir with NO node_modules (proves the
 *    esbuild bundle is self-contained / runnable without an npm install).
 * 2. Starts a tiny mock SSE server that emits ONE `escalated` (critical) event.
 * 3. Spawns the built shim over stdio, drives the MCP `initialize` handshake,
 *    and asserts:
 *      a. the server advertises `experimental: { 'claude/channel': {} }` +
 *         an `instructions` string in its initialize result;
 *      b. the shim writes a `notifications/claude/channel` JSON-RPC message to
 *         stdout, with the mapped one-line `content` and an identifier-safe
 *         `meta` (kind=escalated, alert_id=disk:/, severity=critical,
 *         previous_severity=warn).
 * 4. Also runs pure `mapEvent` / `passesSeverity` unit assertions on the bundle.
 *
 * Exit 0 = pass; non-zero = fail.
 */

import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const BUILT = join(__dirname, 'dist', 'uzora-channel.js');

let failures = 0;
function assert(cond, msg) {
  if (cond) {
    console.log(`  PASS  ${msg}`);
  } else {
    console.error(`  FAIL  ${msg}`);
    failures++;
  }
}

// ---------------------------------------------------------------------------
// Part 1 — pure mapping/severity unit assertions (import the bundle directly)
// ---------------------------------------------------------------------------
async function unitAssertions() {
  console.log('[unit] mapEvent / passesSeverity');
  const m = await import(pathToFileURL(BUILT).href);

  const esc = m.mapEvent('escalated', {
    ts: '2026-07-12T00:00:00Z',
    kind: 'escalated',
    alert: { probe: 'disk', key: '/', severity: 'critical', message: 'Disk 98% full' },
    previous_severity: 'warn',
  });
  assert(esc.meta.kind === 'escalated', 'escalated meta.kind');
  assert(esc.meta.alert_id === 'disk:/', 'escalated meta.alert_id reconstructed (probe:key)');
  assert(esc.meta.severity === 'critical', 'escalated meta.severity');
  assert(esc.meta.previous_severity === 'warn', 'escalated meta.previous_severity');
  assert(Object.keys(esc.meta).every((k) => /^[A-Za-z0-9_]+$/.test(k)), 'escalated meta keys identifier-safe');

  const diag = m.mapEvent('diagnosed', {
    kind: 'diagnosed', detector: 'runaway_daemon', subject: 'ecosystemd',
    severity: 'warn', confidence: 'high', title: 'ecosystemd is spinning', suggested_action: 'restart it',
  });
  assert(diag.meta.finding_id === 'runaway_daemon:ecosystemd', 'diagnosed meta.finding_id (detector:subject)');

  const verdict = m.mapEvent('verdict_changed', {
    kind: 'verdict_changed', previous_level: 'good', level: 'degraded', headline: 'CPU pinned',
  });
  assert(verdict.meta.level === 'degraded' && verdict.meta.previous_level === 'good', 'verdict_changed meta level/previous_level');

  // severity filter (default warn)
  assert(m.passesSeverity('appeared', { alert: { severity: 'info' } }, 'warn') === false, 'info appeared suppressed at warn');
  assert(m.passesSeverity('appeared', { alert: { severity: 'warn' } }, 'warn') === true, 'warn appeared forwarded at warn');
  assert(m.passesSeverity('escalated', { alert: { severity: 'critical' } }, 'warn') === true, 'critical escalated forwarded at warn');
  assert(m.passesSeverity('cleared', { alert_id: 'disk:/' }, 'warn') === false, 'raw cleared suppressed at warn');
  assert(m.passesSeverity('verdict_changed', {}, 'critical') === true, 'verdict_changed always forwarded');
  assert(m.mapEvent('bogus', {}) === null, 'unknown event maps to null');
}

// ---------------------------------------------------------------------------
// Part 2 — full stdio-MCP e2e
// ---------------------------------------------------------------------------
function startMockSse() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      if (req.url !== '/stream') { res.writeHead(404); res.end(); return; }
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
      });
      res.write(': connected\n\n');
      // Emit ONE escalated (critical) event shortly after connect.
      setTimeout(() => {
        const body = JSON.stringify({
          ts: '2026-07-12T00:00:00Z',
          kind: 'escalated',
          alert: {
            probe: 'disk', key: '/', severity: 'critical', message: 'Disk 98% full',
            first_seen: '2026-07-12T00:00:00Z', last_updated: '2026-07-12T00:00:00Z',
          },
          previous_severity: 'warn',
        });
        res.write(`event: escalated\ndata: ${body}\n\n`);
      }, 300);
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

async function e2e() {
  console.log('[e2e] stdio-MCP handshake + channel notification');

  // Copy the bundle (+ its `type:module` marker) to a scratch dir with NO
  // node_modules — proves the esbuild bundle is self-contained.
  const scratch = mkdtempSync(join(tmpdir(), 'uzora-channel-smoke-'));
  const bundleCopy = join(scratch, 'uzora-channel.js');
  copyFileSync(BUILT, bundleCopy);
  copyFileSync(join(__dirname, 'dist', 'package.json'), join(scratch, 'package.json'));

  const sse = await startMockSse();
  const { port } = sse.address();
  const streamUrl = `http://127.0.0.1:${port}/stream`;

  const child = spawn(process.execPath, [bundleCopy], {
    cwd: scratch, // no node_modules here — must still run
    env: { ...process.env, UZORA_STREAM_URL: streamUrl, UZORA_MIN_SEVERITY: 'warn' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  child.stderr.on('data', (d) => process.stderr.write(`  [shim] ${d}`));
  child.on('error', (e) => console.error('  [child error]', e));
  let killed = false;
  child.on('exit', (c, s) => {
    if (!killed) console.error(`  [child exit] code=${c} signal=${s} (unexpected)`);
  });

  const messages = [];
  let buf = '';
  child.stdout.on('data', (chunk) => {
    buf += chunk.toString('utf8');
    let idx;
    while ((idx = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (!line) continue;
      try { messages.push(JSON.parse(line)); } catch { /* ignore non-JSON */ }
    }
  });

  const send = (obj) => child.stdin.write(JSON.stringify(obj) + '\n');

  // Drive the MCP handshake.
  send({
    jsonrpc: '2.0', id: 1, method: 'initialize',
    params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'smoke', version: '0.0.0' } },
  });

  const deadline = Date.now() + 8000;
  const waitFor = (pred) =>
    new Promise((resolve, reject) => {
      const tick = () => {
        const hit = messages.find(pred);
        if (hit) return resolve(hit);
        if (Date.now() > deadline) return reject(new Error('timeout waiting for message'));
        setTimeout(tick, 50);
      };
      tick();
    });

  try {
    const initResult = await waitFor((mm) => mm.id === 1 && mm.result);
    const caps = initResult.result.capabilities || {};
    assert(!!(caps.experimental && caps.experimental['claude/channel']), 'initialize advertises experimental["claude/channel"]');
    assert(typeof initResult.result.instructions === 'string' && initResult.result.instructions.length > 0, 'initialize includes non-empty instructions');

    // Complete the handshake.
    send({ jsonrpc: '2.0', method: 'notifications/initialized' });

    // The mock server emits the escalated event ~300ms after SSE connect; the
    // shim maps it and pushes a channel notification to stdout.
    const note = await waitFor((mm) => mm.method === 'notifications/claude/channel');
    assert(!!note.params && typeof note.params.content === 'string', 'channel notification has string content');
    assert(/escalated/i.test(note.params.content) && /Disk 98% full/.test(note.params.content), `content mapped correctly: "${note.params.content}"`);
    const meta = note.params.meta || {};
    assert(meta.kind === 'escalated', 'notification meta.kind = escalated');
    assert(meta.alert_id === 'disk:/', 'notification meta.alert_id = disk:/');
    assert(meta.severity === 'critical', 'notification meta.severity = critical');
    assert(meta.previous_severity === 'warn', 'notification meta.previous_severity = warn');
    assert(Object.keys(meta).every((k) => /^[A-Za-z0-9_]+$/.test(k)), 'notification meta keys identifier-safe (no hyphens)');
  } finally {
    killed = true;
    child.kill('SIGKILL');
    sse.close();
  }
}

// ---------------------------------------------------------------------------
(async () => {
  await unitAssertions();
  await e2e();
  console.log('');
  if (failures === 0) {
    console.log('SMOKE TEST: ALL PASSED');
    process.exit(0);
  } else {
    console.error(`SMOKE TEST: ${failures} FAILURE(S)`);
    process.exit(1);
  }
})().catch((err) => {
  console.error('SMOKE TEST ERROR:', err);
  process.exit(1);
});
