import XCTest
@testable import ExactKit

final class AgentSwipeTests: XCTestCase {
    static func ask(_ agent: Agent, _ request: [String: Any]) throws -> [String: Any] {
        let pipe = Pipe(), saved = Agent.out
        Agent.out = pipe.fileHandleForWriting
        defer { Agent.out = saved; try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let data = try JSONSerialization.data(withJSONObject: ["op": "tap"].merging(request) { _, value in value })
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var completed = 0
        agent.handle(op: "tap", wire, line: String(decoding: data, as: UTF8.self)) { completed += 1 }
        XCTAssertEqual(completed, 1, "the router completes each tap once")
        try pipe.fileHandleForWriting.close()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    }

    func testTheOuterRouterRejectsMixedSwipesBeforeItsShortcuts() throws {
        let session = ExactApp.shared.makeSession(label: "routed-swipe")
        defer { session.destroy() }
        let agent = Agent(session: session)
        agent.contact = CGPoint(x: 12, y: 34)
        let mixed: [[String: Any]] = [
            ["mediaSession": "pause"], ["pictureInPicture": "close"], ["into": ["key": "row"]],
            ["contact": 7, "phase": "up"], ["contact": 7, "phase": "cancel"],
            ["part": "seal", "aim": true], ["close": true], ["back": true], ["resize": [300, 200]],
            ["ticket": 1], ["world": true], ["entity": "player"], ["widget": true], ["activity": true],
        ]
        for fields in mixed {
            for raw in ["down", NSNull()] as [Any] {
                let reply = try Self.ask(agent, ["id": 1, "swipe": raw].merging(fields) { _, value in value })
                XCTAssertEqual(reply["malformed"] as? Bool, true, "\(fields): \(reply)")
                XCTAssertNil(reply["delivery"], "\(reply)")
                XCTAssertEqual(agent.contact, CGPoint(x: 12, y: 34), "a malformed request leaves the held contact alone")
            }
        }
        let media = try Self.ask(agent, ["id": 1, "mediaSession": "pause"])
        XCTAssertNil(media["malformed"], "\(media)")
        XCTAssertEqual(media["error"] as? String, "no view 1 on screen", "ordinary media input still reaches its router")
    }

    func testMalformedSwipeRequestsAreRefusedBeforeAnyTapForm() {
        let session = ExactApp.shared.makeSession(label: "malformed-swipe")
        defer { session.destroy() }
        let agent = Agent(session: session)
        let invalid: [[String: Any]] = [
            ["swipe": NSNull()], ["swipe": "sideways"], ["swipe": true],
            ["id": true], ["id": -1], ["id": 1.5], ["id": "1"],
            ["at": [true, false]], ["at": [0.0, Double.infinity]], ["at": [1]], ["at": NSNull()],
            ["mouse": true], ["phase": "down"], ["holdState": "active"], ["modifiers": "Shift"],
            ["check": "true"],
        ]
        for fields in invalid {
            let req = ["id": 1, "swipe": "down"] as [String: Any]
            let reply = agent.tap(req.merging(fields) { _, b in b })
            XCTAssertEqual(reply["malformed"] as? Bool, true, "\(fields): \(reply)")
        }
        #if os(tvOS)
        let reply = agent.tap(["id": 1, "swipe": "down"])
        XCTAssertEqual(reply["delivery"] as? String, "unsupported")
        XCTAssertTrue((reply["reason"] as? String)?.contains("tvOS makes no swipe") == true)
        #endif
    }
}
