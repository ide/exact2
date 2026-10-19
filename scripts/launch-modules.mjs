// The modules an app's app.json names under `launch` (modules/observe is one).
import { existsSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');

/** The modules app.json `launch` names, in order, each from the app's
 * `modules/<name>/` else exact2's: `apple/launch/*.swift` links into the
 * executable, `apple/service/*.swift` builds its service dylib, and `web` is
 * its `web/service.js` or null. */
export function launchModules(dir, manifest) {
  return (manifest.launch ?? []).map((name) => {
    const own = resolve(dir, 'modules', name), shared = resolve(ROOT, 'modules', name);
    const base = existsSync(own) ? own : shared;
    if (!existsSync(base)) throw new Error(`app.json launch: no module ${name} (neither ${own} nor ${shared})`);
    const swift = (sub) => { const d = resolve(base, sub); return existsSync(d) ? readdirSync(d).filter(f => f.endsWith('.swift')).sort().map(f => resolve(d, f)) : []; };
    const web = resolve(base, 'web/service.js');
    return { name, launch: swift('apple/launch'), service: swift('apple/service'), web: existsSync(web) ? web : null };
  });
}
