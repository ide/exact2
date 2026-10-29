#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// A list's scroller is as long as its rows' extent, whichever writer sizes it last: the batch's fit
/// (`CollectionHost.fit`) or a frame or content box applied after it (`NodeView.fitScroll`).
final class CollectionExtentIOSTests: XCTestCase {
    /// A replay of shorter laid-out content keeps the end where the runner's extent puts it: cut short while UIKit
    /// springs the port back from past the end, it would clamp the rubber band there.
    func testAGeometryReplayKeepsTheListsEndAtItsExtent() throws {
        let p = Presenter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        defer { p.reset(); window.isHidden = true }
        p.apply(wireBatch([
            ["op": "collections", "items": [["view": 1, "revision": 1, "scrollSequence": 0, "count": 100,
                "totalExtent": 5000, "pending": false, "rows": [["view": 10, "root": 10, "epoch": 1, "index": 0]], "correction": NSNull()]]],
            ["op": "create", "id": 1, "kind": "list", "style": ["overflow_y": "scroll"]],
            ["op": "create", "id": 10, "kind": "view"],
            ["op": "children", "id": 1, "ids": [10]], ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 300.0],
            ["op": "frame", "id": 10, "x": 0.0, "y": 0.0, "w": 300.0, "h": 50.0],
            ["op": "content", "id": 1, "w": 300.0, "h": 4980.0],
        ]))
        let scroll = try XCTUnwrap(p.views[1]?.scroll)
        XCTAssertEqual(scroll.contentSize.height, 5000, accuracy: 0.5, "as long as its rows")
        p.applyGeometry(wireBatch([["op": "content", "id": 1, "w": 300.0, "h": 4980.0]]).ops[0])
        XCTAssertEqual(scroll.contentSize.height, 5000, accuracy: 0.5, "a replay of shorter content keeps its end")
        p.applyGeometry(wireBatch([["op": "content", "id": 1, "w": 300.0, "h": 5100.0]]).ops[0])
        XCTAssertEqual(scroll.contentSize.height, 5100, accuracy: 0.5, "longer laid-out content still reaches further")
    }
}
#endif
