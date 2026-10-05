// Crash capture: on a fatal signal, write one pending record, then re-raise with the
// default action. The record's text is formatted at launch into static memory, so the
// handler only calls the async-signal-safe `open`, `write` and `close`.
// The service reads the record at the next launch and attributes it to the crashed session.
import Foundation

enum ObserveCrash {
    nonisolated(unsafe) static var path: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var head: UnsafeMutablePointer<UInt8>?
    nonisolated(unsafe) static var headLength = 0
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
        for s in signals { signal(s, handler) }
    }

    static let handler: @convention(c) (Int32) -> Void = { sig in
        if let path = ObserveCrash.path, let head = ObserveCrash.head {
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 {
                _ = write(fd, head, ObserveCrash.headLength)
                // Write the signal number in decimal by hand: formatting functions aren't async-signal-safe.
                var digits: [UInt8] = [0, 0, 0, 0]
                var n = Int(sig), i = 3
                repeat { digits[i] = UInt8(48 + n % 10); n /= 10; i -= 1 } while n > 0 && i >= 0
                digits.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress! + i + 1, 3 - i) }
                var tail: [UInt8] = [125, 10] // "}\n"
                tail.withUnsafeMutableBufferPointer { _ = write(fd, $0.baseAddress!, 2) }
                close(fd)
            }
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }
}
