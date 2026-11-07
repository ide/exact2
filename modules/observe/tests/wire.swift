// Feeds wire.json's events through ObserveService and prints the metrics and logs
// bodies it would send, as {"metrics": …, "logs": …}. wire.test.mjs compiles and runs it.
import Foundation
import SQLite3

// Observe loads on the UI thread; record SQLite opens without changing their behavior
private enum SQLiteThreads {
    static let lock = NSLock()
    static var mainOpens = 0
    static var totalOpens = 0
    static let original = sqlite3_vfs_find(nil)!
    static let monitored: UnsafeMutablePointer<sqlite3_vfs> = {
        let copy = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
        copy.initialize(to: original.pointee)
        copy.pointee.zName = UnsafePointer(strdup("observe-wire-threads"))
        copy.pointee.xOpen = { _, name, file, flags, output in
            lock.lock()
            totalOpens += 1
            if Thread.isMainThread { mainOpens += 1 }
            lock.unlock()
            return original.pointee.xOpen!(original, name, file, flags, output)
        }
        return copy
    }()

    static func install() {
        precondition(sqlite3_vfs_register(monitored, 1) == SQLITE_OK)
    }

    static func counts() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["mainOpens": mainOpens, "totalOpens": totalOpens]
    }
}

@main
enum WireHarness {
    static func main() throws {
        let args = CommandLine.arguments
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let app = fixture["app"] as! [String: Any]
        let config: [String: Any] = [
            "session": fixture["session"]!, "sessionStart": fixture["sessionStart"]!, "environment": fixture["environment"]!,
            "app.CFBundleIdentifier": app["id"]!, "app.CFBundleName": app["name"]!,
        ]
        // The handoff is length-prefixed JSON records. The device record holds the state at TTI.
        let record = try JSONSerialization.data(withJSONObject: ["kind": "device", "params": fixture["device"]!])
        var handoff = withUnsafeBytes(of: UInt32(record.count).littleEndian) { Data($0) }
        handoff.append(record)
        SQLiteThreads.install()
        let began = DispatchTime.now().uptimeNanoseconds
        let service = ObserveService(config: config, handoff: handoff, root: root, clientId: UUID(uuidString: fixture["clientId"] as! String)!)
        let constructed = DispatchTime.now().uptimeNanoseconds
        for e in fixture["events"] as! [Any] { service.event(try JSONSerialization.data(withJSONObject: e)) }
        var out: [String: Any] = service.queue.sync {
            ["metrics": service.chunk("metrics", limit: 200)?.body ?? [:], "logs": service.chunk("logs", limit: 200)?.body ?? [:],
             "recent": service.query(["op": "recent", "limit": 3]), "unknown": service.query(["op": "everything"])]
        }
        let ready = DispatchTime.now().uptimeNanoseconds
        out["initialization"] = ["returnedMs": Double(constructed - began) / 1_000_000, "readyMs": Double(ready - began) / 1_000_000,
                                 "threads": SQLiteThreads.counts()] as [String: Any]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out))
    }
}
