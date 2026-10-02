// Temporary driver for a long-lived Lexy session (not committed): reads ops,
// one per line, from a FIFO and logs replies. Credentials come from a file.
import { open } from './agent.mjs';
import { readFileSync, existsSync, unlinkSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { createReadStream } from 'node:fs';

const creds = JSON.parse(readFileSync('/tmp/pw/lexus.json', 'utf8'));
const s = await open({ host: 'ios', epoch: Date.now(), env: { EXACT_STORE: process.env.LEXY_STORE ?? 'real' }, ...(process.env.LEXY_URL ? { url: process.env.LEXY_URL } : {}) });
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const texts = async () => {
  const t = await s.tree();
  return t.nodes.filter(n => n.props?.testId || n.text).map(n => `${n.props?.testId ?? ''}${n.text ? ' ' + JSON.stringify(n.text) : ''}`);
};
log('open', s.boot);
for (;;) {
  const rl = createInterface({ input: createReadStream('/tmp/pw/cmd') });
  for await (const line of rl) {
    const [op, target, ...rest] = line.trim().split(' ');
    try {
      if (op === 'signin') {
        await s.type('email', creds.username);
        await s.type('password', creds.password);
        await s.tap('sign-in-button');
        log('settle', JSON.stringify(await s.clock('settle')));
      } else if (op === 'tap') { await s.tap(target); log('tap', target, JSON.stringify(await s.clock('settle'))); }
      else if (op === 'type') { await s.type(target, rest.join(' ')); log('typed', target); }
      else if (op === 'settle') log('settle', JSON.stringify(await s.clock('settle')));
      else if (op === 'advance') { await s.clock('+' + target); log('advance', target, JSON.stringify(await s.clock('settle'))); }
      else if (op === 'texts') log('texts\n' + (await texts()).join('\n'));
      else if (op === 'logs') { const l = await s.logs(); log('logs\n' + l.lines.join('\n') + '\n' + l.host.join('\n')); }
      else if (op === 'grep') { const l = await s.logs(); log('grep\n' + [...l.lines, ...l.host].filter(x => new RegExp(target, 'i').test(x)).join('\n')); }
      else if (op === 'wheel') { await s.tap(target, { wheel: [0, Number(rest[0])] }); log('wheel', JSON.stringify(await s.clock('settle'))); }
      else if (op === 'shot') log('shot', JSON.stringify(await s.screenshot(target, true)));
      else if (op === 'node') {
        const st = await s.state();
        const slots = st.slots ?? st;
        const raw = slots.nodeRaw ?? '';
        const node = raw ? JSON.parse(raw) : null;
        log('node', JSON.stringify({ step: slots.signStep, error: slots.signError, nodeTypes: slots.nodeTypes, callbacks: node?.callbacks?.map(c => ({ type: c.type, output: c.output, inputNames: c.input?.map(i => i.name) })), stage: node?.stage, header: node?.header, description: node?.description }, null, 1));
      }
      else if (op === 'prefer') log('prefer', JSON.stringify(await s.prefer({ [target]: rest[0] })));
      else if (op === 'down') log('down', JSON.stringify(await s.tap(target, { down: true })));
      else if (op === 'hold') log('hold', JSON.stringify(await s.pointer('hold', { ms: Number(target) })));
      else if (op === 'up') log('up', JSON.stringify(await s.pointer('up')));
      else if (op === 'slot') { const st = await s.state(); log('slot', target, JSON.stringify((st.slots ?? {})[target])?.slice(0, 1000)); }
      else if (op === 'res') { const st = await s.state(); const r = st.resources ?? {}; log('res', Object.keys(st).join(','), '|', JSON.stringify(r[target] ?? st[target] ?? Object.keys(r)).slice(0, 3000)); }
      else if (op === 'answers') {
        const st = await s.state();
        const slots = st.slots ?? st;
        const pick = v => v && typeof v === 'object' ? { ok: v.ok, status: v.status, error: v.error, types: v.types, tokenId: v.tokenId ? '<set>' : '' } : v;
        log('answers', JSON.stringify(Object.fromEntries(['started','named','passed','chose','verified','finished'].map(k => [k, pick(slots[k]?.value ?? slots[k])]))));
        log('keys', Object.keys(st).join(','));
      }
      else if (op === 'layout') { const l = await s.layout(target); require('fs').writeFileSync('/tmp/pw/layout.json', JSON.stringify(l)); log('layout', JSON.stringify(l).slice(0, 400)); }
      else if (op === 'tree1') log('tree1', JSON.stringify(await s.tree(target)).slice(0, 4000));
      else if (op === 'store') { const st = await s.state(); log('store', JSON.stringify(st.store, (k, v) => typeof v === 'string' && v.length > 40 ? `<${v.length} chars>` : v).slice(0, 2000)); log('kept', JSON.stringify(st.kept).slice(0, 1500)); }
      else if (op === 'dump') { const t = await s.tree(); require('fs').writeFileSync('/tmp/pw/tree.json', JSON.stringify(t, null, 1)); log('dump', t.nodes?.length); }
      else if (op === 'quit') { await s.close?.(); process.exit(0); }
    } catch (e) { log('error', op, e.message); }
  }
}
