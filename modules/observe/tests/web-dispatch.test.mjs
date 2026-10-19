// The web service's sending: each signal's retry gate, the retry it schedules, and the
// queues of tabs that closed before sending. `bun test ./modules/observe/tests/web-dispatch.test.mjs`.
import { expect, test } from 'bun:test';

/** Runs `body` with the browser globals the service reads replaced by fakes, and returns what it sent. */
async function withPage({ storage = new Map(), locks = new Map(), status = () => 200 }, body) {
  const sent = [], timers = [];
  const names = ['localStorage', 'navigator', 'setTimeout', 'clearTimeout', 'fetch'];
  const saved = Object.fromEntries(names.map(n => [n, Object.getOwnPropertyDescriptor(globalThis, n)]));
  Object.assign(globalThis, {
    localStorage: {
      getItem: k => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, String(v)), removeItem: k => storage.delete(k),
      get length() { return storage.size; }, key: i => [...storage.keys()][i] ?? null,
    },
    navigator: {
      platform: 'MacIntel', language: 'en-US', onLine: true,
      // Web Locks: a held name refuses `ifAvailable`; the holder's promise keeps it held.
      locks: { request: async (name, opts, cb) => {
        if (typeof opts === 'function') { cb = opts; opts = {}; }
        if (locks.has(name)) return opts.ifAvailable ? cb(null) : new Promise(() => {});
        locks.set(name, true);
        try { return await cb({ name }); } finally { locks.delete(name); }
      } },
    },
    setTimeout: (f, ms) => { timers.push({ f, ms }); return timers.length; },
    clearTimeout: () => {},
    fetch: async (url, init) => { const signal = url.split('/').pop(); sent.push({ signal, body: JSON.parse(init.body) }); return new Response(null, { status: status(signal), headers: { 'Retry-After': '120' } }); },
  });
  try {
    const { start } = await import('../web/service.js');
    await body(start, sent, timers);
  } finally {
    for (const n of names) saved[n] ? Object.defineProperty(globalThis, n, saved[n]) : delete globalThis[n];
  }
  return { sent, timers };
}

const config = { 'app.CFBundleIdentifier': 'com.example.web', projectId: 'p', endpoint: 'http://sink' };
const settle = () => new Promise(r => queueMicrotask(r)).then(() => new Promise(r => setImmediate(r)));
const startup = { kind: 'startup', wall: 1700000001000, metrics: { timeToFirstRender: 0.1 }, walls: { timeToFirstRender: 1700000000500 }, marks: {} };
const error = { kind: 'app.error', wall: 1700000002000, type: 'Error', message: 'boom' };

test('a retryable metrics answer leaves logs sending and schedules its own retry', async () => {
  await withPage({ status: signal => (signal === 'metrics' ? 503 : 200) }, async (start, sent, timers) => {
    const service = start(config);
    service.event(startup);
    service.event(error);
    service.background();
    await settle();
    expect(sent.map(s => s.signal)).toEqual(['metrics', 'logs']);
    // Retry-After 120 s closes the metrics gate only, and a timer sends again when it opens.
    const retry = timers.find(t => t.ms > 100_000);
    expect(retry?.ms).toBeGreaterThan(119_000);
    expect(retry?.ms).toBeLessThanOrEqual(120_000);
    service.background();
    await settle();
    expect(sent.map(s => s.signal)).toEqual(['metrics', 'logs'], 'the gate holds metrics, and logs had nothing left');
  });
});

test('a tab sends the queue of a tab that closed, and leaves an open tab\'s alone', async () => {
  const storage = new Map(), locks = new Map();
  const row = session => JSON.stringify({ sessions: { [session]: { appIdentifier: 'com.example.web' } }, metrics: [{ session, time: 1700000000, category: 'appStartup', name: 'timeToFirstRender', value: 0.1 }], logs: [] });
  storage.set('exact-observe:com.example.web:closed-tab', row('closed-tab'));
  storage.set('exact-observe:com.example.web:open-tab', row('open-tab'));
  locks.set('exact-observe:com.example.web:open-tab', true);
  const { sent } = await withPage({ storage, locks }, async (start, sent, timers) => {
    start(config);
    await settle();
    // The 5 s dispatch timer the service armed at start: unlike the flush on hide, it also sends other tabs' queues.
    timers.find(t => t.ms === 5000).f();
    await settle();
    await settle();
  });
  const sessions = sent.flatMap(s => s.body.resourceMetrics?.flatMap(r => r.scopeMetrics.flatMap(m => m.metrics.flatMap(x => x.gauge.dataPoints.map(p => p.attributes.find(a => a.key === 'session.id').value.stringValue)))) ?? []);
  expect(sessions).toContain('closed-tab');
  expect(sessions).not.toContain('open-tab');
  expect(storage.has('exact-observe:com.example.web:closed-tab')).toBe(false);
  expect(storage.has('exact-observe:com.example.web:open-tab')).toBe(true);
});

