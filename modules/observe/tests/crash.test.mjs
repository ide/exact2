// Observe's Apple crash handler (launch/ObserveCrash.swift) in a process that crashes: it writes
// its record, then the action installed before it runs with the original fault, or the default
// action ends the process. `bun test ./modules/observe/tests/crash.test.mjs`, on macOS only.
import { expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = import.meta.dir;

// What the handler reads of ExactKit.
const STUB = 'public enum ExactLaunch { nonisolated(unsafe) public static var runningUpdate: UnsafeMutablePointer<CChar>? = nil }\n';

// `harness <dir> <fault|abort> <none|info>`: with `info`, an SA_SIGINFO handler installed before
// Observe's writes the signal and the fault address to <dir>/previous and exits 0.
const HARNESS = `import Foundation
let args = CommandLine.arguments
nonisolated(unsafe) var marker = strdup(args[1] + "/previous")!
if args[3] == "info" {
    var a = sigaction()
    a.__sigaction_u = __sigaction_u(__sa_sigaction: { sig, info, _ in
        let text = "\\(sig) \\(UInt(bitPattern: info?.pointee.si_addr))"
        let fd = open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        _ = text.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        _exit(0)
    })
    a.sa_flags = SA_SIGINFO
    for s in [SIGSEGV, SIGBUS, SIGABRT] { sigaction(s, &a, nil) }
}
ObserveCrash.install(directory: args[1], session: "00000000-0000-4000-8000-000000000001", app: "com.example.crash", metadata: [:])
if args[2] == "fault" { UnsafeMutablePointer<Int>(bitPattern: 0x10)!.pointee = 1 } else { abort() }
`;

test.skipIf(process.platform !== 'darwin')('a crash writes its record, then the action before it sees the original fault', () => {
  const work = mkdtempSync(join(tmpdir(), 'observe-crash-'));
  try {
    writeFileSync(join(work, 'stub.swift'), STUB);
    writeFileSync(join(work, 'main.swift'), HARNESS);
    const lib = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-emit-library', '-emit-module', '-module-name', 'ExactKit',
      '-module-cache-path', join(work, 'cache'), join(work, 'stub.swift'), '-o', join(work, 'libExactKit.dylib'), '-emit-module-path', join(work, 'ExactKit.swiftmodule')], { encoding: 'utf8' });
    expect(lib.status, lib.stderr).toBe(0);
    const exe = join(work, 'harness');
    const build = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-module-cache-path', join(work, 'cache'), '-I', work, '-L', work, '-lExactKit',
      '-Xlinker', '-rpath', '-Xlinker', work, join(dir, '../apple/launch/ObserveCrash.swift'), join(work, 'main.swift'), '-o', exe], { encoding: 'utf8' });
    expect(build.status, build.stderr).toBe(0);
    for (const [mode, previous, signal] of [['fault', 'info', 11], ['abort', 'info', 6], ['fault', 'none', 11], ['abort', 'none', 6]]) {
      const run = join(work, `${mode}-${previous}`);
      mkdirSync(run);
      const r = spawnSync(exe, [run, mode, previous], { encoding: 'utf8' });
      const record = readdirSync(run).find(f => f.startsWith('exact-observe-pending-'));
      expect(record, `${mode} ${previous}: the record`).toBeDefined();
      expect(JSON.parse(readFileSync(join(run, record), 'utf8')).signal).toBe(signal);
      if (previous === 'info') {
        expect(r.status, `${mode}: the earlier handler ran and exited`).toBe(0);
        const [sig, address] = readFileSync(join(run, 'previous'), 'utf8').split(' ').map(Number);
        expect(sig).toBe(signal);
        // The fault's own address (0x10) reaches it; abort's signal carries none.
        if (mode === 'fault') expect(address).toBe(0x10);
      } else {
        expect(r.signal, `${mode}: the default action ended it`).toBe(signal === 11 ? 'SIGSEGV' : 'SIGABRT');
        expect(existsSync(join(run, 'previous'))).toBe(false);
      }
    }
  } finally { rmSync(work, { recursive: true, force: true }); }
}, 120_000);
