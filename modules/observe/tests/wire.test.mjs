// Observe's web and Apple services against wire.json, the bodies all three services must send.
// The Linux service runs the same fixture in host/linux/tests/observe.
// `bun test ./modules/observe/tests/wire.test.mjs`. The Apple half needs swiftc, so it runs on macOS only.
import { expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
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
      const extra = m.name.startsWith('expo.app_startup.') ? { ...p.startupParams, ...(m.name === 'expo.app_startup.tti' ? p.ttiParams : {}) } : params.isAppLaunch ? p.launchNavigationParams : {};
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
    const ms = walls => walls && Object.fromEntries(Object.entries(walls).map(([k, v]) => [k, v * 1000]));
    for (const e of fixture.events) service.event({ ...e, wall: e.wall * 1000, walls: ms(e.walls) });
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
    const out = JSON.parse(run.stdout);
    check(out, 'apple');
    // What an app's own screen reads back (`ExactServices.query("observe", …)`):
    // the newest rows first, none sent yet, at most the limit.
    const { session, metrics } = out.recent;
    expect(session).toBe(fixture.session);
    expect(metrics.length).toBeLessThanOrEqual(3);
    expect(metrics.length).toBeGreaterThan(0);
    expect(metrics.every(m => m.sent === false && typeof m.value === 'number' && typeof m.name === 'string')).toBe(true);
    expect(metrics.map(m => m.time)).toEqual([...metrics.map(m => m.time)].sort((a, b) => b - a));
    expect(out.unknown.error).toContain('recent');
  } finally { rmSync(work, { recursive: true, force: true }); }
}, 120_000);

test.skipIf(process.platform !== 'darwin')('the Apple service labels each row with the update that ran when it was recorded', () => {
  const work = mkdtempSync(join(tmpdir(), 'observe-update-'));
  try {
    const exe = join(work, 'harness');
    const service = ['ObserveService', 'ObserveWire', 'ObserveRules', 'ObserveStore'].map(f => join(dir, `../apple/service/${f}.swift`));
    const build = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', join(work, 'cache'),
      ...service, join(dir, 'wire.swift'), '-lsqlite3', '-o', exe], { encoding: 'utf8' });
    expect(build.status, build.stderr).toBe(0);
    const navigation = fixture.events.find(e => e.kind === 'navigation');
    const updates = events => {
      const path = join(work, `fixture-${Math.random()}.json`);
      writeFileSync(path, JSON.stringify({ ...fixture, events }));
      const run = spawnSync(exe, [path, join(work, `store-${Math.random()}`)], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      // Each resource's update id, with the metric names it holds.
      return JSON.parse(run.stdout).metrics.resourceMetrics.map(r => [
        r.resource.attributes.find(a => a.key === 'expo.app.update_id')?.value.stringValue ?? null,
        r.scopeMetrics[0].metrics.map(m => m.name)]);
    };
    // A live activation: the rows before it keep the update they ran under.
    const live = updates([{ kind: 'update.launched', entry: 'a'.repeat(64), seq: 1 }, navigation, { kind: 'update.launched', entry: 'b'.repeat(64), seq: 2 }, navigation]);
    expect(live.map(([id]) => id)).toEqual(['a'.repeat(64), 'b'.repeat(64)]);
    expect(live.every(([, names]) => names.length === 1)).toBe(true);
    // A live activation before startup's report: the startup metrics keep the update their marks are of.
    const startupEvent = fixture.events.find(e => e.kind === 'startup');
    const relabel = updates([{ kind: 'update.launched', entry: 'a'.repeat(64), seq: 1 }, { kind: 'update.launched', entry: 'b'.repeat(64), seq: 2 }, { ...startupEvent, update: 'a'.repeat(64) }]);
    expect(relabel.map(([id]) => id)).toEqual(['a'.repeat(64)]);
    // A refused update: the embedded app runs, and its rows carry no update id.
    const refused = updates([{ kind: 'update.launched', entry: 'a'.repeat(64), seq: 1 }, { kind: 'update.launched', entry: '', seq: 0 }, navigation]);
    expect(refused.map(([id]) => id)).toEqual([null]);

    // A crash under update A, recovered at the next launch (another session, no update): it keeps A.
    const store = join(work, 'crash-store');
    const run = f => {
      const path = join(work, `fixture-${Math.random()}.json`);
      writeFileSync(path, JSON.stringify(f));
      const r = spawnSync(exe, [path, store], { encoding: 'utf8' });
      expect(r.status, r.stderr).toBe(0);
      return JSON.parse(r.stdout);
    };
    // Now, not the fixture's 2023: the store forgets rows and sessions past its retention.
    const now = Date.now() / 1000;
    run({ ...fixture, sessionStart: now, events: [{ kind: 'update.launched', entry: 'a'.repeat(64), seq: 1 }, { ...navigation, wall: now }] });
    writeFileSync(join(store, `exact-observe-pending-${fixture.session}-${fixture.app.id}.json`),
      JSON.stringify({ session: fixture.session, app: fixture.app.id, sessionStart: now, metadata: {}, signal: 6 }));
    const next = run({ ...fixture, sessionStart: now, session: '00000000-0000-4000-8000-000000000002', events: [] });
    const crash = next.logs.resourceLogs.find(r => r.scopeLogs[0].logRecords.some(l => l.attributes.some(a => a.key === 'event.name' && a.value.stringValue === 'native.exception')));
    expect(crash.resource.attributes.find(a => a.key === 'expo.app.update_id')?.value.stringValue).toBe('a'.repeat(64));

    // A crash during startup, before its service stored anything: the record names the update (ObserveCrash.swift).
    const early = '00000000-0000-4000-8000-000000000003';
    writeFileSync(join(store, `exact-observe-pending-${early}-${fixture.app.id}.json`),
      JSON.stringify({ session: early, app: fixture.app.id, sessionStart: now, metadata: {}, updateId: 'b'.repeat(64), signal: 11 }));
    const after = run({ ...fixture, sessionStart: now, session: '00000000-0000-4000-8000-000000000004', events: [] });
    const startupCrash = after.logs.resourceLogs.find(r => r.scopeLogs[0].logRecords.some(l => l.attributes.some(a => a.key === 'session.id' && a.value.stringValue === early)));
    expect(startupCrash.resource.attributes.find(a => a.key === 'expo.app.update_id')?.value.stringValue).toBe('b'.repeat(64));
  } finally { rmSync(work, { recursive: true, force: true }); }
}, 120_000);

