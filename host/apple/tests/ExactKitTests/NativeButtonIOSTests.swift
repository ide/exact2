#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// Every button is a UIButton (NativeButtonIOS); `-exact-apple-button-style`
/// draws it in a system style from its text and symbol; and
/// `-exact-apple-glass-container` groups descendants' glass.
///   bun host/apple/build.mjs --test --ios
final class NativeButtonIOSTests: XCTestCase {
    private var window: UIWindow!

    private func presenter(_ ops: [[String: Any]]) -> Presenter {
        let p = Presenter()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        p.apply(wireBatch(ops))
        return p
    }

    private func button(_ v: NodeView) -> NativeButton? { v.subviews.compactMap { $0 as? NativeButton }.first }

    func testAButtonIsAUIButtonThatPressesItsNode() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "button", "handlers": ["press"], "props": ["testId": "go"]],
            ["op": "create", "id": 2, "kind": "text", "props": ["text": "Go"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 120.0, "h": 44.0],
        ])
        let b = try XCTUnwrap(button(try XCTUnwrap(p.views[1])))
        XCTAssertEqual(b.frame, CGRect(x: 0, y: 0, width: 120, height: 44))
        XCTAssertEqual(b.accessibilityIdentifier, "go")
        XCTAssertNil(b.configuration, "an author-styled button keeps its boxes")
        XCTAssertFalse(try XCTUnwrap(p.views[2]).isHidden)
    }

    func testAStyledButtonIsDrawnByItsConfigurationFromItsText() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "button", "handlers": ["press"], "style": ["exact_apple_button_style": "filled"]],
            ["op": "create", "id": 2, "kind": "text", "props": ["text": "Save"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 120.0, "h": 44.0],
        ])
        let b = try XCTUnwrap(button(try XCTUnwrap(p.views[1])))
        XCTAssertEqual(b.configuration?.title, "Save")
        XCTAssertTrue(try XCTUnwrap(p.views[2]).isHidden, "the configuration draws the title")
    }

    func testADisabledButtonIsADisabledUIButton() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "button", "handlers": ["press"], "props": ["disabled": "true"]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 120.0, "h": 44.0],
        ])
        XCTAssertFalse(try XCTUnwrap(button(try XCTUnwrap(p.views[1]))).isEnabled)
    }

    func testAGlassContainerHoldsItsChildrenInOneGroup() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Liquid Glass") }
        let p = presenter([
            ["op": "create", "id": 1, "kind": "view", "style": ["exact_apple_glass_container": 8.0]],
            // A button: a childless plain box would be a flat leaf, not a view.
            ["op": "create", "id": 2, "kind": "button", "handlers": ["press"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 80.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 100.0, "h": 80.0],
        ])
        let row = try XCTUnwrap(p.views[1]), child = try XCTUnwrap(p.views[2])
        let effect = try XCTUnwrap(row.materialView)
        XCTAssertEqual(row.materialKind, Materials.containerKind)
        XCTAssertNotNil(effect.effect, "a UIGlassContainerEffect (UIKit hands back its own copy)")
        XCTAssertTrue(child.superview === effect.contentView)
    }

    func testAnAutoGlassContainerMergesAcrossItsOwnGap() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Liquid Glass") }
        let p = presenter([
            ["op": "create", "id": 1, "kind": "view", "style": ["exact_apple_glass_container": Double(Materials.containerAuto)]],
            ["op": "create", "id": 2, "kind": "button", "handlers": ["press"]],
            ["op": "create", "id": 3, "kind": "button", "handlers": ["press"]],
            ["op": "children", "id": 1, "ids": [2, 3]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 80.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 100.0, "h": 80.0],
            ["op": "frame", "id": 3, "x": 108.0, "y": 0.0, "w": 100.0, "h": 80.0],
        ])
        let row = try XCTUnwrap(p.views[1])
        XCTAssertEqual(row.materialKind, Materials.containerKind)
        XCTAssertEqual(row.glassGroupSpacing, 8, accuracy: 0.001)
    }

    func testAPopoverOfContentIsUIKitsPopoverAndOneOfRowsIsAMenu() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "view"],
            ["op": "create", "id": 2, "kind": "button", "props": ["popovertarget": "tip"]],
            ["op": "create", "id": 3, "kind": "view", "props": ["id": "tip", "popover": "auto"]],
            ["op": "create", "id": 4, "kind": "text", "props": ["text": "Oct 2 at 9:41 PM"]],
            ["op": "create", "id": 5, "kind": "button", "props": ["popovertarget": "menu"]],
            ["op": "create", "id": 6, "kind": "view", "props": ["id": "menu", "popover": "auto"]],
            ["op": "create", "id": 7, "kind": "button", "handlers": ["press"], "props": ["popovertarget": "menu", "popovertargetaction": "hide"]],
            ["op": "children", "id": 3, "ids": [4]],
            ["op": "children", "id": 6, "ids": [7]],
            ["op": "children", "id": 1, "ids": [2, 3, 5, 6]],
            ["op": "roots", "ids": [1]],
        ])
        let tip = try XCTUnwrap(p.views[2]), menu = try XCTUnwrap(p.views[5])
        XCTAssertTrue(p.menus.contentPopover(invokedBy: tip) === p.views[3])
        XCTAssertTrue(tip.invokesConfirmation, "its invoker is pressable as itself")
        XCTAssertNil(p.menus.contentPopover(invokedBy: menu), "a popover of pressing rows is a menu")
    }

    func testUserSelectTextOffersCopyOfTheWholeText() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "view", "style": ["user_select": "text"]],
            ["op": "create", "id": 2, "kind": "text", "props": ["text": "Order 1042"]],
            ["op": "create", "id": 3, "kind": "text", "props": ["text": "Plain"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1, 3]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 40.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 300.0, "h": 40.0],
            ["op": "frame", "id": 3, "x": 0.0, "y": 50.0, "w": 300.0, "h": 40.0],
        ])
        let box = try XCTUnwrap(p.views[1]), plain = try XCTUnwrap(p.views[3])
        let copy = try XCTUnwrap(box.textCopy)
        XCTAssertTrue(box.interactions.contains { $0 === copy.menu })
        XCTAssertEqual(TextCopy.text(of: box), "Order 1042")
        XCTAssertEqual(box.accessibilityCustomActions?.count, 1, "VoiceOver can copy too")
        XCTAssertNil(plain.textCopy, "auto: a label is not copyable")
        p.apply(wireBatch([["op": "style", "id": 1, "style": ["user_select": "auto"]]]))
        XCTAssertNil(box.textCopy)
        XCTAssertNil(box.accessibilityCustomActions)
        XCTAssertFalse(box.interactions.contains { $0 is UIEditMenuInteraction })
    }
}
#endif
