#if os(macOS)
import AppKit
import XCTest
@testable import ExactKit

/// CSS UI 4 §6.1 `user-select` over macOS's paragraph selection (LLP 1033):
/// `auto` is `text` at the root, as on the web; `none` is left out of a
/// selection extending across it and starts none; a selection started in a
/// `contain` box stays in it; touching an `all` box selects it whole.
final class UserSelectMacTests: XCTestCase {
    private var presenter: Presenter!
    private var y: CGFloat = 0

    override func setUp() {
        presenter = Presenter()
        presenter.root.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        y = 0
    }
    private func box(_ id: UInt32, _ userSelect: String? = nil, in parent: NSView? = nil) -> NodeView {
        let node = NodeView(id: id, kind: "view", presenter: presenter)
        if let userSelect { node.applyStyle(["user_select": .string(userSelect)]) }
        node.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        (parent.map { ($0 as? NodeView)?.container ?? $0 } ?? presenter.root).addSubview(node)
        presenter.views[id] = node
        return node
    }
    private func paragraph(_ id: UInt32, _ text: String, _ userSelect: String? = nil, in parent: NSView) -> NodeView {
        let node = NodeView(id: id, kind: "text", presenter: presenter)
        node.applyProps(set: ["text": text], clear: [])
        if let userSelect { node.applyStyle(["user_select": .string(userSelect)]) }
        let local = parent.convert(NSPoint(x: 0, y: y), from: presenter.root)
        node.frame = NSRect(x: 0, y: local.y, width: 200, height: 20)
        y += 30
        ((parent as? NodeView)?.container ?? parent).addSubview(node)
        presenter.views[id] = node
        return node
    }
    private func event(_ type: NSEvent.EventType, at node: NodeView, x: CGFloat = 1, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: node.convert(NSPoint(x: x, y: 10), to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func testNoneIsLeftOutAndStartsNoSelection() throws {
        let root = box(1)
        let a = paragraph(2, "alpha", in: root)
        let b = paragraph(3, "badge", "none", in: root)
        let c = paragraph(4, "gamma", in: root)
        presenter.selection.selectAll()
        XCTAssertEqual(presenter.selection.selectedText(), "alpha\n\ngamma")
        XCTAssertNil(presenter.selection.range(b))
        // A press in `none` neither starts a selection nor clears this one.
        presenter.selection.begin(b, event: event(.leftMouseDown, at: b))
        XCTAssertEqual(presenter.selection.selectedText(), "alpha\n\ngamma")
        XCTAssertNotNil(presenter.selection.range(a))
        XCTAssertNotNil(presenter.selection.range(c))
    }

    func testSelectableTextInsideNoneIsKept() throws {
        let root = box(1)
        let none = box(2, "none", in: root)
        _ = paragraph(3, "hidden", in: none)
        let kept = paragraph(4, "kept", "text", in: none)
        presenter.selection.selectAll()
        XCTAssertEqual(presenter.selection.selectedText(), "kept")
        XCTAssertEqual(presenter.selection.range(kept), NSRange(location: 0, length: 4))
    }

    func testASelectionStartedInContainStaysInIt() throws {
        let root = box(1)
        let outside = paragraph(2, "outside", in: root)
        let contain = box(3, "contain", in: root)
        let inside = paragraph(4, "inside", in: contain)
        let alsoInside = paragraph(5, "also", in: contain)
        presenter.selection.begin(inside, event: event(.leftMouseDown, at: inside))
        presenter.selection.drag(event(.leftMouseDragged, at: outside, x: 50))
        XCTAssertNil(presenter.selection.range(outside), "it does not extend outside")
        presenter.selection.drag(event(.leftMouseDragged, at: alsoInside, x: 20))
        XCTAssertNotNil(presenter.selection.range(alsoInside))
        // Started outside, it does not end inside.
        presenter.selection.begin(outside, event: event(.leftMouseDown, at: outside))
        presenter.selection.drag(event(.leftMouseDragged, at: alsoInside, x: 20))
        XCTAssertNil(presenter.selection.range(alsoInside))
    }

    func testTouchingAnAllBoxSelectsItWhole() throws {
        let root = box(1)
        let all = box(2, "all", in: root)
        let first = paragraph(3, "first", in: all)
        let second = paragraph(4, "second", in: all)
        // A double click selects a word of the first paragraph: part of the box.
        presenter.selection.begin(first, event: event(.leftMouseDown, at: first, clicks: 2))
        XCTAssertEqual(presenter.selection.range(first), NSRange(location: 0, length: 5))
        XCTAssertEqual(presenter.selection.range(second), NSRange(location: 0, length: 6))
        XCTAssertEqual(presenter.selection.selectedText(), "first\n\nsecond")
    }
}
#endif