test.skipIf(process.platform !== 'darwin')('the Apple service gives the launch route startup\'s TTI only when that screen stayed on top', () => {
  const work = mkdtempSync(join(tmpdir(), 'observe-launch-'));
  try {
    const exe = join(work, 'harness');
    const service = ['ObserveService', 'ObserveWire', 'ObserveRules', 'ObserveStore'].map(f => join(dir, `../apple/service/${f}.swift`));
    const build = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', join(work, 'cache'),
      ...service, join(dir, 'wire.swift'), '-lsqlite3', '-o', exe], { encoding: 'utf8' });
    expect(build.status, build.stderr).toBe(0);
    // Startup's report with TTI. The host says whether the launch screen stayed on top (`launchScreen`); a navigation's
    // own rows can come after startup's when both end at one vsync, and another window's navigation is not this one's.
    const { launchScreen: _, ...reached } = fixture.events.find(e => e.kind === 'startup' && e.metrics.timeToInteractive !== undefined);
    const names = (launchScreen, before = []) => {
      const path = join(work, `fixture-${Math.random()}.json`);
      const launch = fixture.events.find(e => e.kind === 'navigation.launch');
      writeFileSync(path, JSON.stringify({ ...fixture, events: [launch, ...before, { ...reached, kind: 'startup', ...(launchScreen ? { launchScreen } : {}) }] }));
      const run = spawnSync(exe, [path, join(work, `store-${Math.random()}`)], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      return JSON.parse(run.stdout).metrics.resourceMetrics.flatMap(r => r.scopeMetrics[0].metrics.map(m => m.name));
    };
    // Another window navigated before startup's TTI: the launch screen still stayed on top in its own.
    const navigation = fixture.events.find(e => e.kind === 'navigation');
    expect(names(true, [navigation])).toContain('expo.navigation.tti');
    const elsewhere = names(false);
    expect(elsewhere).toContain('expo.navigation.cold_ttr');
    expect(elsewhere).toContain('expo.app_startup.tti');
    expect(elsewhere).not.toContain('expo.navigation.tti');
  } finally { rmSync(work, { recursive: true, force: true }); }
}, 120_000);
