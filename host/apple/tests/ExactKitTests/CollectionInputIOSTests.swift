#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// Collection corrections and reader input through the UIKit host. Request
/// cancellation follows LLP 1070.000 §2.5; scripted scrolls retain §2.6's
/// authored exceptions.
final class CollectionInputIOSTests: XCTestCase {
    /// A list with an optional waiting request.
    private func list(horizontal: Bool = false, waiting: Bool = true) -> Presenter {
        let p = Presenter()
        p.apply(wireBatch([["op": "collections", "items": [["view": 1, "revision": 1, "scrollSequence": 0, "count": 50, "totalExtent": 2000,
                "axis": horizontal ? "x" : "y", "rows": [["view": 10, "root": 10, "epoch": 1]], "correction": NSNull(), "waiting": waiting,
                "request": waiting ? 1 : 0, "lastRequest": waiting ? 1 : 0]]],
            ["op": "create", "id": 1, "kind": "list", "style": [horizontal ? "overflow_x" : "overflow_y": "scroll"]],
            ["op": "create", "id": 10, "kind": "view"],
            ["op": "children", "id": 1, "ids": [10]], ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 300.0],
            ["op": "frame", "id": 10, "x": 0.0, "y": 0.0, "w": 300.0, "h": 40.0],
            ["op": "content", "id": 1, "w": horizontal ? 2000.0 : 300.0, "h": horizontal ? 300.0 : 2000.0]]))
        return p
    }

    private func correction(_ revision: Int, sequence: UInt64, offset: Double, horizontal: Bool, authored: Bool = false, smooth: Bool = false, from: Double? = nil) -> Batch {
        var correction: [String: Any] = ["scrollSequence": String(sequence), "offset": offset, "smooth": smooth]
        if let from { correction["from"] = from }
        return wireBatch([["op": "collections", "items": [["view": 1, "revision": revision, "scrollSequence": String(sequence), "axis": horizontal ? "x" : "y",
            "count": 50, "totalExtent": 2000, "rows": [["view": 10, "root": 10, "epoch": 1]], "correction": correction,
            "seeking": authored, "request": authored ? revision : 0, "lastRequest": authored ? revision : 0]]]])
    }

    /// Replace the node's settable scroller, keeping its rows and delegate.
    /// The subclass supplies input flags, inset changes and the stop callback.
    private func scroller(_ p: Presenter, horizontal: Bool, at offset: CGFloat = 600) throws -> InputScroll {
        let node = try XCTUnwrap(p.views[1]), old = try XCTUnwrap(node.scroll)
        let scroll = InputScroll(frame: old.frame)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.scrollsX = horizontal; scroll.scrollsY = !horizontal
        scroll.contentSize = old.contentSize
        for row in old.subviews where row is NodeView { scroll.addSubview(row) }
        old.removeFromSuperview(); node.addSubview(scroll); node.scroll = scroll
        scroll.delegate = node
        scroll.contentOffset = horizontal ? CGPoint(x: offset, y: 0) : CGPoint(x: 0, y: offset)
        scroll.writes.removeAll()
        return scroll
    }

    func testAnOwedAbsoluteIntentStopsAFlingDespiteItsLaterTravel() throws {
        for horizontal in [false, true] {
            let p = list(horizontal: horizontal, waiting: false)
            defer { p.reset() }
            let scroll = try scroller(p, horizontal: horizontal), entry = try XCTUnwrap(p.collections.entries[1])
            let node = try XCTUnwrap(p.views[1])
            node.scrollViewDidScroll(scroll)
            p.collections.userIntent(1, travel: true)
            let began = entry.cursor.sequence
            scroll.simulatedDecelerating = true
            scroll.delegate = nil
            scroll.contentOffset = horizontal ? CGPoint(x: 620, y: 0) : CGPoint(x: 0, y: 620)
            scroll.delegate = node
            node.scrollViewDidScroll(scroll)
            let travelled = entry.cursor.sequence
            XCTAssertGreaterThan(travelled, began)
            XCTAssertNotEqual(p.scrollPump.velocity(1), 0, "the pump sampled the fling before the intent")
            p.apply(correction(2, sequence: began, offset: 1200, horizontal: horizontal))
            XCTAssertFalse(scroll.isDecelerating, "a new intent stops the fling even after another travel report")
            XCTAssertEqual(scroll.writes, [horizontal ? CGPoint(x: 620, y: 0) : CGPoint(x: 0, y: 620)], "stopped where it was")
            XCTAssertNil(p.collections.motion?(1), "the stopped fling's sampled travel cannot cancel a later correction")
            p.apply(correction(3, sequence: travelled, offset: 1200, horizontal: horizontal))
            XCTAssertEqual(horizontal ? scroll.contentOffset.x : scroll.contentOffset.y, 1200, accuracy: 0.5, "the next report's correction lands")
            scroll.writes.removeAll(); scroll.simulatedDecelerating = true
            p.apply(correction(3, sequence: travelled, offset: 1200, horizontal: horizontal))
            XCTAssertTrue(scroll.isDecelerating, "an already consumed revision cannot stop another fling")
            XCTAssertTrue(scroll.writes.isEmpty)
        }
    }

    func testEarlierCorrectionsAndTrackingLeaveTheFlingButAuthoredRequestsStillLand() throws {
        for horizontal in [false, true] {
            let p = list(horizontal: horizontal, waiting: false)
            defer { p.reset() }
            let scroll = try scroller(p, horizontal: horizontal), entry = try XCTUnwrap(p.collections.entries[1])
            let earlier = entry.cursor.sequence
            p.collections.userIntent(1, travel: true)
            let began = entry.cursor.sequence
            scroll.simulatedDecelerating = true
            p.apply(correction(2, sequence: earlier, offset: 1200, horizontal: horizontal))
            XCTAssertTrue(scroll.isDecelerating, "the reader overrode the earlier correction")
            XCTAssertTrue(scroll.writes.isEmpty)
            scroll.simulatedTracking = true
            p.apply(correction(3, sequence: began, offset: 1200, horizontal: horizontal))
            XCTAssertTrue(scroll.writes.isEmpty, "an ordinary correction leaves the tracking finger alone")
            p.apply(correction(4, sequence: earlier, offset: 1200, horizontal: horizontal, authored: true, smooth: true))
            XCTAssertEqual(horizontal ? scroll.contentOffset.x : scroll.contentOffset.y, 1200, accuracy: 0.5, "an authored request lands under the finger, at an older sequence too")
            XCTAssertFalse(p.collections.animating.contains(1), "a smooth request lands at once under a dragging finger")
            scroll.simulatedTracking = false; scroll.simulatedDecelerating = true; scroll.writes.removeAll()
            p.apply(correction(5, sequence: began, offset: 1500, horizontal: horizontal, authored: true))
            XCTAssertEqual(scroll.writes.count, 2, "the fling stops, then the authored correction lands")
            XCTAssertFalse(entry.gesture, "the stop's native callback is not a reader's gesture, even in a snapshot-only batch")
            XCTAssertEqual(horizontal ? scroll.contentOffset.x : scroll.contentOffset.y, 1500, accuracy: 0.5)
        }
    }

    func testTheSameEdgeRubberBandAndRelativeCorrectionsKeepDecelerating() throws {
        for horizontal in [false, true] {
            for (start, edge) in [(CGFloat(-60), 0.0), (1800, 1700)] {
                let p = list(horizontal: horizontal, waiting: false)
                defer { p.reset() }
                let scroll = try scroller(p, horizontal: horizontal, at: start)
                p.collections.userIntent(1, travel: true)
                let sequence = try XCTUnwrap(p.collections.entries[1]).cursor.sequence
                scroll.simulatedDecelerating = true
                p.apply(correction(2, sequence: sequence, offset: edge, horizontal: horizontal))
                XCTAssertTrue(scroll.isDecelerating, "the platform returns the rubber band to this edge")
                XCTAssertTrue(scroll.writes.isEmpty)
                p.apply(correction(3, sequence: sequence, offset: 1000, horizontal: horizontal))
                XCTAssertFalse(scroll.isDecelerating, "an intent toward a different position stops it")
                XCTAssertEqual(horizontal ? scroll.contentOffset.x : scroll.contentOffset.y, 1000, accuracy: 0.5)
            }
            let p = list(horizontal: horizontal, waiting: false)
            defer { p.reset() }
            let scroll = try scroller(p, horizontal: horizontal)
            p.collections.userIntent(1, travel: true)
            let sequence = try XCTUnwrap(p.collections.entries[1]).cursor.sequence
            scroll.simulatedDecelerating = true
            p.apply(correction(2, sequence: sequence, offset: 650, horizontal: horizontal, from: 600))
            XCTAssertTrue(scroll.isDecelerating, "an anchor moves with the fling")
            XCTAssertTrue(scroll.writes.isEmpty, "the relative assignment never stops momentum")
            XCTAssertEqual(horizontal ? scroll.contentOffset.x : scroll.contentOffset.y, 650, accuracy: 0.5)
        }
    }

    func testTopInsetsCompensateCollectionsAndBottomInsetsRequireEndAnchoring() throws {
        let anchors: [[String: String]] = [[:], ["scrollFollowEnd": "true"], ["scrollStart": "end"]]
        for horizontal in [false, true] {
            for props in anchors {
                let p = list(horizontal: horizontal)
                defer { p.reset() }
                p.apply(wireBatch([["op": "props", "id": 1, "set": props]]))
                let scroll = try scroller(p, horizontal: horizontal, at: 1700)
                scroll.overlay = UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0)
                scroll.contentOffset.y -= 60 // UIKit's compensation before its inset callback
                scroll.adjustedContentInsetDidChange()
                XCTAssertEqual(scroll.contentOffset.y, horizontal ? -60 : 1700, accuracy: 0.5, "a mounted vertical collection compensates for the top inset without end-anchor props")
                if horizontal { XCTAssertEqual(scroll.contentOffset.x, 1700, accuracy: 0.5) }
                scroll.overlay = UIEdgeInsets(top: 60, left: 0, bottom: 40, right: 0)
                scroll.adjustedContentInsetDidChange()
                let anchored = !horizontal && !props.isEmpty
                XCTAssertEqual(scroll.contentOffset.y, anchored ? 1740 : horizontal ? -60 : 1700, accuracy: 0.5, "a bottom inset still requires an authored end anchor")
            }
        }
        for offset: CGFloat in [0, 600] {
            let p = list()
            defer { p.reset() }
            p.apply(wireBatch([["op": "props", "id": 1, "set": ["scrollFollowEnd": "true"]]]))
            let scroll = try scroller(p, horizontal: false, at: offset)
            scroll.overlay = UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0)
            scroll.contentOffset.y -= 60
            scroll.adjustedContentInsetDidChange()
            XCTAssertEqual(scroll.contentOffset.y, offset - 60, accuracy: 0.5, "an initial or reader offset away from the end keeps UIKit's compensation")
        }
    }

    func testAMountedCollectionWithoutEndAnchorPropsCompensatesTopInsets() throws {
        let p = list(waiting: false)
        defer { p.reset() }
        let node = try XCTUnwrap(p.views[1])
        XCTAssertNil(node.props["scrollStart"])
        XCTAssertNil(node.props["scrollFollowEnd"])
        XCTAssertNotNil(p.collections.entries[1])
        let scroll = try scroller(p, horizontal: false, at: 1700)
        scroll.overlay = UIEdgeInsets(top: 60, left: 0, bottom: 0, right: 0)
        scroll.contentOffset.y -= 60
        scroll.adjustedContentInsetDidChange()
        XCTAssertEqual(scroll.contentOffset.y, 1700, accuracy: 0.5, "a collection at its end compensates outside a presenter batch")
        scroll.overlay = .zero
        scroll.contentOffset.y += 60
        scroll.adjustedContentInsetDidChange()
        XCTAssertEqual(scroll.contentOffset.y, 1700, accuracy: 0.5, "the top inset going away also keeps the end")
        scroll.overlay = UIEdgeInsets(top: 0, left: 0, bottom: 40, right: 0)
        scroll.adjustedContentInsetDidChange()
        XCTAssertEqual(scroll.contentOffset.y, 1700, accuracy: 0.5, "collection membership alone does not enable bottom anchoring")
    }

    private final class InputScroll: ScrollView {
        var simulatedTracking = false, simulatedDecelerating = false
        var overlay: UIEdgeInsets?
        var writes: [CGPoint] = []
        override var isTracking: Bool { simulatedTracking }
        override var isDragging: Bool { simulatedTracking || simulatedDecelerating }
        override var isDecelerating: Bool { simulatedDecelerating }
        override var adjustedContentInset: UIEdgeInsets { overlay ?? super.adjustedContentInset }
        override func setContentOffset(_ point: CGPoint, animated: Bool) {
            writes.append(point)
            if !animated { simulatedDecelerating = false }
            super.setContentOffset(point, animated: animated)
            delegate?.scrollViewDidScroll?(self)
        }
    }

    func testAnInputCountsAgainstTheRequestUnderWayWhenItBegan() throws {
        let p = list()
        defer { p.collections.reset() }
        let requestAt = try XCTUnwrap(p.collections.entries[1]).requestAt
        p.collections.gestureBegan(1, at: requestAt - 0.01)
        XCTAssertFalse(try XCTUnwrap(p.collections.entries[1]).gesture, "a touch that began before the request")
        p.collections.gestureBegan(1, at: requestAt + 0.01)
        XCTAssertTrue(try XCTUnwrap(p.collections.entries[1]).gesture, "one that began after it")
    }

    /// The selected tab tapped again scrolls its screen's list to the top:
    /// the reader's move, which ends a request made before the tap, and
    /// gives way to any the tab's press made in answer, under way or ended.
    func testAScrollToTheTopGivesWayToARequestTheTabsPressMade() throws {
        let p = list()
        defer { p.collections.reset() }
        let entry = try XCTUnwrap(p.collections.entries[1]), scroll = try XCTUnwrap(p.views[1]?.scroll)
        let route = RouteController(try XCTUnwrap(p.views[1]))
        p.navigation.scrollsToTopAnimated = false
        scroll.contentOffset.y = 600
        p.navigation.scrollToTop(route, since: [1: 0])
        XCTAssertFalse(entry.gesture, "a request the press made, under way, is its answer to the tap")
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5, "which the scroll to the top gives way to")
        p.navigation.scrollToTop(route, since: [:])
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5, "as to one in a list the press made")
        // The next press's request was `done` at once: the port already showed its row.
        p.apply(wireBatch([["op": "collections", "items": [["view": 1, "revision": 2, "scrollSequence": 0, "count": 50, "totalExtent": 2000,
            "rows": [["view": 10, "root": 10, "epoch": 1]], "correction": NSNull(), "lastRequest": 2]]]]))
        p.navigation.scrollToTop(route, since: [1: 1])
        XCTAssertEqual(scroll.contentOffset.y, 600, accuracy: 0.5, "and so is one done at once, its row already shown")
        // A press that asked for nothing: the request under way is from before the tap.
        p.apply(wireBatch([["op": "collections", "items": [["view": 1, "revision": 3, "scrollSequence": 0, "count": 50, "totalExtent": 2000,
            "rows": [["view": 10, "root": 10, "epoch": 1]], "correction": NSNull(), "waiting": true, "request": 3, "lastRequest": 3]]]]))
        p.navigation.scrollToTop(route, since: [1: 3])
        XCTAssertTrue(entry.gesture, "a request made before the tap ends")
        XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top, accuracy: 0.5, "and the list goes to its top")
    }

    /// A finger coming down on a list while its request is under way is the
    /// reader's gesture against it, heard by the host's contact recognizer
    /// (LLP 1070.000 §2.6); one beside the list is not.
    func testAFingerComingDownOnTheListIsTheReadersGesture() throws {
        let p = list()
        defer { p.collections.reset() }
        let contact = p.collections.watchContacts(in: p.viewport)
        defer { p.viewport.removeGestureRecognizer(contact) }
        let after = try XCTUnwrap(p.collections.entries[1]).requestAt + 0.01
        let beside = Touch(p.viewport, at: after), onRow = Touch(try XCTUnwrap(p.views[10]), at: after)
        contact.touchesBegan([beside], with: UIEvent())
        XCTAssertFalse(try XCTUnwrap(p.collections.entries[1]).gesture, "beside the list")
        contact.touchesEnded([beside], with: UIEvent())
        contact.touchesBegan([onRow], with: UIEvent())
        XCTAssertTrue(try XCTUnwrap(p.collections.entries[1]).gesture, "on its row")
    }

    private final class Touch: UITouch {
        let target: UIView, time: TimeInterval
        init(_ target: UIView, at time: TimeInterval) { self.target = target; self.time = time; super.init() }
        override var view: UIView? { target }
        override var timestamp: TimeInterval { time }
    }
}
#endif
