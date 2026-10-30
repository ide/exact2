#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
import XCTest
@testable import ExactKit

/// LLP 1057.001 §8 on UIKit: `swipe` is a `UISwipeGestureRecognizer` per
/// direction the node names, taking its `touch-count`; it waits for a scroll
/// view's pan only where that pan would begin, and an outer swipe for an
/// inner one; a finger's flick passes a text editor, a pointer's does not,
/// and a selection moved during the contact refuses it. UIKit synthesizes no
/// touches for a unit test, so the tests hand the recognizers theirs.
final class DiscreteSwipeIOSTests: XCTestCase {
    private var window: UIWindow!

    private func host(_ ops: [[String: Any]]) -> Presenter {
        let p = Presenter()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        p.apply(wireBatch(ops))
        window.makeKeyAndVisible()
        return p
    }
    private func swipes(_ node: NodeView) -> [DiscreteSwipe] { node.gestureRecognizers?.compactMap { $0 as? DiscreteSwipe } ?? [] }

    /// A touch of the kind and on the view the test names.
    private final class Touch: UITouch {
        let on: UIView, kind: UITouch.TouchType, at: TimeInterval
        init(on: UIView, kind: UITouch.TouchType = .direct, at: TimeInterval = 10) { self.on = on; self.kind = kind; self.at = at; super.init() }
        override var view: UIView? { on }
        override var type: UITouch.TouchType { kind }
        override var timestamp: TimeInterval { at }
    }

    func testASwipeIsOneRecognizerPerDirectionAndTakesItsCount() throws {
        let p = host([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "down up", "touchCount": "2"]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 200.0],
        ])
        let node = try XCTUnwrap(p.views[1])
        XCTAssertEqual(swipes(node).map(\.direction), [.down, .up])
        XCTAssertEqual(swipes(node).map(\.numberOfTouchesRequired), [2, 2])
        let before = swipes(node)
        p.apply(wireBatch([["op": "props", "id": 1, "set": ["swipeDirection": "left"], "clear": ["touchCount"]]]))
        XCTAssertEqual(swipes(node).map(\.direction), [.left])
        XCTAssertEqual(swipes(node).map(\.numberOfTouchesRequired), [1], "omitted: UIKit's own, one finger")
        XCTAssertTrue(before.allSatisfy { $0.view == nil }, "a new configuration makes new recognizers")

        // Only the node's current recognizers speak for it (`swiped`)
        XCTAssertTrue(node.discreteSwipes.contains { $0 === swipes(node)[0] })
        XCTAssertFalse(node.discreteSwipes.contains { $0 === before[0] })
    }

    func testASwipeWaitsForAScrollViewsPanOnlyWhereItWouldScroll() throws {
        let p = host([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "down right"]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 200.0],
        ])
        let node = try XCTUnwrap(p.views[1])
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        node.addSubview(scroll)
        let down = try XCTUnwrap(swipes(node).first { $0.word == "down" }), right = try XCTUnwrap(swipes(node).first { $0.word == "right" })
        XCTAssertTrue(node.admitsSwipe(down, Touch(on: scroll)))
        XCTAssertTrue(node.admitsSwipe(right, Touch(on: scroll)))
        scroll.contentSize = CGSize(width: 300, height: 400)
        XCTAssertTrue(node.swipeRequiresFailure(down, of: scroll.panGestureRecognizer), "it scrolls down: scroll wins")
        XCTAssertFalse(node.swipeRequiresFailure(right, of: scroll.panGestureRecognizer), "it does not scroll sideways")
        scroll.contentSize = CGSize(width: 300, height: 100)
        XCTAssertFalse(node.swipeRequiresFailure(down, of: scroll.panGestureRecognizer), "its content fits")
        scroll.alwaysBounceVertical = true
        XCTAssertTrue(node.swipeRequiresFailure(down, of: scroll.panGestureRecognizer), "it bounces")
    }

    func testAnOuterSwipeWaitsForAnInnerOneInTheSameDirectionAndCount() throws {
        let p = host([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "down left"]],
            ["op": "create", "id": 2, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "down"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 200.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 300.0, "h": 100.0],
        ])
        let outer = try XCTUnwrap(p.views[1]), inner = try XCTUnwrap(p.views[2])
        let innerDown = try XCTUnwrap(swipes(inner).first)
        XCTAssertTrue(outer.swipeRequiresFailure(try XCTUnwrap(swipes(outer).first { $0.word == "down" }), of: innerDown))
        XCTAssertFalse(outer.swipeRequiresFailure(try XCTUnwrap(swipes(outer).first { $0.word == "left" }), of: innerDown))
        XCTAssertFalse(inner.swipeRequiresFailure(innerDown, of: try XCTUnwrap(swipes(outer).first)), "the inner one waits for no ancestor")
    }

    func testAFingerPassesAnEditorAndASelectionMovedSinceItWentDownRefusesTheSwipe() throws {
        let p = host([
            ["op": "create", "id": 1, "kind": "view", "handlers": ["swipe"], "props": ["swipeDirection": "down"]],
            ["op": "create", "id": 2, "kind": "textarea", "props": ["value": "Hello"]],
            ["op": "create", "id": 3, "kind": "button", "handlers": ["press"]],
            ["op": "children", "id": 1, "ids": [2, 3]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 200.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 300.0, "h": 100.0],
            ["op": "frame", "id": 3, "x": 0.0, "y": 120.0, "w": 60.0, "h": 40.0],
        ])
        let bar = try XCTUnwrap(p.views[1]), field = try XCTUnwrap(p.views[2]), button = try XCTUnwrap(p.views[3])
        let text = try XCTUnwrap(field.textArea)
        let down = try XCTUnwrap(swipes(bar).first)
        XCTAssertTrue(bar.admitsSwipe(down, Touch(on: text)), "a finger's flick on the field is the bar's")
        XCTAssertFalse(bar.admitsSwipe(down, Touch(on: text, kind: .indirectPointer)), "a pointer's drag selects")
        XCTAssertFalse(bar.admitsSwipe(down, Touch(on: text, kind: .pencil)))
        XCTAssertFalse(bar.admitsSwipe(down, Touch(on: button)), "a press between keeps the contact")
        down.reset()
        XCTAssertTrue(bar.admitsSwipe(down, Touch(on: text, at: 10)))
        XCTAssertTrue(down.editor === field)
        field.selectionMovedAt = 9
        XCTAssertTrue(bar.swipeMayBegin(down), "moved before the contact")
        field.selectionMovedAt = 11
        XCTAssertFalse(bar.swipeMayBegin(down), "moved during the contact: the editor's")
    }
}
#endif
