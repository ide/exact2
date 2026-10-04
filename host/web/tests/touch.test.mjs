// Touch presses in a real browser (touch.js, installed by chrome.js), driven
// by CDP touch events with the shell's own sheet: UIKit's rule, not the
// browser's. A touch activates only when it lifts on the control; one that
// leaves it, or turns into a scroll, or lands while a scroller moves, does
// not; in a scroller the press shows only after a delay, or as a quick tap
// lifts; fixed chrome is in no scroller; the keyboard still activates.
import { test, expect } from 'bun:test';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { Cdp } from '../../../scripts/agent.mjs';

const WEB = resolve(new URL('..', import.meta.url).pathname);
const chrome = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const check = existsSync(chrome) ? test : test.skip;

const page = '<meta name="viewport" content="width=device-width, initial-scale=1">' + readFileSync(resolve(WEB, 'index.html'), 'utf8').match(/<style>[\s\S]*?<\/style>/)[0] + `
<div id="exact-root" style="padding:20px;box-sizing:border-box">
  <button id="out" style="width:120px;height:44px">out</button>
  <input id="sw" type="checkbox" switch style="margin:20px 0">
  <div id="sc" data-scroll="true" style="height:300px;width:300px">
    <div style="height:40px"></div>
    <button id="in" style="width:200px;height:60px">in</button>
    <div style="height:1200px"></div>
  </div>
  <div style="position:fixed;left:0;right:0;bottom:0;height:60px;touch-action:none"><button id="bar" style="width:120px;height:44px">bar</button></div>
</div>
<script type="module">
  import { installTouch } from './touch.js';
  installTouch();
  window.log = [];
  window.held = [];
  for (const id of ['out', 'in', 'bar']) document.getElementById(id).addEventListener('click', () => log.push(id));
  document.getElementById('sw').addEventListener('change', e => log.push('sw:' + e.target.checked));
  new MutationObserver(ms => { for (const m of ms) held.push(m.target.id + (m.target.hasAttribute('data-held') ? '+' : '-')); })
    .observe(document.getElementById('exact-root'), { subtree: true, attributeFilter: ['data-held'] });
  window.ready = true;
</script>`;

