#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// Both `CollectionHost.fit` and `NodeView.fitScroll` keep the scroller as
/// long as its rows' extent, including after a geometry replay.
final class CollectionExtentIOSTests: XCTestCase {
    /// Shorter laid-out content must not cut the scroll range and clamp an
    /// overscroll while UIKit is springing it back.
    func testAGeometryReplayKeepsTheListsEndAtItsExtent() throws {
        for horizontal in [false, true] {
            let p = Presenter()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
            p.viewport.frame = window.bounds
            window.addSubview(p.viewport)
            window.makeKeyAndVisible()
            defer { p.reset(); window.isHidden = true }
            let content = { (length: Double) -> [String: Any] in
                ["op": "content", "id": 1, "w": horizontal ? length : 300, "h": horizontal ? 300 : length]
            }
            p.apply(wireBatch([
                ["op": "collections", "items": [["view": 1, "revision": 1, "scrollSequence": 0, "axis": horizontal ? "x" : "y", "count": 100,
                    "totalExtent": 5000, "pending": false, "rows": [["view": 10, "root": 10, "epoch": 1, "index": 0]], "correction": NSNull()]]],
                ["op": "create", "id": 1, "kind": "list", "style": [horizontal ? "overflow_x" : "overflow_y": "scroll"]],
                ["op": "create", "id": 10, "kind": "view"],
                ["op": "children", "id": 1, "ids": [10]], ["op": "roots", "ids": [1]],
                ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 300.0],
                ["op": "frame", "id": 10, "x": 0.0, "y": 0.0, "w": horizontal ? 50.0 : 300.0, "h": horizontal ? 300.0 : 50.0], content(4980)
            ]))
            let scroll = try XCTUnwrap(p.views[1]?.scroll)
            let length = { horizontal ? scroll.contentSize.width : scroll.contentSize.height }
            XCTAssertEqual(length(), 5000, accuracy: 0.5, "as long as its rows")
            p.applyGeometry(wireBatch([content(4980)]).ops[0])
            XCTAssertEqual(length(), 5000, accuracy: 0.5, "a replay of shorter content keeps its end")
            p.applyGeometry(wireBatch([content(5100)]).ops[0])
            XCTAssertEqual(length(), 5100, accuracy: 0.5, "longer laid-out content still reaches further")
        }
    }
}
#endif