const sessionsOf = sent => sent.flatMap(s => (s.body.resourceMetrics ?? s.body.resourceLogs ?? []).flatMap(r => r.resource.attributes.length ? (r.scopeMetrics ?? r.scopeLogs).flatMap(m => (m.metrics?.flatMap(x => x.gauge.dataPoints) ?? m.logRecords).map(p => p.attributes.find(a => a.key === 'session.id').value.stringValue)) : []));

test('closed tabs\' queues are all sent, however many', async () => {
  const storage = new Map(), row = session => JSON.stringify({ sessions: { [session]: { appIdentifier: 'com.example.web' } }, metrics: [{ session, time: 1700000000, category: 'appStartup', name: 'timeToFirstRender', value: 0.1 }], logs: [] });
  for (const s of ['closed-a', 'closed-b', 'closed-c']) storage.set(`exact-observe:com.example.web:${s}`, row(s));
  const { sent } = await withPage({ storage }, async (start, sent, timers) => {
    start(config);
    await settle();
    timers.find(t => t.ms === 5000).f();
    for (let i = 0; i < 4; i++) await settle();
  });
  expect(sessionsOf(sent).sort()).toEqual(['closed-a', 'closed-b', 'closed-c']);
  expect([...storage.keys()].filter(k => k.includes('closed'))).toEqual([]);
});

test('a page closed before its service loaded leaves its journal, which the next page sends under its session', async () => {
  const storage = new Map();
  storage.set('exact-journal:com.example.web:gone', JSON.stringify({ session: 'gone', config, events: [startup] }));
  storage.set('exact-journal:com.example.web:open', JSON.stringify({ session: 'open', config, events: [startup] }));
  const locks = new Map([['exact-journal:com.example.web:open', true]]);
  const { sent } = await withPage({ storage, locks }, async (start, sent, timers) => {
    start(config, { session: 'this' });
    for (let i = 0; i < 3; i++) await settle();
    timers.find(t => t.ms === 5000).f();
    for (let i = 0; i < 4; i++) await settle();
  });
  expect(sessionsOf(sent)).toContain('gone');
  expect(sessionsOf(sent)).not.toContain('open');
  expect(storage.has('exact-journal:com.example.web:gone')).toBe(false);
  expect(storage.has('exact-journal:com.example.web:open')).toBe(true, 'that page is still open');
});

test('a retry that comes due during the logs send runs after it', async () => {
  let release;
  const slow = new Promise(r => { release = r; });
  let metricsCalls = 0;
  const now = Date.now;
  let clock = now();
  Date.now = () => clock;
  try {
    await withPage({ status: signal => (signal === 'metrics' && ++metricsCalls === 1 ? 503 : 200) }, async (start, sent, timers) => {
      const service = start(config);
      const fetch = globalThis.fetch;
      // The logs request waits until the test releases it.
      globalThis.fetch = async (url, init) => { const answer = fetch(url, init); if (url.endsWith('/logs')) await slow; return answer; };
      service.event(startup);
      service.event(error);
      service.background();
      await settle();
      expect(sent.map(s => s.signal)).toEqual(['metrics', 'logs']);
      // The metrics gate (Retry-After 120 s) opens while logs still wait, and its retry fires then.
      clock += 121_000;
      timers.find(t => t.ms > 100_000).f();
      release();
      for (let i = 0; i < 6; i++) await settle();
      expect(sent.map(s => s.signal)).toEqual(['metrics', 'logs', 'metrics'], 'the retry ran after the logs send, with no new event');
    });
  } finally {
    Date.now = now;
  }
});

