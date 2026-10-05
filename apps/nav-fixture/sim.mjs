// The native navigation fixture driven with real touches (LLP 1035.001.000
// §4): UIKit's own chrome — the back button and its menu, the edge swipe,
// a sheet pulled down, the More list and its Edit — on a normally launched
// app, never the agent driver, which presses the hidden controls instead.
// Each step waits for what UIKit shows (the bar's title) and what the app
// holds (the screen's `counts` line: its route, how many `traverse`s and
// Backs it heard) with a bounded poll of the accessibility tree; no sleeps.
//
//   bun host/apple/build.mjs --ios nav-fixture-apple --sim <udid>
//   bun apps/nav-fixture/sim.mjs --sim <udid>
//
// Needs `axe` (https://github.com/cameroncooke/AXe) on PATH.
import { execFileSync } from 'node:child_process';

const sim = process.argv[process.argv.indexOf('--sim') + 1];
if (!process.argv.includes('--sim') || !sim) throw new Error('usage: bun apps/nav-fixture/sim.mjs --sim <udid>');
const axe = (...args) => execFileSync('axe', [...args, '--udid', sim], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

function nodes() {
  const out = [];
  const walk = n => { out.push(n); for (const c of n.children ?? []) walk(c); };
  for (const n of JSON.parse(axe('describe-ui'))) walk(n);
  return out;
}
const centre = n => [n.frame.x + n.frame.width / 2, n.frame.y + n.frame.height / 2];
const title = all => all.filter(n => n.type === 'Heading').map(n => n.AXLabel).join('|');
const counts = all => all.find(n => n.AXUniqueId?.startsWith('counts-'))?.AXLabel ?? '';

/** Polls until `test(nodes)` returns something, for at most `ms`. */
function until(what, test, ms = 6000) {
  const end = Date.now() + ms;
  let all = [];
  for (;;) {
    all = nodes();
    const found = test(all);
    if (found) return found;
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}; shown: "${title(all)}" / "${counts(all)}"`);
  }
}
/** UIKit shows `name` and the app's top route is `name`, with these counts. */
function at(name, traverses, backs = 0) {
  const want = `${name} traverses=${traverses} backs=${backs}`;
  until(`${want}`, all => title(all) === name && counts(all) === want);
  // Settled: nothing pushes it back in (B1) for the next second.
  const end = Date.now() + 1000;
  while (Date.now() < end) {
    const all = nodes();
    if (title(all) !== name || counts(all) !== want) throw new Error(`${want} did not hold: "${title(all)}" / "${counts(all)}"`);
  }
  console.log(`ok  ${want}`);
}
const tap = ([x, y]) => axe('tap', '-x', String(Math.round(x)), '-y', String(Math.round(y)), '--tap-style', 'physical');
const element = (what, test) => until(what, all => all.find(test));
const next = () => tap(centre(element('the bar\'s next button', n => n.AXUniqueId?.startsWith('next-'))));
const backButton = () => element('the back button', n => n.AXUniqueId === 'BackButton');
const tab = label => tap(centre(element(`the ${label} tab`, n => n.type === 'RadioButton' && n.AXLabel === label)));
const swipe = (from, to) => axe('swipe', '--start-x', String(from[0]), '--start-y', String(from[1]), '--end-x', String(to[0]), '--end-y', String(to[1]), '--duration', '0.4');
const pullDown = () => swipe([201, 70], [201, 860]);

execFileSync('xcrun', ['simctl', 'launch', '--terminate-running-process', sim, 'com.exact.navfixture'], { stdio: 'ignore' });
at('home', 0);

// The back button's menu: one transition three screens deep, one `traverse`.
next(); at('deep', 0); next(); at('deeper', 0); next(); at('deepest', 0);
const [bx, by] = centre(backButton());
axe('touch', '-x', String(bx), '-y', String(by), '--down');
const item = element('the back menu\'s home', n => n.AXLabel === 'home' && n.type !== 'Heading' && n.type !== 'RadioButton' && n.frame.y < 400);
axe('touch', ...['-x', String(centre(item)[0]), '-y', String(centre(item)[1])], '--up');
at('home', 1);

// The back button; the edge swipe; a swipe let go early, which cancels.
next(); at('deep', 1); tap(centre(backButton())); at('home', 2);
next(); at('deep', 2); swipe([3, 450], [330, 450]); at('home', 3);
next(); at('deep', 3); swipe([3, 450], [40, 450]); at('deep', 3);
tap(centre(backButton())); at('home', 4);

// A sheet pulled down with the screen it pushed: one `traverse`, beneath it.
tab('two'); at('two', 4);
next(); at('sheet', 4); next(); at('inner', 4);
pullDown(); at('two', 5);

// An alert over a sheet holds it; its answer asks for a sheet while the alert
// is still leaving (B6), which then stands over the first; each comes down.
next(); at('sheet', 5); next(); at('inner', 5); next();
element('the alert', n => n.AXLabel === 'Alert over a sheet');
pullDown();
element('the alert, still up', n => n.AXLabel === 'Alert over a sheet');
tap(centre(element('the alert\'s OK', n => n.AXLabel === 'OK')));
at('sheet', 5);
pullDown(); at('inner', 6);
pullDown(); at('two', 7);

// The More list: UIKit's own chrome; a tab chosen in it is selected; its
// stack pushes and pops there; back to the list changes nothing.
tab('More');
until('the More list', all => title(all) === 'More');
tap(centre(element('six in the More list', n => n.type === 'StaticText' && n.AXLabel === 'six')));
at('six', 7);
next(); at('six2', 7); tap(centre(backButton())); at('six', 8);
tap(centre(backButton()));
until('the More list again', all => title(all) === 'More');
tab('home'); at('home', 8);

// A tab chosen again in the More list is a choice (LLP 1035.001.001 D5): one
// `tabselect`, and the app's `select` takes that tab back to its root.
tab('More');
until('the More list', all => title(all) === 'More');
tap(centre(element('six in the More list', n => n.type === 'StaticText' && n.AXLabel === 'six')));
at('six', 8); next(); at('six2', 8);
tab('More');
until('the More list', all => title(all) === 'More');
tap(centre(element('six in the More list', n => n.type === 'StaticText' && n.AXLabel === 'six')));
at('six', 8);
tab('home'); at('home', 8);

// More's Edit: the person puts six on the bar; UIKit keeps that order.
tab('More');
until('the More list', all => title(all) === 'More');
tap(centre(element('Edit', n => n.AXLabel === 'Edit')));
const six = element('six to drag', n => n.type === 'RadioButton' && n.AXLabel === 'six' && n.frame.y < 700);
const two = element('two on the bar', n => n.type === 'RadioButton' && n.AXLabel === 'two' && n.frame.y > 700);
axe('drag', '--start-x', String(centre(six)[0]), '--start-y', String(centre(six)[1]), '--end-x', String(centre(two)[0]), '--end-y', String(centre(two)[1]), '--duration', '1.2');
tap(centre(element('Done', n => n.AXLabel === 'Done')));
tab('six'); at('six', 8);
tab('home'); at('home', 8);
until('six still on the bar', all => all.some(n => n.type === 'RadioButton' && n.AXLabel === 'six' && n.frame.y > 700));
console.log('nav-fixture: every step held');
