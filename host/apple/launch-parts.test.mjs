import { expect, test } from 'bun:test';
import { auditLaunchParts } from './launch-parts.mjs';

const object = import.meta.filename;
const modules = [{ name: 'observe' }];
const size = { status: 0, stdout: '__TEXT __DATA\n21083 936\n' };
const commands = { status: 0, stdout: 'cmd LC_SEGMENT_64\nsectname __text\n' };

test('launch-part inspection refuses failed or unreadable tool results', () => {
  for (const bad of [
    { status: 1, stdout: size.stdout },
    { status: null, stdout: '' },
    { status: 0, stdout: 'unreadable' },
    { status: 0, stdout: '__TEXT __DATA\nNaN 936\n' },
    { status: 0, stdout: '__TEXT __DATA\n-1 936\n' },
  ]) {
    expect(() => auditLaunchParts(object, modules, tool => tool === 'xcrun' ? bad : commands)).toThrow('size inspection failed');
  }
  for (const bad of [{ status: 1, stdout: commands.stdout }, { status: 0, stdout: '' }]) {
    expect(() => auditLaunchParts(object, modules, tool => tool === 'xcrun' ? size : bad)).toThrow('load-command inspection failed');
  }
});

test('launch-part inspection accepts the byte limit and reports all forbidden code', () => {
  expect(() => auditLaunchParts(object, modules, tool => tool === 'xcrun'
    ? { status: 0, stdout: '__TEXT __DATA\n32768 0\n' } : commands)).not.toThrow();
  const inspect = tool => tool === 'xcrun'
    ? { status: 0, stdout: '__TEXT __DATA\n32768 1\n' }
    : { status: 0, stdout: `${commands.stdout}sectname __mod_init_func\nsectname __objc_nlclslist\n` };
  for (const problem of ['32 KiB budget', 'static initializer', 'Objective-C +load']) {
    expect(() => auditLaunchParts(object, modules, inspect)).toThrow(problem);
  }
  expect(() => auditLaunchParts(object, modules, tool => tool === 'xcrun' ? size
    : { status: 0, stdout: `${commands.stdout}sectname __init_offsets\n` })).toThrow('static initializer');
});
