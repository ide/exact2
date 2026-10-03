#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// CSS UI 4 §6.1 `user-select` on iOS: the spec's used values, with Exact's
/// iOS UA sheet making the root's parent `none` (LLP 1001). A box that starts
/// a selectable region offers Copy on a long press for the region's text.
final class UserSelectIOSTests: XCTestCase {
    private var window: UIWindow!

    private func presenter(_ ops: [[String: Any]]) -> Presenter {
        let p = Presenter()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        p.apply(wireBatch(ops))
        return p
    }
    private func text(_ id: Int, _ s: String, style: [String: Any] = [:]) -> [String: Any] {
        ["op": "create", "id": id, "kind": "text", "props": ["text": s], "style": style]
    }
    private func view(_ id: Int, _ style: [String: Any] = [:], handlers: [String] = []) -> [String: Any] {
        ["op": "create", "id": id, "kind": "view", "style": style, "handlers": handlers]
    }

    func testUsedValuesFollowTheSpec() throws {
        let p = presenter([
            // Leaves are paragraphs: an empty box may be drawn as a layer, no view.
            view(1, ["user_select": "text"]), text(2, "a"), view(3, ["user_select": "none"]), text(4, "b"),
            view(5, ["user_select": "all"]), text(6, "c"),
            ["op": "create", "id": 7, "kind": "input"],
            ["op": "children", "id": 1, "ids": [2, 3, 5]], ["op": "children", "id": 3, "ids": [4]],
            ["op": "children", "id": 5, "ids": [6, 7]],
            text(8, "d"),
            ["op": "roots", "ids": [1, 8]],
        ])
        func used(_ id: UInt32) throws -> String { try XCTUnwrap(p.views[id]).userSelect }
        XCTAssertEqual(try used(8), "none", "auto under the UA sheet's none: nothing selectable by default")
        XCTAssertEqual(try used(1), "text")
        XCTAssertEqual(try used(2), "text", "auto under text is text")
        XCTAssertEqual(try used(3), "none")
        XCTAssertEqual(try used(4), "none", "auto under none is none")
        XCTAssertEqual(try used(6), "all", "auto under all is all")
        XCTAssertEqual(try used(7), "contain", "an editable element is always contain")
    }

    func testARegionsStartOffersCopyOfItsText() throws {
        let p = presenter([
            view(1, ["user_select": "text"]), text(2, "Order 1042"), text(3, "Plain"),
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1, 3]],
        ])
        let box = try XCTUnwrap(p.views[1]), plain = try XCTUnwrap(p.views[3])
        let copy = try XCTUnwrap(box.textCopy)
        XCTAssertTrue(box.interactions.contains { $0 === copy.menu })
        XCTAssertEqual(TextCopy.text(of: box), "Order 1042")
        XCTAssertEqual(box.accessibilityCustomActions?.count, 1, "VoiceOver can copy too")
        XCTAssertNil(plain.textCopy, "auto under the root: not selectable")
        XCTAssertNil(p.views[2]?.textCopy, "auto inside a region continues it; it starts none")
        p.apply(wireBatch([["op": "style", "id": 1, "style": ["user_select": "auto"]]]))
        XCTAssertNil(box.textCopy)
        XCTAssertNil(box.accessibilityCustomActions)
        XCTAssertFalse(box.interactions.contains { $0 is UIEditMenuInteraction })
        p.apply(wireBatch([["op": "style", "id": 1, "style": ["user_select": "contain"]]]))
        XCTAssertNotNil(box.textCopy, "contain is selectable inside")
    }

    func testNoneIsLeftOutButItsSelectableDescendantsAreNot() throws {
        let p = presenter([
            view(1, ["user_select": "text"]), text(2, "Model"), view(3, ["user_select": "none"]),
            text(4, "decoration"), text(5, "IS 350", style: ["user_select": "text"]), text(6, "2026"),
            ["op": "children", "id": 3, "ids": [4, 5]],
            ["op": "children", "id": 1, "ids": [2, 3, 6]],
            ["op": "roots", "ids": [1]],
        ])
        let box = try XCTUnwrap(p.views[1])
        XCTAssertEqual(TextCopy.text(of: box), "Model IS 350 2026")
        XCTAssertNotNil(p.views[5]?.textCopy, "text inside none starts a region of its own")
        XCTAssertEqual(TextCopy.text(of: try XCTUnwrap(p.views[5])), "IS 350")
    }

    func testAllIsSelectedWholeFromItsOutermostBox() throws {
        let p = presenter([
            view(1, ["user_select": "all"]), view(2, ["user_select": "all"]), text(3, "a"),
            view(4, ["user_select": "text"]), text(5, "b"),
            ["op": "children", "id": 2, "ids": [3]], ["op": "children", "id": 4, "ids": [5]],
            ["op": "children", "id": 1, "ids": [2, 4]],
            ["op": "roots", "ids": [1]],
        ])
        XCTAssertNotNil(p.views[1]?.textCopy)
        XCTAssertNil(p.views[2]?.textCopy, "an all inside an all is selected with it")
        XCTAssertNotNil(p.views[4]?.textCopy, "a text inside an all may be selected alone")
        XCTAssertEqual(TextCopy.text(of: try XCTUnwrap(p.views[1])), "a b")
    }

    func testEditableElementsKeepTheirOwnSelection() throws {
        let p = presenter([
            view(1, ["user_select": "text"]),
            ["op": "create", "id": 2, "kind": "input", "style": ["user_select": "text"], "props": ["value": "hello"]],
            ["op": "create", "id": 3, "kind": "input", "props": ["type": "password", "value": "secret"]],
            ["op": "children", "id": 1, "ids": [2, 3]],
            ["op": "roots", "ids": [1]],
        ])
        XCTAssertNil(p.views[2]?.textCopy, "a field's used value is contain; it keeps its own selection")
        XCTAssertNil(p.views[3]?.textCopy)
        let copied = TextCopy.text(of: try XCTUnwrap(p.views[1]))
        XCTAssertFalse(copied.contains("secret"), "a secure field's text is never copied")
    }

    func testAContextMenuOwnsTheLongPressAndReleaseRemovesTheMenu() throws {
        let p = presenter([
            view(1, ["user_select": "text"]), text(2, "x"),
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
        ])
        let box = try XCTUnwrap(p.views[1])
        XCTAssertTrue(box.textCopy?.press.delegate === box, "the node's own arbitration")
        box.handlers = ["contextmenu"]
        TextCopy.sync(p)
        XCTAssertNil(box.textCopy)
        box.handlers = []
        TextCopy.sync(p)
        XCTAssertNotNil(box.textCopy)
        p.release(1) { _ in }
        XCTAssertTrue(p.copyNodes.isEmpty)
        XCTAssertNil(box.textCopy)
    }
}
#endif
