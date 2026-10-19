// Observe's web service, loaded by the host's marks.js after startup. It queues journal
// events as Observe rows in localStorage until the server accepts them, and sends them
// in expo-observe's OTLP/JSON with its retry rules. Each tab's session has a queue of its
// own, held by a Web Lock of the same name while the tab is open; a tab also sends the
// queues whose lock is free, those of tabs that closed before sending.
// On page hide it flushes with fetch(keepalive). Browsers cap all in-flight keepalive
// bodies at 64 KiB together, so one flush sends at most 60 KiB and leaves the rest queued.

const SCHEMA_URL = 'https://opentelemetry.io/schemas/1.27.0';
const NAMES = {
  'appStartup/timeToInteractive': 'expo.app_startup.tti', 'appStartup/timeToFirstRender': 'expo.app_startup.ttr',
  'appStartup/coldLaunchTime': 'expo.app_startup.cold_launch_time', 'appStartup/warmLaunchTime': 'expo.app_startup.warm_launch_time',
  'updates/updateDownloadTime': 'expo.updates.download_time',
  'navigation/cold_ttr': 'expo.navigation.cold_ttr', 'navigation/warm_ttr': 'expo.navigation.warm_ttr', 'navigation/tti': 'expo.navigation.tti',
};
const SEVERITY = { trace: 1, debug: 5, info: 9, warn: 13, error: 17, fatal: 21 };
const KEEPALIVE_BUDGET = 60 * 1024, CHUNK = 200, MAX_ROWS = 2000;

// `randomUUID` exists only in secure contexts; on plain HTTP (a LAN development server) the UUID is made from `getRandomValues`
const uuid = () => crypto.randomUUID?.() ?? '10000000-1000-4000-8000-100000000000'.replace(/[018]/g, c => (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16));
const stringAttr = (key, v) => ({ key, value: { stringValue: v } });

/** Expo main's `EASClientID.deterministicUniformValue` (ObserveWire.swift `uniform`): a stable value in [0, 1) per install. */
export function uniform(id) {
  const hex = id.replace(/-/g, '');
  let z = BigInt('0x' + hex.slice(0, 16)) ^ BigInt('0x' + hex.slice(16, 32));
  const m = (1n << 64n) - 1n;
  z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & m;
  z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & m;
  z = z ^ (z >> 31n);
  return Number(z >> 11n) / 2 ** 53;
}

function anyValue(v) {
  if (typeof v === 'boolean') return { boolValue: v };
  if (typeof v === 'number') return Number.isFinite(v) ? (Number.isInteger(v) ? { intValue: v } : { doubleValue: v }) : null;
  if (typeof v === 'string') return { stringValue: v };
  if (Array.isArray(v)) { const a = v.map(anyValue); return a.every(Boolean) ? { arrayValue: { values: a } } : null; }
  if (v && typeof v === 'object') {
    const values = [];
    for (const k of Object.keys(v).sort()) { const m = anyValue(v[k]); if (!m) return null; values.push({ key: k, value: m }); }
    return { kvlistValue: { values } };
  }
  return null;
}

/** Observe's custom-event validation, copied from expo-app-metrics (`LogEvents`). */
function rulesName(raw) { const n = String(raw ?? '').trim(); return n && !n.startsWith('expo.') && n.length <= 256 ? n : null; }
const truncate = (s, max) => (s.length <= max ? s : s.slice(0, max - 1) + '…');
function rulesAttributes(raw) {
  const kept = {}; let dropped = 0;
  for (const key of Object.keys(raw ?? {}).sort()) {
    const k = key.trim();
    if (!k || (k.startsWith('expo.') && k.length > 5) || k === 'session.id' || k === 'event.name' || Object.keys(kept).length >= 128) { dropped++; continue; }
    kept[k] = raw[key];
  }
  return { kept, dropped };
}

