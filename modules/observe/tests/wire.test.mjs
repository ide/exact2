// Observe's web and Apple services against wire.json, the bodies all three services must send.
// The Linux service runs the same fixture in host/linux/tests/observe.
// `bun test ./modules/observe/tests/wire.test.mjs`. The Apple half needs swiftc, so it runs on macOS only.
import { expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = import.meta.dir;
const fixture = await Bun.file(join(dir, 'wire.json')).json();

// The resource keys wire.json compares: those in its expected bodies and the platform's.
const shared = fixture.expected.metrics.resourceMetrics[0].resource.attributes;
const resourceKeys = platform => new Set([...shared.map(a => a.key), ...Object.keys(fixture.platforms[platform].resource)]);

/** A body in the form wire.json compares: see its `about`. */
function normalize(body, platform) {
  const keep = resourceKeys(platform);
  for (const r of Object.values(body)[0]) {
    r.resource.attributes = r.resource.attributes.filter(a => keep.has(a.key)).sort((a, b) => a.key.localeCompare(b.key));
    for (const scope of r.scopeMetrics ?? []) {
      for (const m of scope.metrics) for (const p of m.gauge.dataPoints) for (const a of p.attributes)
        if (a.key === 'expo.custom_params' && typeof a.value.stringValue === 'string') a.value.stringValue = JSON.parse(a.value.stringValue);
      scope.metrics.sort((a, b) => a.name.localeCompare(b.name) || a.gauge.dataPoints[0].timeUnixNano - b.gauge.dataPoints[0].timeUnixNano);
    }
  }
  return body;
}

/** wire.json's expected body with the platform's own resource attributes and launch params added. */
function expected(signal, platform) {
  const p = fixture.platforms[platform];
  const body = structuredClone(fixture.expected[signal]);
  for (const r of Object.values(body)[0]) {
    r.resource.attributes.push(...Object.entries(p.resource).map(([key, v]) => ({ key, value: { stringValue: v } })));
    for (const scope of r.scopeMetrics ?? []) for (const m of scope.metrics) for (const a of m.gauge.dataPoints[0].attributes) {
      if (a.key !== 'expo.custom_params') continue;
      const params = JSON.parse(a.value.stringValue);
      const extra = m.name.startsWith('expo.app_startup.') ? p.startupParams : params.isAppLaunch ? p.launchNavigationParams : {};
      a.value.stringValue = { ...params, ...extra };
    }
  }
  return normalize(body, platform);
}

function check(actual, platform) {
  for (const signal of ['metrics', 'logs']) expect(normalize(actual[signal], platform)).toEqual(expected(signal, platform));
}

test('the web service sends wire.json\'s bodies', async () => {
  const storage = new Map([['expo.eas-client-id', fixture.clientId]]);
  const sent = {};
  const names = ['localStorage', 'navigator', 'setTimeout', 'fetch'];
  const saved = Object.fromEntries(names.map(n => [n, Object.getOwnPropertyDescriptor(globalThis, n)]));
  const randomUUID = crypto.randomUUID;
  Object.assign(globalThis, {
    localStorage: { getItem: k => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, String(v)) },
    navigator: { platform: 'MacIntel', language: 'en-US', onLine: true, connection: { type: 'wifi' } },
    setTimeout: () => 0,
    fetch: async (url, init) => { sent[url.split('/').pop()] = JSON.parse(init.body); return new Response(null, { status: 200 }); },
  });
  crypto.randomUUID = () => fixture.session;
  try {
    const { start } = await import('../web/service.js');
    const service = start({ 'app.CFBundleIdentifier': fixture.app.id, 'app.CFBundleName': fixture.app.name, environment: fixture.environment, projectId: 'p', endpoint: 'http://sink' });
    for (const e of fixture.events) service.event({ ...e, wall: e.wall * 1000 });
    service.background();
    await new Promise(r => saved.setTimeout.value(r, 0));
  } finally {
    for (const n of names) saved[n] ? Object.defineProperty(globalThis, n, saved[n]) : delete globalThis[n];
    crypto.randomUUID = randomUUID;
  }
  check(sent, 'web');
});

test.skipIf(process.platform !== 'darwin')('the Apple service sends wire.json\'s bodies', () => {
  const work = mkdtempSync(join(tmpdir(), 'observe-wire-'));
  try {
    const exe = join(work, 'harness');
    const service = ['ObserveService', 'ObserveWire', 'ObserveRules', 'ObserveStore'].map(f => join(dir, `../apple/service/${f}.swift`));
    const build = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', join(work, 'cache'),
      ...service, join(dir, 'wire.swift'), '-lsqlite3', '-o', exe], { encoding: 'utf8' });
    expect(build.status, build.stderr).toBe(0);
    const run = spawnSync(exe, [join(dir, 'wire.json'), join(work, 'store')], { encoding: 'utf8' });
    expect(run.status, run.stderr).toBe(0);
    check(JSON.parse(run.stdout), 'apple');
  } finally { rmSync(work, { recursive: true, force: true }); }
}, 120_000);
