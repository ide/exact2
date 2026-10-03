// The JS target's `formatDate` and `formatNumber` are the browser's `Intl`
// (host/web-js/stdlib.js); the runner's are Rust copies of Intl's `en-US`.
// This holds the JS to the runner's own oracle table
// (runner/tests/it/format.rs), read from that file, under Bun's ICU; a
// browser whose ICU prints otherwise is the deviation LLP 1001 declares.
import { test, expect } from 'bun:test';
import { readFileSync } from 'node:fs';
import { x_formatDate, x_formatNumber, x_at } from '../../web-js/stdlib.js';

const src = readFileSync(new URL('../../../runner/tests/it/format.rs', import.meta.url), 'utf8');
const table = name => src.slice(src.indexOf(`const ${name}`), src.indexOf('];', src.indexOf(`const ${name}`)));
const num = t => ({ 'f64::INFINITY': Infinity, 'f64::NEG_INFINITY': -Infinity, 'f64::NAN': NaN, 'f64::MAX': Number.MAX_VALUE, 'f64::MIN_POSITIVE': 2.2250738585072014e-308 })[t.trim()] ?? Number(t.trim().replaceAll('_', ''));
const str = `"((?:[^"\\\\]|\\\\.)*)"`;

test('formatDate is the runner oracle in both styles', () => {
  const rows = [...table('DATES').matchAll(new RegExp(`\\(\\s*([^,()]+),\\s*([^,()]+),\\s*${str},\\s*${str},\\s*${str}\\s*\\)`, 'g'))];
  expect(rows.length).toBeGreaterThan(400);
  for (const [, ms, off, , medium, monthYear] of rows) {
    expect([ms, off, x_formatDate(num(ms), num(off), 'medium')]).toEqual([ms, off, JSON.parse(`"${medium}"`)]);
    expect([ms, off, x_formatDate(num(ms), num(off), 'month-year')]).toEqual([ms, off, JSON.parse(`"${monthYear}"`)]);
  }
});

test('formatNumber compact is the runner oracle', () => {
  const rows = [...table('NUMBERS').matchAll(new RegExp(`\\(\\s*([^,()]+),\\s*${str}\\s*\\)`, 'g'))];
  expect(rows.length).toBeGreaterThan(100);
  for (const [, n, want] of rows) expect([n, x_formatNumber(num(n), 'compact')]).toEqual([n, JSON.parse(`"${want}"`)]);
});

test('invalid input is blank', () => {
  for (const bad of [NaN, Infinity, -Infinity]) {
    expect(x_formatDate(bad, 0, 'medium')).toBe('');
    expect(x_formatDate(0, bad, 'medium')).toBe('');
    expect(x_formatNumber(bad, 'compact')).toBe('');
  }
  for (const off of [1080.5, -1081, 1e9]) expect(x_formatDate(0, off, 'medium')).toBe('');
});

test('at counts from either end and is null past them', () => {
  const l = ['a', 'b', 'c'];
  expect([x_at(l, 0), x_at(l, 2.9), x_at(l, -1), x_at(l, -3), x_at(l, 3), x_at(l, -4), x_at([], 0)]).toEqual(['a', 'c', 'c', 'a', null, null, null]);
});
