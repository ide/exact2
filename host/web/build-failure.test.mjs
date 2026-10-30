// What a failed web build says (host/web/build.mjs): the compiler's own
// refusal, with its place, rather than whatever lines its output ended on.
import { expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

const ROOT = resolve(import.meta.dir, '../..');

test("the web build says the JS target's refusal of the app's Contract, with its place", () => {
  const dir = mkdtempSync(resolve(tmpdir(), 'exact web refusal-'));
  try {
    writeFileSync(resolve(dir, 'app.json'), JSON.stringify({ name: 'Refusal', app: { id: 'test.exact.refusal', name: 'Refusal' }, rust: false }));
    // A computed exit animation, which the JS target takes as no one declaration, in a component: the refusal
    // is followed by a note of where the component is instantiated and by its excerpt
    writeFileSync(resolve(dir, 'app.contract'), [
      'component App', '  state leaving = "none"', '  view', '    Greeting(leaving=leaving)',
      'component Greeting', '  props', '    leaving: string', '  view', '    text "Hello" -exact-exit-animation=leaving', '',
    ].join('\n'));
    writeFileSync(resolve(dir, 'app.ts'), "export const appId = 'test.exact.refusal';\nexport const grants = '';\n");
    const built = spawnSync(process.execPath, [resolve(ROOT, 'host/web/build.mjs'), 'refusal', '--render', 'none'], {
      cwd: ROOT, encoding: 'utf8', env: { ...process.env, EXACT_APP_DIR: dir, EXACT_WEB_DIST: resolve(dir, 'dist') },
    });
    expect(built.status, built.stderr).toBe(1);
    expect(built.stderr).toMatch(/app\.contract:9:5 \[web-target\] a dynamic `exit_animation`/);
    expect(built.stderr).toContain('the web build (the JS target) failed');
  } finally { rmSync(dir, { recursive: true, force: true }); }
}, 60_000);
