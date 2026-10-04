// @ref LLP 1027 D4 — the JS target's kept answers: the runner's encoding and
// 8 KB bound (runner/src/runner/kept.rs), what a launch shows, and the web's
// forgetting them as the store's names change. `bun test ./host/web-js/kept.test.mjs`.
import { test, expect, beforeEach } from 'bun:test';
import { Kept } from './kept.js';

const storage = new Map();
globalThis.localStorage = {
  get length() { return storage.size; },
  key: i => [...storage.keys()][i] ?? null,
  getItem: k => storage.get(k) ?? null,
  setItem: (k, v) => storage.set(k, String(v)),
  removeItem: k => storage.delete(k),
};
const boot = () => { Kept.on = undefined; Kept.held.clear(); Kept.writes.length = 0; };
beforeEach(() => { storage.clear(); boot(); });
const live = () => false;

test('an answer is kept in the runner\'s encoding: arguments and value, canonical bytes, hex', () => {
  Kept.seed('car', 'car', '{bs}', 'sn', live);
  Kept.keep('car', 'car', 'sn', ['mv', 3], [true, 'ada'], '{bs}');
  Kept.persist();
  // kept.rs's own vector: args [str "mv", 3.0], value record [true, "ada"].
  expect(storage.get('exact.kept.car')).toBe('car|060200000002020000006d76000000000000000840|070200000001010203000000616461');
  boot();
  expect(Kept.seed('car', 'car', '{bs}', 'sn', live)).toEqual([['mv', 3], [true, 'ada']]);
});

test('options, units, lists, signed zero and text beyond ASCII round-trip', () => {
  const type = '{?n?su[{ns}s}', value = [null, 'é💬', null, [[-0, 'a'], [2.5, '']], 'x'];
  Kept.seed('r', 's', type, '?n[s', live);
  Kept.keep('r', 's', '?n[s', [7, ['a', 'b']], value, type);
  Kept.persist();
  boot();
  const [args, v] = Kept.seed('r', 's', type, '?n[s', live);
  expect(args).toEqual([7, ['a', 'b']]);
  expect(v).toEqual(value);
  expect(Object.is(v[3][0][0], -0)).toBe(true);
});

test('a kept answer shows for its identifying arguments, whatever it was asked with', () => {
  expect(Kept.stands([true, 1, 2], [true, 9, 9], 1)).toBe(true);
  expect(Kept.stands([false, 1, 2], [true, 1, 2], 1)).toBe(false);
  // Without a `with`, every argument identifies the answer.
  expect(Kept.stands([1, 2], [1, 3], 2)).toBe(false);
  expect(Kept.stands([1, 2], [1, 2], 2)).toBe(true);
  expect(Kept.stands([1], [1, 2], 1)).toBe(false);
});

test('a damaged entry, another source\'s, or one outside the shape is not used', () => {
  storage.set('exact.kept.a', 'src|0600000000|0001');
  storage.set('exact.kept.b', 'old|0600000000|000000000000000840');
  storage.set('exact.kept.c', 'src|0600000000|0101');
  storage.set('exact.kept.d', 'src|0600000000|00000000000000f07f'); // +Infinity
  storage.set('exact.kept.e', 'src|0600000000|000000000000000840ff');
  storage.set('exact.kept.f', 'src|0600000000|000000000000000840');
  for (const n of 'abcde') expect(Kept.seed(n, 'src', 'n', '', live)).toBeUndefined();
  expect(Kept.seed('f', 'src', 'n', '', live)).toEqual([[], 3]);
  expect(Kept.seed('f', 'src', 'n', 'n', live)).toBeUndefined();
});

test('the 8 KB bound is the runner\'s: 8191 encoded characters fit, 8193 do not', () => {
  Kept.seed('x', 's', 's', '', live);
  Kept.keep('x', 's', '', [], 'x'.repeat(4085), 's');
  Kept.keep('y', 's', '', [], 'x'.repeat(4086), 's');
  Kept.persist();
  expect(storage.get('exact.kept.x').length - 's|'.length).toBe(8191);
  expect(storage.has('exact.kept.y')).toBe(false);
});

test('a change to the store\'s names forgets every kept answer; answers after it are kept again', () => {
  Kept.seed('a', 's', 'n', '', live);
  Kept.keep('a', 's', '', [], 1, 'n');
  Kept.keep('b', 's', '', [], 2, 'n');
  Kept.persist();
  const at = Kept.save();
  Kept.forget();
  Kept.restore(at); // a refused commit forgets nothing
  Kept.persist();
  expect([...storage.keys()].sort()).toEqual(['exact.kept.a', 'exact.kept.b']);
  Kept.forget();
  Kept.keep('a', 's', '', [], 3, 'n');
  Kept.persist();
  expect([...storage.keys()]).toEqual(['exact.kept.a']);
  boot();
  expect(Kept.seed('a', 's', 'n', '', live)).toEqual([[], 3]);
});

test('under the agent or in a render nothing is read or kept', () => {
  storage.set('exact.kept.a', 's|0600000000|000000000000000840');
  expect(Kept.seed('a', 's', 'n', '', () => true)).toBeUndefined();
  Kept.keep('b', 's', '', [], 1, 'n');
  Kept.forget();
  Kept.persist();
  expect([...storage.keys()]).toEqual(['exact.kept.a']);
});