test('rows recorded during a send that trim the queue are not taken as sent', async () => {
  let release;
  const slow = new Promise(r => { release = r; });
  const { sent } = await withPage({}, async (start, sent, timers) => {
    const service = start(config);
    const fetch = globalThis.fetch;
    let first = true;
    globalThis.fetch = async (url, init) => { const answer = fetch(url, init); if (first) { first = false; await slow; } return answer; };
    // A full queue: 2,000 rows, the first 200 in flight.
    const row = value => ({ kind: 'navigation', name: 'cold_ttr', value, wall: 1700000001000, route: '/x', routeParams: {}, url: '/x' });
    for (let i = 0; i < 2000; i++) service.event(row(i));
    // The normal dispatch, 5 s after a row (a hide's keepalive flush stops at its byte budget).
    for (let i = 0; i < 3; i++) await settle();
    timers.find(t => t.ms === 5000).f();
    await settle();
    // One more row trims the head, which is in flight.
    service.event(row(2000));
    release();
    for (let i = 0; i < 30; i++) await settle();
  });
  const values = sent.filter(s => s.signal === 'metrics').flatMap(s => s.body.resourceMetrics.flatMap(r => r.scopeMetrics[0].metrics.map(m => m.gauge.dataPoints[0].asDouble)));
  // Row 0 went in the first request before the cap dropped it; every other row was sent too.
  expect(new Set(values).size).toBe(2001);
});

test('a startup report journaled each time it gains a metric stores each metric once', async () => {
  for (const launchScreen of [true, false]) {
    await withPage({}, async (start, sent) => {
      const service = start(config);
      service.event({ kind: 'navigation.launch', wall: 1700000000000, route: '/', routeParams: {}, url: '/' });
      service.event({ kind: 'startup', wall: 1700000000500, metrics: { timeToFirstRender: 0.5 }, walls: { timeToFirstRender: 1700000000500 }, marks: { present: 500 } });
      const tti = { kind: 'startup', wall: 1700000001000, metrics: { timeToFirstRender: 0.5, timeToInteractive: 1 }, walls: { timeToFirstRender: 1700000000500, timeToInteractive: 1700000001000 }, marks: { present: 500, interactive: 1000 }, tti: 'settled' };
      // The launch screen's TTI is startup's only when the host says that screen stayed on top.
      service.event(launchScreen ? { ...tti, launchScreen } : tti);
      service.event(launchScreen ? { ...tti, launchScreen } : tti);
      service.background();
      await settle();
      const names = sent.flatMap(s => s.body.resourceMetrics ?? []).flatMap(r => r.scopeMetrics[0].metrics).map(m => m.name).sort();
      expect(names).toEqual(['expo.app_startup.tti', 'expo.app_startup.ttr', 'expo.navigation.cold_ttr', ...(launchScreen ? ['expo.navigation.tti'] : [])]);
    });
  }
});

test('a prerendered page painted before its activation has a launch-route TTR of zero, not less', async () => {
  await withPage({}, async (start, sent) => {
    const service = start(config);
    service.event({ kind: 'navigation.launch', wall: 1700000000000, route: '/', routeParams: {}, url: '/' });
    service.event({ kind: 'startup', wall: 1700000005000, metrics: { timeToFirstRender: 0 }, walls: { timeToFirstRender: 1700000005000 }, marks: { activation: 5000, present: 100 } });
    service.background();
    await settle();
    const ttr = sent.flatMap(s => s.body.resourceMetrics ?? []).flatMap(r => r.scopeMetrics[0].metrics).find(m => m.name === 'expo.navigation.cold_ttr');
    expect(ttr.gauge.dataPoints[0].asDouble).toBe(0);
  });
});

test('storage that refuses access (blocked, or over its quota) leaves the service sending from memory', async () => {
  await withPage({}, async (start, sent) => {
    const refuse = () => { throw new DOMException('The operation is insecure.', 'SecurityError'); };
    globalThis.localStorage = { getItem: refuse, setItem: refuse, removeItem: refuse, key: refuse, get length() { return refuse(); } };
    const service = start(config);
    service.event(startup);
    service.background();
    await settle();
    expect(sent.map(s => s.signal)).toEqual(['metrics']);
  });
});

test('a page on plain HTTP, without `crypto.randomUUID` or Web Locks, gets UUIDs from `getRandomValues` and sends its own rows', async () => {
  const storage = new Map();
  const own = Object.getOwnPropertyDescriptor(crypto, 'randomUUID');
  crypto.randomUUID = undefined;
  try {
    await withPage({ storage }, async (start, sent) => {
      navigator.locks = undefined;
      const service = start(config);
      service.event(startup);
      service.background();
      await settle();
      expect(sent.map(s => s.signal)).toEqual(['metrics']);
    });
  } finally { own ? Object.defineProperty(crypto, 'randomUUID', own) : delete crypto.randomUUID; }
  expect(storage.get('expo.eas-client-id')).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});
