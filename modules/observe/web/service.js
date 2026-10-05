// Observe's web service, loaded by the host's marks.js after startup. It queues journal
// events as Observe rows in localStorage until the server accepts them, and sends them
// in expo-observe's OTLP/JSON with its retry rules.
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

const uuid = () => crypto.randomUUID();
const stringAttr = (key, v) => ({ key, value: { stringValue: v } });

/** Same as expo's `EASClientID.deterministicUniformValue`: a stable value in [0, 1) per install. */
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
    for (const [k, x] of Object.entries(v)) { const m = anyValue(x); if (!m) return null; values.push({ key: k, value: m }); }
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

export function start(config, { boot = 0 } = {}) {
  const key = `exact-observe:${config['app.CFBundleIdentifier'] ?? location.host}`;
  const clientId = localStorage.getItem('expo.eas-client-id') ?? uuid();
  localStorage.setItem('expo.eas-client-id', clientId);
  const session = uuid();
  const save = q => { q.metrics = q.metrics.slice(-MAX_ROWS); q.logs = q.logs.slice(-MAX_ROWS); try { localStorage.setItem(key, JSON.stringify(q)); } catch {} };
  const q = (() => { try { return JSON.parse(localStorage.getItem(key)); } catch {} })() ?? { sessions: {}, metrics: [], logs: [] };
  q.sessions[session] = {
    osName: navigator.userAgentData?.platform ?? navigator.platform, language: navigator.language, clientVersion: '0.1.0',
    appIdentifier: config['app.CFBundleIdentifier'], appName: config['app.CFBundleName'],
    environment: config.environment ?? (config['fact.development'] ? 'development' : 'production'),
  };
  save(q);
  let globals = {}, gate = { after: 0, failures: 0 }, sending = false, timer = null, launchRoute = null, navigated = false;
  const params = extra => ({ ...globals, ...extra });
  const metric = (category, name, value, wall, route, p) => { q.metrics.push({ session, time: wall / 1000, category, name, value, route, params: JSON.stringify(p) }); save(q); schedule(); };
  const log = (severity, name, body, attributes, dropped, wall) => { q.logs.push({ session, time: wall / 1000, severity, name, body, attributes, dropped }); save(q); schedule(); };

  function startup(e) {
    const m = e.marks ?? {}, from = m.activation ?? 0;
    const common = { 'exact.present.method': e.presentMethod ?? 'raf', 'exact.since_process_start.ttr': m.present !== undefined ? (m.present - from) / 1000 : undefined };
    for (const [name, value] of Object.entries(e.metrics ?? {})) {
      const p = params(common);
      if (name === 'timeToInteractive') { p['exact.tti.reason'] = e.tti; Object.assign(p, device()); }
      metric('appStartup', name, value, e.wall, undefined, p);
    }
    if (launchRoute && m.present !== undefined) {
      const p = params({ isAppLaunch: true, routeParams: launchRoute.routeParams ?? {}, url: launchRoute.url, 'exact.nav.anchor': 'activation' });
      metric('navigation', 'cold_ttr', (m.present - from) / 1000, e.wall, launchRoute.route, p);
      if (m.interactive !== undefined && !navigated && ['settled', 'declared'].includes(e.tti)) metric('navigation', 'tti', (m.interactive - from) / 1000, e.wall, launchRoute.route, p);
    }
  }
  function device() {
    const c = navigator.connection;
    const d = { 'expo.network.connected': navigator.onLine, 'expo.network.type': !navigator.onLine ? 'none' : c?.type && c.type !== 'unknown' ? c.type : 'unknown' };
    if (c?.effectiveType) d['exact.network.effectiveType'] = c.effectiveType;
    return d;
  }

  const resource = meta => {
    const a = [['os.type', 'browser'], ['os.name', meta.osName], ['browser.language', meta.language], ['telemetry.sdk.name', 'exact-observe'],
      ['telemetry.sdk.version', meta.clientVersion], ['telemetry.sdk.language', 'javascript'], ['expo.eas_client.id', clientId],
      ['service.name', meta.appIdentifier], ['expo.app.name', meta.appName], ['expo.environment', meta.environment]];
    return { attributes: a.filter(([, v]) => v != null).map(([k, v]) => stringAttr(k, String(v))) };
  };
  /** `{outer: [{resource, inner: [{scope, list: items}], schemaUrl}]}`, one resource per session. */
  const envelope = (by, outer, inner, list) => ({ [outer]: Object.keys(by).filter(s => q.sessions[s]).map(s => ({
    resource: resource(q.sessions[s]), [inner]: [{ scope: { name: 'expo-observe', version: q.sessions[s].clientVersion ?? '0' }, [list]: by[s] }], schemaUrl: SCHEMA_URL })) });
  const nanos = s => String(Math.round(s * 1000)) + '000000';
  function metricsBody(rows) {
    const by = {};
    for (const r of rows) {
      const attrs = [stringAttr('session.id', r.session)];
      if (r.route) attrs.push(stringAttr('expo.route_name', r.route));
      if (r.params && r.params !== '{}') attrs.push(stringAttr('expo.custom_params', r.params));
      (by[r.session] ??= []).push({ unit: 's', name: NAMES[`${r.category}/${r.name}`] ?? `expo.unknown.${r.name}`, gauge: { dataPoints: [{ timeUnixNano: nanos(r.time), asDouble: r.value, attributes: attrs }] } });
    }
    return envelope(by, 'resourceMetrics', 'scopeMetrics', 'metrics');
  }
  function logsBody(rows) {
    const by = {};
    for (const r of rows) {
      const attrs = [stringAttr('session.id', r.session), stringAttr('event.name', r.name)];
      let dropped = r.dropped ?? 0;
      for (const k of Object.keys(r.attributes ?? {}).sort()) { const v = anyValue(r.attributes[k]); if (v) attrs.push({ key: k, value: v }); else dropped++; }
      const rec = { timeUnixNano: nanos(r.time), observedTimeUnixNano: nanos(r.time), severityNumber: SEVERITY[r.severity] ?? 9, severityText: r.severity.toUpperCase(), body: { stringValue: r.body ?? '' }, attributes: attrs };
      if (dropped) rec.droppedAttributesCount = dropped;
      (by[r.session] ??= []).push(rec);
    }
    return envelope(by, 'resourceLogs', 'scopeLogs', 'logRecords');
  }

  const inSample = () => uniform(clientId) < Math.min(Math.max(config.sampleRate ?? 1, 0), 1);
  const shouldDispatch = () => (config.dispatchingEnabled ?? true) && inSample() && (!config['fact.development'] || config.dispatchInDebug === true);
  const backoff = n => Math.min(60 * 2 ** (n - 1), 900) * Math.random();
  const retryAfter = h => { if (!h) return null; const s = Number(h); const clamp = x => Math.min(Math.max(x, 60), 900); if (Number.isFinite(s)) return clamp(s); const d = Date.parse(h); return Number.isNaN(d) ? null : clamp((d - Date.now()) / 1000); };

  /** Sends one signal's rows chunk by chunk, as expo-observe's `DispatchLoop.swift` does.
   * With `keepalive`, it also stops at the byte budget. */
  async function send(signal, url, keepalive) {
    let limit = CHUNK, budget = KEEPALIVE_BUDGET;
    while (q[signal].length) {
      const rows = q[signal].slice(0, limit);
      const body = JSON.stringify(signal === 'metrics' ? metricsBody(rows) : logsBody(rows));
      if (keepalive && body.length > budget) {
        if (rows.length > 1) { limit = rows.length >> 1; continue; }
        return; // One row is over the keepalive budget. A normal fetch sends it next time.
      }
      let status = null, retry = null;
      try {
        const r = await fetch(url, { method: 'POST', body, keepalive, headers: { 'Content-Type': 'application/json', 'Expo-AppMetrics-Skip': '1' } });
        status = r.status; retry = r.headers.get('Retry-After');
      } catch {}
      if (keepalive) budget -= body.length;
      if (globalThis.EXACT_OBSERVE_LOG) console.log(`observe: ${signal} ${rows.length} rows → ${status ?? 'transport error'}`);
      if (status !== null && ![413, 429, 502, 503, 504].includes(status)) { gate.failures = 0; q[signal].splice(0, rows.length); save(q); limit = CHUNK; continue; }
      if (status === 413) { gate.failures = 0; if (rows.length > 1) { limit = rows.length >> 1; continue; } q[signal].splice(0, 1); save(q); limit = CHUNK; continue; }
      gate.failures++; gate.after = Date.now() + 1000 * (retryAfter(retry) ?? backoff(gate.failures));
      return;
    }
  }
  async function dispatch(keepalive = false) {
    if (sending || Date.now() < gate.after) return;
    if (!shouldDispatch() || !config.projectId) { q.metrics.length = 0; q.logs.length = 0; save(q); return; }
    sending = true;
    const base = String(config.endpoint ?? 'https://o.expo.dev').replace(/\/+$/, '');
    try {
      await send('metrics', `${base}/${config.projectId}/v1/metrics`, keepalive);
      await send('logs', `${base}/${config.projectId}/v1/logs`, keepalive);
    } finally { sending = false; }
  }
  function schedule() { if (!timer) timer = setTimeout(() => { timer = null; dispatch(); }, 5000); }
  schedule();

  return {
    event(e) {
      switch (e.kind) {
        case 'startup': startup(e); break;
        case 'navigation.launch': launchRoute = e; break;
        case 'navigation': navigated = true; metric('navigation', e.name, e.value, e.wall, e.route, params({ isAppLaunch: false, routeParams: e.routeParams ?? {}, url: e.url, 'exact.nav.cause': e['exact.nav.cause'] })); break;
        case 'app.attributes': globals = rulesAttributes(e.attributes).kept; break;
        case 'app.event': {
          const name = rulesName(e.name); if (!name) break;
          const a = rulesAttributes(e.attributes);
          const attrs = { ...globals, ...a.kept };
          if (e.displayName?.trim()) attrs['expo.log.display_name'] = truncate(e.displayName.trim(), 128);
          log(SEVERITY[e.severity] ? e.severity : 'info', name, e.body == null ? undefined : truncate(String(e.body), 4096), attrs, a.dropped, e.wall);
          break;
        }
        case 'app.error': log('error', 'js.exception', undefined, { 'expo.error.source': e.source ?? 'reportedByUser', 'expo.error.is_fatal': false, 'exception.type': e.type ?? 'Error', 'exception.message': e.message ?? '', ...(e.stack ? { 'exception.stacktrace': e.stack } : {}) }, 0, e.wall); break;
      }
    },
    background() { dispatch(true); },
  };
}
