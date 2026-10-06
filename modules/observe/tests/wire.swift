// Feeds wire.json's events through ObserveService and prints the metrics and logs
// bodies it would send, as {"metrics": …, "logs": …}. wire.test.mjs compiles and runs it.
import Foundation

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
        let service = ObserveService(config: config, handoff: handoff, root: root, clientId: UUID(uuidString: fixture["clientId"] as! String)!)
        for e in fixture["events"] as! [Any] { service.event(try JSONSerialization.data(withJSONObject: e)) }
        let out = service.queue.sync {
            ["metrics": service.chunk("metrics", limit: 200)?.body ?? [:], "logs": service.chunk("logs", limit: 200)?.body ?? [:],
             "recent": service.query(["op": "recent", "limit": 3]), "unknown": service.query(["op": "everything"])]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out))
    }
}
