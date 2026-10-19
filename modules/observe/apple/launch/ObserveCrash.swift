// Crash capture: on a fatal signal, write one pending record, then hand the signal to the
// action installed before this one, whole (`sigaction`: the default action unless the app
// or another crash reporter installed one). The record's text is formatted at launch into
// static memory, so the handler only calls the async-signal-safe `open`, `write`, `close`,
// `sigaction` and `raise`.
// The service reads the record at the next launch and attributes it to the crashed session.
import ExactKit
import Foundation

enum ObserveCrash {
    nonisolated(unsafe) static var path: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var head: UnsafeMutablePointer<UInt8>?
    nonisolated(unsafe) static var headLength = 0
    /// Scratch for the signal number and "}\n", allocated at install: the handler must not allocate.
    nonisolated(unsafe) static var tail: UnsafeMutablePointer<UInt8>?
    /// Each signal's action before this one, by signal number.
    nonisolated(unsafe) static var previous: UnsafeMutablePointer<sigaction>?
    static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    /// The record's file name, `exact-observe-pending-<session>-<app>.json`: the session
    /// is a UUID, so the app id after it is read exactly. An app outside a sandbox shares
    /// Caches with others and reads only its own.
    static func fileName(session: String, app: String) -> String { "exact-observe-pending-\(session)-\(app).json" }

    /// `app` is the crashed build's identity and metadata (`appVersion`, `appBuildNumber`,
    /// `osVersion`), kept with the record: the next launch can be another build.
    static func install(directory: String, session: String, app: String, metadata: [String: String]) {
        // The directory (Caches) already exists. The file is created only on a crash.
        path = strdup("\(directory)/\(fileName(session: session, app: app))")
        let wall = Date().timeIntervalSince1970
        let meta = String(decoding: (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
        let id = String(decoding: (try? JSONSerialization.data(withJSONObject: [app], options: [])) ?? Data("[\"\"]".utf8), as: UTF8.self).dropFirst().dropLast()
        let text = "{\"session\":\"\(session)\",\"app\":\(id),\"sessionStart\":\(wall),\"metadata\":\(meta),"
        let bytes = Array(text.utf8)
        head = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        head!.initialize(from: bytes, count: bytes.count)
        headLength = bytes.count
        tail = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
        let before = UnsafeMutablePointer<sigaction>.allocate(capacity: Int(NSIG))
        before.initialize(repeating: sigaction(), count: Int(NSIG))
        previous = before
        var action = sigaction()
        action.__sigaction_u = __sigaction_u(__sa_sigaction: handler)
        action.sa_flags = SA_SIGINFO
        sigemptyset(&action.sa_mask)
        for s in signals { sigaction(s, &action, before + Int(s)) }
    }

    static let handler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { sig, info, _ in
        if let path = ObserveCrash.path, let head = ObserveCrash.head, let tail = ObserveCrash.tail {
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 {
                _ = write(fd, head, ObserveCrash.headLength)
                // The update running at the crash (ExactKit's, set as each generation starts, so
                // also during startup, before the service has stored it), then the signal number.
                if let u = ExactLaunch.runningUpdate {
                    let key: StaticString = "\"updateId\":\""
                    _ = write(fd, key.utf8Start, key.utf8CodeUnitCount)
                    _ = write(fd, u, strlen(u))
                    let end: StaticString = "\","
                    _ = write(fd, end.utf8Start, end.utf8CodeUnitCount)
                }
                let signalKey: StaticString = "\"signal\":"
                _ = write(fd, signalKey.utf8Start, signalKey.utf8CodeUnitCount)
                // The signal number in decimal, then "}\n": formatting functions aren't async-signal-safe.
                var n = Int(sig), start = 6
                tail[6] = 125
                tail[7] = 10
                repeat { start -= 1; tail[start] = UInt8(48 + n % 10); n /= 10 } while n > 0 && start > 0
                _ = write(fd, tail + start, 8 - start)
                close(fd)
            }
        }
        if let previous = ObserveCrash.previous { sigaction(sig, previous + Int(sig), nil) } else { signal(sig, SIG_DFL) }
        // A fault the processor raised recurs when this handler returns, so that action sees the
        // original fault and its address. A signal software raised (`abort`, `kill`) is raised again,
        // to be delivered once this handler returns; `abort` would set the default action instead.
        let code = info?.pointee.si_code ?? 0
        if sig == SIGABRT || !(1..<SI_USER).contains(code) { raise(sig) }
    }
}