check('a touch activates only where UIKit would, its press late in a scroller', async () => {
  const server = createServer((req, res) => {
    if (req.url === '/') { res.writeHead(200, { 'content-type': 'text/html' }); res.end(page); return; }
    res.writeHead(200, { 'content-type': 'text/javascript' }); res.end(readFileSync(resolve(WEB, 'touch.js')));
  });
  await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
  const profile = mkdtempSync(resolve(tmpdir(), 'exact-touch-'));
  const child = spawn(chrome, ['--headless=new', '--remote-debugging-pipe', '--window-size=400,800', `--user-data-dir=${profile}`,
    '--no-sandbox', '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
  try {
    const cdp = new Cdp(child.stdio[3], child.stdio[4]);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    const call = (method, params) => cdp.send(method, params, sessionId);
    const evaluate = async (expression) => {
      const reply = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
      if (reply.exceptionDetails) throw new Error(reply.exceptionDetails.exception?.description ?? reply.exceptionDetails.text);
      return reply.result.value;
    };
    await call('Emulation.setDeviceMetricsOverride', { width: 400, height: 800, deviceScaleFactor: 2, mobile: true });
    await call('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 1 });
    await call('Emulation.setFocusEmulationEnabled', { enabled: true });
    await call('Page.bringToFront', {});
    await call('Page.navigate', { url: `http://127.0.0.1:${server.address().port}/` });
    for (let i = 0; !(await evaluate('window.ready === true')); i++) { if (i > 2000) throw new Error('page never ready'); await Bun.sleep(5); }
    const centre = (id) => evaluate(`(() => { const r = document.getElementById('${id}').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    const touch = (type, [x, y]) => call('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y, id: 1 }] });
    const drag = async (from, [dx, dy], steps = 10) => {
      for (let i = 1; i <= steps; i++) { await touch('touchMove', [from[0] + dx * i / steps, from[1] + dy * i / steps]); await Bun.sleep(16); }
    };
    // What happened since the last look: activations, and the held marks in order.
    const seen = async () => { const r = await evaluate('[log.splice(0).join(), held.splice(0).join()]'); await Bun.sleep(0); return r; };
    const quiet = () => Bun.sleep(400); // past a click's delivery, a flash and the scroll memory

    // Outside a scroller: held at the touch, activated at the lift.
    const out = await centre('out');
    await touch('touchStart', out);
    expect((await seen())[1]).toBe('out+');
    await touch('touchEnd', out);
    await quiet();
    expect(await seen()).toEqual(['out', 'out-']);

    // Dragged off before lifting: let go as it leaves, never activated.
    await touch('touchStart', out);
    await drag(out, [0, 120]);
    await touch('touchEnd', [out[0], out[1] + 120]);
    await quiet();
    expect(await seen()).toEqual(['', 'out+,out-']);

    // A switch dragged off keeps its value; tapped, it changes.
    const sw = await centre('sw');
    await touch('touchStart', sw);
    await drag(sw, [150, 0]);
    await touch('touchEnd', [sw[0] + 150, sw[1]]);
    await quiet();
    expect((await seen())[0]).toBe('');
    expect(await evaluate(`document.getElementById('sw').checked`)).toBe(false);
    await touch('touchStart', sw);
    await touch('touchEnd', sw);
    await quiet();
    expect((await seen())[0]).toBe('sw:true');

    // In a scroller a quick tap shows nothing at the touch, then its press as it lifts, and activates.
    const inside = await centre('in');
    await touch('touchStart', inside);
    expect((await seen())[1]).toBe('');
    await touch('touchEnd', inside);
    await quiet();
    expect(await seen()).toEqual(['in', 'in+,in-']);

    // Held still in a scroller: the press shows after the delay.
    await touch('touchStart', inside);
    await Bun.sleep(40);
    expect((await seen())[1]).toBe('');
    // (Headless Chromium runs the page's timer late under a held touch: wait for it.)
    let late = '';
    for (let i = 0; i < 100 && !late; i++) { await Bun.sleep(10); late = (await seen())[1]; }
    expect(late).toBe('in+');
    await touch('touchEnd', inside);
    await quiet();
    expect(await seen()).toEqual(['in', 'in-']);

    // A scroll that starts on the button: it scrolls; no press shows, nothing activates.
    // (Sent with the first move: CDP acknowledges a touch start a frame or more late.)
    await Promise.all([touch('touchStart', inside), touch('touchMove', [inside[0], inside[1] - 19])]);
    await drag([inside[0], inside[1] - 19], [0, -131], 7);
    await touch('touchEnd', [inside[0], inside[1] - 150]);
    await quiet();
    expect(await evaluate(`document.getElementById('sc').scrollTop`)).toBeGreaterThan(50);
    expect(await seen()).toEqual(['', '']);

    // A touch while the scroller still moves only stops it.
    await evaluate(`document.getElementById('sc').scrollTop = 0`);
    await Bun.sleep(400);
    const back = await centre('in');
    await evaluate(`document.getElementById('sc').scrollTop = 4`);
    await Bun.sleep(20);
    await touch('touchStart', back);
    await touch('touchEnd', back);
    await quiet();
    expect(await seen()).toEqual(['', '']);

    // The keyboard still activates: Space on the switch, Enter on a button.
    await evaluate(`document.getElementById('sw').focus()`);
    for (const type of ['keyDown', 'keyUp']) await call('Input.dispatchKeyEvent', { type, key: ' ', code: 'Space', windowsVirtualKeyCode: 32, ...(type === 'keyDown' ? { text: ' ' } : {}) });
    await evaluate(`document.getElementById('out').focus()`);
    for (const type of ['keyDown', 'keyUp']) await call('Input.dispatchKeyEvent', { type, key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, ...(type === 'keyDown' ? { text: '\r' } : {}) });
    await quiet();
    expect((await seen())[0]).toBe('sw:false,out');

    // A page whose document scrolls (nav-chrome.js's page): the document is the scroller,
    // so a press on it is late, and a pan of the page on it activates nothing.
    await evaluate(`document.getElementById('exact-root').append(Object.assign(document.createElement('div'), { style: 'height:2000px' }))`);
    await Bun.sleep(400);
    const page = await centre('out');
    await touch('touchStart', page);
    expect((await seen())[1]).toBe('');
    await touch('touchEnd', page);
    await quiet();
    expect(await seen()).toEqual(['out', 'out+,out-']);
    await Promise.all([touch('touchStart', page), touch('touchMove', [page[0], page[1] - 19])]);
    await drag([page[0], page[1] - 19], [0, -131], 7);
    await touch('touchEnd', [page[0], page[1] - 150]);
    await quiet();
    expect(await evaluate('scrollY')).toBeGreaterThan(50);
    expect(await seen()).toEqual(['', '']);

    // Fixed chrome over that page (a tab bar) is in no scroller: held at the touch, even
    // while the page still moves, and a drag that starts on it pans nothing.
    await evaluate('scrollBy(0, 4)');
    await Bun.sleep(20);
    const bar = await centre('bar');
    await touch('touchStart', bar);
    expect((await seen())[1]).toBe('bar+');
    await touch('touchEnd', bar);
    await quiet();
    expect(await seen()).toEqual(['bar', 'bar-']);
    const before = await evaluate('scrollY');
    await Promise.all([touch('touchStart', bar), touch('touchMove', [bar[0], bar[1] - 19])]);
    await drag([bar[0], bar[1] - 19], [0, -131], 7);
    await touch('touchEnd', [bar[0], bar[1] - 150]);
    await quiet();
    expect(await evaluate('scrollY')).toBe(before);
    expect((await seen())[0]).toBe('');
  } finally {
    child.kill();
    server.close();
    rmSync(profile, { recursive: true, force: true });
  }
}, 60000);