/** This page's session's metadata, from its service configuration. */
const metadata = config => ({
  osName: navigator.userAgentData?.platform ?? navigator.platform, language: navigator.language, clientVersion: '0.1.0',
  appIdentifier: config['app.CFBundleIdentifier'], appName: config['app.CFBundleName'],
  appVersion: config['app.CFBundleShortVersionString'], appBuildNumber: config['app.CFBundleVersion'],
  environment: config.environment ?? (config['fact.development'] ? 'development' : 'production'),
});

function device() {
  const c = navigator.connection;
  const d = { 'expo.network.connected': navigator.onLine, 'expo.network.type': !navigator.onLine ? 'none' : c?.type && c.type !== 'unknown' ? c.type : 'unknown' };
  if (c?.effectiveType) d['exact.network.effectiveType'] = c.effectiveType;
  return d;
}

/** Records the journal events of `session` as Observe rows in queue `q`, calling `saved` after each row. A journal
 * `recovered` from a closed page gets no device or network state: this page's is not that page's. */
function recorder(session, q, saved, recovered = false) {
  let globals = {}, launchRoute = null, navigated = false;
  /** The startup metrics sent, by name (`launch.` for the launch route's). */
  const sent = new Set();
  const params = extra => ({ ...globals, ...extra });
  const metric = (category, name, value, wall, route, p) => { q.metrics.push({ session, time: wall / 1000, category, name, value, route, params: JSON.stringify(p) }); saved(); };
  const log = (severity, name, body, attributes, dropped, wall) => { q.logs.push({ session, time: wall / 1000, severity, name, body, attributes, dropped }); saved(); };

  /** The startup metrics, each at the time of its own mark, and each once: a report after the
   * timeout's (`startup.tti`) sends only what that one lacked, such as a first frame that came after it. */
  function startup(e) {
    const m = e.marks ?? {}, from = m.activation ?? 0, walls = e.walls ?? {};
    const common = { 'exact.present.method': e.presentMethod ?? 'raf', 'exact.since_process_start.ttr': m.present !== undefined ? (m.present - from) / 1000 : undefined };
    if (e.interrupted) common['exact.launch.interrupted'] = true;
    for (const [name, value] of Object.entries(e.metrics ?? {})) {
      if (sent.has(name)) continue;
      sent.add(name);
      const p = params(common);
      let route;
      if (name === 'timeToInteractive') {
        p['exact.tti.reason'] = e.tti;
        if (e.trace?.length) p['exact.tti.trace'] = e.trace.join(' → ');
        if (!recovered) Object.assign(p, device());
        // The screen shown at TTI, with Observe's navigation params.
        if (e.route) { route = e.route.route; p.routeParams = e.route.routeParams ?? {}; p.url = e.route.url; }
        if (e.late) p['exact.tti.late'] = true;
      }
      metric('appStartup', name, value, walls[name] ?? e.wall, route, p);
    }
    if (!launchRoute) return;
    // The launch route is anchored at activation; a mark before it (a prerendered page's paint) counts as at it.
    const since = t => (Math.max(t, from) - from) / 1000;
    const p = params({ isAppLaunch: true, routeParams: launchRoute.routeParams ?? {}, url: launchRoute.url, 'exact.nav.anchor': 'activation' });
    const once = name => !sent.has(name) && sent.add(name);
    if (e.metrics?.timeToFirstRender !== undefined && once('launch.cold_ttr')) metric('navigation', 'cold_ttr', since(m.present), walls.timeToFirstRender ?? e.wall, launchRoute.route, p);
    if (e.metrics?.timeToInteractive !== undefined && !navigated && once('launch.tti')) metric('navigation', 'tti', since(m.interactive), walls.timeToInteractive ?? e.wall, launchRoute.route, p);
  }

  return e => {
    switch (e.kind) {
      case 'startup': startup(e); break;
      case 'startup.tti': startup(e); break;
      case 'navigation.launch': launchRoute = e; break;
      case 'navigation': navigated = true; metric('navigation', e.name, e.value, e.wall, e.route, params({ isAppLaunch: false, routeParams: e.routeParams ?? {}, url: e.url, ...Object.fromEntries(Object.entries(e).filter(([k]) => k.startsWith('exact.'))) })); break;
      case 'app.attributes': globals = rulesAttributes(e.attributes).kept; break;
      case 'app.event': {
        const name = rulesName(e.name); if (!name) break;
        const a = rulesAttributes(e.attributes);
        const attrs = { ...globals, ...a.kept };
        if (e.displayName?.trim()) attrs['expo.log.display_name'] = truncate(e.displayName.trim(), 128);
        log(SEVERITY[e.severity] ? e.severity : 'info', name, e.body == null ? undefined : truncate(String(e.body), 4096), attrs, a.dropped, e.wall);
        break;
      }
      case 'app.error': log('error', 'js.exception', undefined, { ...globals, 'expo.error.source': e.source ?? 'reportedByUser', 'expo.error.is_fatal': false, 'exception.type': e.type ?? 'Error', 'exception.message': e.message ?? '', ...(e.stack ? { 'exception.stacktrace': e.stack } : {}) }, 0, e.wall); break;
    }
  };
}

