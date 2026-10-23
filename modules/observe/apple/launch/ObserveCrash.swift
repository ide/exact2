// Crash capture: on a fatal signal, write one pending record, then re-raise with the
// default action. The record's text is formatted at launch into static memory, so the
// handler only calls the async-signal-safe `open`, `write` and `close`.
// The service reads the record at the next launch and attributes it to the crashed session.
import Foundation

enum ObserveCrash {
    nonisolated(unsafe) static var path: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var head: UnsafeMutablePointer<UInt8>?
    nonisolated(unsafe) static var headLength = 0
    /// Scratch for the signal number and "}\n", allocated at install: the handler must not allocate.
    nonisolated(unsafe) static var tail: UnsafeMutablePointer<UInt8>?
    static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    static func install(directory: String, session: String) {
        // The directory (Caches) already exists. The file is created only on a crash.
        path = strdup("\(directory)/exact-observe-pending-\(session).json")
        let wall = Date().timeIntervalSince1970
        let text = "{\"session\":\"\(session)\",\"sessionStart\":\(wall),\"signal\":"
        let bytes = Array(text.utf8)
        head = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        head!.initialize(from: bytes, count: bytes.count)
        headLength = bytes.count
        tail = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
        for s in signals { signal(s, handler) }
    }

    static let handler: @convention(c) (Int32) -> Void = { sig in
        if let path = ObserveCrash.path, let head = ObserveCrash.head, let tail = ObserveCrash.tail {
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 {
                _ = write(fd, head, ObserveCrash.headLength)
                // The signal number in decimal, then "}\n": formatting functions aren't async-signal-safe.
                var n = Int(sig), start = 6
                tail[6] = 125
                tail[7] = 10
                repeat { start -= 1; tail[start] = UInt8(48 + n % 10); n /= 10 } while n > 0 && start > 0
                _ = write(fd, tail + start, 8 - start)
                close(fd)
            }
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }
}
