import { afterAll, expect, mock, test } from 'bun:test';
import { createDocument } from './dom.js';

// The build copies these modules and generates names.js.
mock.module('./navigation.js', () => import('../web/navigation.js'));
mock.module('./prompt-glue.js', () => ({}));
mock.module('./alert-message.js', () => ({}));
mock.module('./menu-rows.js', () => ({}));
mock.module('./names.js', () => ({ sourceTypes: {} }));
const previous = Object.fromEntries(['document', 'location', '__exactRender'].map(k => [k, globalThis[k]]));
Object.assign(globalThis, { document: createDocument(), location: { pathname: '/', search: '', href: 'http://list.invalid/', origin: '' }, __exactRender: true });
const rt = await import('./rt.js'), { vl } = await import('./list.js');
afterAll(() => {
  for (const [k, v] of Object.entries(previous)) { if (v === undefined) delete globalThis[k]; else globalThis[k] = v; }
});

function fixture(horizontal) {
  const el = document.createElement('div');
  document.getElementById('exact-root').append(el);
  const rows = rt.sig(Array.from({ length: 30 }, (_, i) => i));
  const own = rt.scope(() => vl(el, rows, i => i(), w => w.append(document.createElement('span')),
    { est: 20, x: horizontal, pw: [100], ph: [100] }));
  const c = el.$list;
  return { c, prepend() { rt.commit(() => rt.W(rows, Array.from({ length: 35 }, (_, i) => i - 5))); },
    close() { rt.end(own); el.remove(); } };
}

function report(c, offset, leading = 150) {
  const f = { view: c.view, revision: c.revision, scroll_sequence: (c.geometry?.scroll_sequence ?? 0) + 1,
    offset, port_main: 100, port_cross: 100, cross: 100, padding: [leading, 0], focus_view: null, interaction_view: null,
    measurements: c.mounted.map(m => ({ view: m.view, epoch: m.epoch, size: 20 })) };
  const prepared = c.prepare(f);
  expect(prepared).not.toBeNull();
  c.feedback(f, prepared, { velocity: 0, limit: null });
}

test('a prepend keeps a signed anchor within leading padding on both axes', () => {
  for (const horizontal of [false, true]) for (const offset of [-150, -60, 0]) {
    const f = fixture(horizontal);
    try {
      for (let n = 0; n < 3; n++) report(f.c, offset);
      expect(f.c.correction).toBeNull();
      f.prepend();
      if (offset === -150) {
        expect(f.c.correction).toBeNull();
        expect(f.c.geometry.offset).toBe(offset);
      } else {
        expect(f.c.correction).toMatchObject({ from: offset, offset: offset + 100 });
        expect(f.c.index.prefix(f.c.index.pos.get('n:0')) - f.c.geometry.offset).toBe(0 - offset);
      }
    } finally { f.close(); }
  }
});

test('an excluded row anchors its visible successor with a signed offset', () => {
  const f = fixture(false);
  try {
    const index = f.c.index;
    index.leading = 150;
    for (const moved of [false, true]) {
      index.replace(Array.from({ length: 30 }, (_, i) => 'n:' + i));
      const anchor = index.anchor(-60, 100, false, 'n:0');
      expect(anchor.within).toBe(-80);
      if (moved) index.replace(['n:1', 'n:0', ...index.order.slice(2)]);
      expect(index.restoreAnchor(anchor, 100)).toBe(moved ? -80 : -60);
      expect(index.keptRow(anchor, 100)).toBe(true);
    }
  } finally { f.close(); }
});