/** The keys in localStorage that start with `prefix`, read once: draining one removes it. */
function keys(prefix) {
  const out = [];
  try { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k?.startsWith(prefix)) out.push(k); } } catch {}
  return out;
}

const bytes = s => new TextEncoder().encode(s).length;

/** Starts this page's service. `session` is the page's (marks.js), whose journal it may find
 * left by an earlier hide; the journals of pages that closed before their service loaded
 * (`exact-journal:<app>:<session>`, under a Web Lock of that name while the page was open)
 * become queues of their own sessions, which the drain sends. */
export function start(config, { boot = 0, session = uuid() } = {}) {
  const app = config['app.CFBundleIdentifier'] ?? location.host;
  const prefix = `exact-observe:${app}:`, journals = `exact-journal:${app}:`;
  // Kept for this page only when storage refuses it (blocked, or over its quota): the queues already work without storage
  let clientId;
  try { clientId = localStorage.getItem('expo.eas-client-id') ?? uuid(); localStorage.setItem('expo.eas-client-id', clientId); } catch { clientId ??= uuid(); }
  const key = prefix + session;
  const load = k => { try { return JSON.parse(localStorage.getItem(k)); } catch {} };
  const save = (k, q) => {
    q.metrics = q.metrics.slice(-MAX_ROWS); q.logs = q.logs.slice(-MAX_ROWS);
    try { if (q.metrics.length || q.logs.length || k === key) localStorage.setItem(k, JSON.stringify(q)); else localStorage.removeItem(k); } catch {}
  };
  const queue = { sessions: { [session]: metadata(config) }, metrics: [], logs: [] };
  save(key, queue);
  // This page's own journal, if an earlier hide left one, is in memory now.
  try { localStorage.removeItem(journals + session); } catch {}
  // Held until the tab closes: a queue whose lock is free has no tab to send it.
  navigator.locks?.request(key, () => new Promise(() => {})).catch(() => {});
  // Each signal's retry gate, as expo-observe keeps one per endpoint.
  const gates = { metrics: { after: 0, failures: 0 }, logs: { after: 0, failures: 0 } };
  // `again`: a dispatch asked for during a send, with its mode (`keepalive` wins).
  let sending = false, again = null, timer = null, retryAt = 0, retryTimer = null;
  const record = recorder(session, queue, () => { save(key, queue); schedule(); });

  const resource = meta => {
    const a = [['os.type', 'browser'], ['os.name', meta.osName], ['browser.language', meta.language], ['telemetry.sdk.name', 'exact-observe'],
      ['telemetry.sdk.version', meta.clientVersion], ['telemetry.sdk.language', 'javascript'], ['expo.eas_client.id', clientId],
      ['service.name', meta.appIdentifier], ['service.version', meta.appVersion], ['expo.app.name', meta.appName],
      ['expo.app.build_number', meta.appBuildNumber], ['expo.environment', meta.environment]];
    return { attributes: a.filter(([, v]) => v != null).map(([k, v]) => stringAttr(k, String(v))) };
  };
  /** `{outer: [{resource, inner: [{scope, list: items}], schemaUrl}]}`, one resource per session. */
  const envelope = (by, sessions, outer, inner, list) => ({ [outer]: Object.keys(by).filter(s => sessions[s]).map(s => ({
    resource: resource(sessions[s]), [inner]: [{ scope: { name: 'expo-observe', version: sessions[s].clientVersion ?? '0' }, [list]: by[s] }], schemaUrl: SCHEMA_URL })) });
  // A JSON number, as expo-observe sends it.
  const nanos = s => Math.round(s * 1000) * 1e6;
  function metricsBody(rows, sessions) {
    const by = {};
    for (const r of rows) {
      const attrs = [stringAttr('session.id', r.session)];
      if (r.route) attrs.push(stringAttr('expo.route_name', r.route));
      if (r.params && r.params !== '{}') attrs.push(stringAttr('expo.custom_params', r.params));
      (by[r.session] ??= []).push({ unit: 's', name: NAMES[`${r.category}/${r.name}`] ?? `expo.unknown.${r.name}`, gauge: { dataPoints: [{ timeUnixNano: nanos(r.time), asDouble: r.value, attributes: attrs }] } });
    }
    return envelope(by, sessions, 'resourceMetrics', 'scopeMetrics', 'metrics');
  }
  function logsBody(rows, sessions) {
    const by = {};
    for (const r of rows) {
      const attrs = [stringAttr('session.id', r.session), stringAttr('event.name', r.name)];
      let dropped = r.dropped ?? 0;
      for (const k of Object.keys(r.attributes ?? {}).sort()) { const v = anyValue(r.attributes[k]); if (v) attrs.push({ key: k, value: v }); else dropped++; }
      const rec = { timeUnixNano: nanos(r.time), observedTimeUnixNano: nanos(r.time), severityNumber: SEVERITY[r.severity] ?? 9, severityText: r.severity.toUpperCase(), body: { stringValue: r.body ?? '' }, attributes: attrs };
      if (dropped) rec.droppedAttributesCount = dropped;
      (by[r.session] ??= []).push(rec);
    }
    return envelope(by, sessions, 'resourceLogs', 'scopeLogs', 'logRecords');
  }

  const inSample = () => uniform(clientId) < Math.min(Math.max(config.sampleRate ?? 1, 0), 1);
  const shouldDispatch = () => (config.dispatchingEnabled ?? true) && inSample() && (!config['fact.development'] || config.dispatchInDebug === true);
  const backoff = n => Math.min(60 * 2 ** (n - 1), 900) * Math.random();
  const retryAfter = h => { if (!h) return null; const s = Number(h); const clamp = x => Math.min(Math.max(x, 60), 900); if (Number.isFinite(s)) return clamp(s); const d = Date.parse(h); return Number.isNaN(d) ? null : clamp((d - Date.now()) / 1000); };

  /** Dispatches again at `at` (ms), so rows a closed gate kept wait for no new event. */
  function retry(at) {
    if (retryTimer && retryAt <= at) return;
    clearTimeout(retryTimer);
    retryAt = at;
    retryTimer = setTimeout(() => { retryTimer = null; dispatch(); }, Math.max(0, at - Date.now()));
  }

  /** Sends one signal's rows of queue `q` (stored at `k`) chunk by chunk, as expo-observe's
   * `DispatchLoop.swift` does. With `keepalive`, it also stops at the byte budget. */
  async function send(k, q, signal, url, keepalive) {
    const gate = gates[signal];
    if (Date.now() < gate.after) return retry(gate.after);
    let limit = CHUNK, budget = KEEPALIVE_BUDGET;
    while (q[signal].length) {
      const rows = q[signal].slice(0, limit);
      const body = JSON.stringify(signal === 'metrics' ? metricsBody(rows, q.sessions) : logsBody(rows, q.sessions));
      const size = bytes(body);
      if (keepalive && size > budget) {
        if (rows.length > 1) { limit = rows.length >> 1; continue; }
        return; // One row is over the keepalive budget. A normal fetch sends it next time.
      }
      let status = null, wait = null;
      try {
        const r = await fetch(url, { method: 'POST', body, keepalive, headers: { 'Content-Type': 'application/json', 'Expo-AppMetrics-Skip': '1' } });
        status = r.status; wait = r.headers.get('Retry-After');
      } catch {}
      if (keepalive) budget -= size;
      if (globalThis.EXACT_OBSERVE_LOG) console.log(`observe: ${signal} ${rows.length} rows → ${status ?? 'transport error'}`);
      // The rows sent leave by identity: a row recorded during the request can have trimmed the queue's head (`save`).
      const done = sent => { const gone = new Set(sent); q[signal] = q[signal].filter(r => !gone.has(r)); save(k, q); limit = CHUNK; };
      if (status !== null && ![413, 429, 502, 503, 504].includes(status)) { gate.failures = 0; done(rows); continue; }
      if (status === 413) { gate.failures = 0; if (rows.length > 1) { limit = rows.length >> 1; continue; } done(rows); continue; }
      gate.failures++; gate.after = Date.now() + 1000 * (retryAfter(wait) ?? backoff(gate.failures));
      return retry(gate.after);
    }
  }
  /** Sends queue `k`: this tab's, or (`own` false) one whose tab closed, under its lock. */
  async function drain(k, own, keepalive) {
    const q = own ? queue : load(k);
    if (!q?.metrics || !q.logs) return;
    if (!shouldDispatch() || !config.projectId) { q.metrics.length = 0; q.logs.length = 0; return save(k, q); }
    const base = String(config.endpoint ?? 'https://o.expo.dev').replace(/\/+$/, '');
    await send(k, q, 'metrics', `${base}/${config.projectId}/v1/metrics`, keepalive);
    await send(k, q, 'logs', `${base}/${config.projectId}/v1/logs`, keepalive);
  }
  async function dispatch(keepalive = false) {
    // A dispatch asked for during a send (a retry that came due, a hide) runs after it.
    if (sending) { again = { keepalive: keepalive || again?.keepalive === true }; return; }
    sending = true;
    try {
      await drain(key, true, keepalive);
      // A flush on hide has no time for other tabs' queues.
      if (!keepalive && navigator.locks) for (const k of keys(prefix)) if (k !== key) await navigator.locks.request(k, { ifAvailable: true }, lock => lock && drain(k, false, false));
    } finally { sending = false; }
    if (again) { const next = again; again = null; dispatch(next.keepalive); }
  }
  function schedule() { if (!timer) timer = setTimeout(() => { timer = null; dispatch(); }, 5000); }

  /** Turns the journals that pages closed before their service loaded into queues for the drain. */
  async function recover() {
    if (!navigator.locks) return;
    for (const k of keys(journals)) {
      // Its lock is held while that page is open: it sends its own.
      await navigator.locks.request(k, { ifAvailable: true }, lock => {
        if (!lock) return;
        const j = load(k);
        try { localStorage.removeItem(k); } catch {}
        if (typeof j?.session !== 'string' || !Array.isArray(j.events)) return;
        const q = { sessions: { [j.session]: metadata(j.config ?? config) }, metrics: [], logs: [] };
        const rec = recorder(j.session, q, () => {}, true);
        for (const e of j.events) rec(e);
        save(prefix + j.session, q);
      }).catch(() => {});
    }
  }
  recover().finally(schedule);

  return {
    event(e) {
      record(e);
      // A background the service missed while it loaded: flush now if the page is still hidden.
      if (e.kind === 'background' && globalThis.document?.visibilityState === 'hidden') dispatch(true);
    },
    background() { dispatch(true); },
  };
}
