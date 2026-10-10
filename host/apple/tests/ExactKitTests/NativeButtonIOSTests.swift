#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// Every button is a UIButton (NativeButtonIOS); `-exact-apple-button-style`
/// draws it in a system style from its text and symbol.
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

    /// A small button's title and symbol are UIKit's small ones under the
    /// document root's font size, which reaches every text that inherits it
    /// and is no size the author wrote; a size of their own wins, the root's
    /// included (`font_written`).
    func testASmallButtonsTitleKeepsUIKitsFontUnderTheRootsSize() throws {
        let root = PageFacts.rootFontSize
        let p = presenter([
            ["op": "create", "id": 1, "kind": "button", "handlers": ["press"], "style": ["exact_apple_button_style": "gray", "exact_apple_button_size": "small"]],
            ["op": "create", "id": 2, "kind": "image", "props": ["imageSource": "symbol:sf/lock.fill", "symbolName": "lock.fill"], "style": ["font_size": root]],
            ["op": "create", "id": 3, "kind": "text", "props": ["text": "Defrost"], "style": ["font_size": root]],
            ["op": "children", "id": 1, "ids": [2, 3]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 160.0, "h": 36.0],
        ])
        let b = try XCTUnwrap(button(try XCTUnwrap(p.views[1])))
        let small = NativeButton.titleFont(.small, traits: b.traitCollection)
        XCTAssertNil(b.configuration?.titleTextAttributesTransformer, "UIKit's small title font, not the root's \(root) pt")
        XCTAssertEqual(b.configuration?.preferredSymbolConfigurationForImage, UIImage.SymbolConfiguration(font: NativeButton.titleFont(.medium, traits: b.traitCollection), scale: .small))
        XCTAssertLessThan(small.pointSize, root)
        p.apply(wireBatch([
            ["op": "style", "id": 3, "style": ["font_size": 13.0, "font_written": 1.0]],
            ["op": "style", "id": 2, "style": ["font_size": root, "font_written": 1.0]],
        ]))
        let written = b.configuration?.titleTextAttributesTransformer?(AttributeContainer())
        XCTAssertEqual(written?.uiKit.font?.pointSize, 13, "a size of its own wins")
        XCTAssertEqual(b.configuration?.preferredSymbolConfigurationForImage, UIImage.SymbolConfiguration(pointSize: root, weight: .regular),
                       "a symbol's own size wins, the root's too")
    }

    func testAStyledButtonKeepsItsContentWhereTheBoxesStand() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "button", "handlers": ["press"], "style": ["exact_apple_button_style": "plain"]],
            ["op": "create", "id": 2, "kind": "text", "props": ["text": "Check"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 44.0],
            ["op": "frame", "id": 2, "x": 16.0, "y": 12.0, "w": 60.0, "h": 20.0],
        ])
        let b = try XCTUnwrap(button(try XCTUnwrap(p.views[1])))
        XCTAssertEqual(b.contentHorizontalAlignment, .left)
        XCTAssertEqual(b.configuration?.contentInsets.leading, 16)
        XCTAssertEqual(NativeButton.horizontal([CGRect(x: 120, y: 0, width: 60, height: 20)], in: 300).0, .center)
        XCTAssertEqual(NativeButton.horizontal([CGRect(x: 16, y: 0, width: 60, height: 20)], in: 300, rtl: true).1.trailing, 16)
    }

    /// A symbol and a title are UIKit's pairing: the author's flex-direction
    /// is the placement and the gap the padding, from the first
    /// configuration on, before any box is laid out (Lock's icon over its
    /// label, Last Parked's beside it).
    func testASymbolAndTitleStandAsTheFlexDirectionAndGapSay() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "button", "handlers": ["press"],
             "style": ["exact_apple_button_style": "filled", "button_content_direction": "column", "button_content_gap": 4]],
            ["op": "create", "id": 2, "kind": "image", "props": ["imageSource": "symbol:sf/lock.fill", "symbolName": "lock.fill"], "style": ["font_size": 20.0]],
            ["op": "create", "id": 3, "kind": "text", "props": ["text": "Lock"]],
            ["op": "children", "id": 1, "ids": [2, 3]],
            ["op": "roots", "ids": [1]],
        ])
        let b = try XCTUnwrap(button(try XCTUnwrap(p.views[1])))
        XCTAssertEqual(b.configuration?.imagePlacement, .top)
        XCTAssertEqual(b.configuration?.imagePadding, 4)
        p.apply(wireBatch([["op": "style", "id": 1, "style": ["exact_apple_button_style": "filled", "button_content_direction": "row-reverse", "button_content_gap": 8]]]))
        XCTAssertEqual(b.configuration?.imagePlacement, .trailing)
        XCTAssertEqual(b.configuration?.imagePadding, 8)
        // No gap written: the platform's system spacing between them, read
        // from UIKit's layout (a configuration's own default is none).
        p.apply(wireBatch([["op": "style", "id": 1, "style": ["exact_apple_button_style": "filled", "button_content_direction": "row"]]]))
        XCTAssertEqual(b.configuration?.imagePlacement, .leading)
        let font = UIFont.systemFont(ofSize: 17, weight: .regular)
        XCTAssertEqual(b.configuration?.imagePadding, NativeButton.systemSpacing(stacked: false, image: b.configuration?.image, font: font))
        XCTAssertGreaterThan(b.configuration?.imagePadding ?? 0, 0)
    }

    func testTheRootsAccentColorIsTheWindowsTint() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "view", "style": ["accent_color": [232, 28, 36, 255]]],
            ["op": "create", "id": 2, "kind": "button", "handlers": ["press"], "style": ["exact_apple_button_style": "plain"]],
            ["op": "create", "id": 3, "kind": "text", "props": ["text": "Go"]],
            ["op": "children", "id": 2, "ids": [3]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 300.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 120.0, "h": 44.0],
        ])
        let tint = try XCTUnwrap(p.views[2]).tintColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 232.0 / 255, accuracy: 0.01, "the root's accent is the window's tint, which every view inherits")
        XCTAssertEqual(g, 28.0 / 255, accuracy: 0.01)
    }

    /// Disabled, a button the author coloured keeps its colours (HTML keeps
    /// an author's on a disabled button): UIKit draws it enabled, and it
    /// takes no touch. Its own CSS says how disabled looks.
    func testADisabledButtonTheAuthorColouredKeepsItsColours() throws {
        for style in ["plain", "tinted", "gray"] {
            let p = presenter([
                ["op": "create", "id": 1, "kind": "button", "handlers": ["press"], "props": ["disabled": "true"],
                 "style": ["exact_apple_button_style": style]],
                ["op": "create", "id": 2, "kind": "text", "props": ["text": "Front"], "style": ["text_color": [232, 28, 36, 255]]],
                ["op": "children", "id": 1, "ids": [2]],
                ["op": "roots", "ids": [1]],
                ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 120.0, "h": 44.0],
                ["op": "frame", "id": 2, "x": 30.0, "y": 12.0, "w": 60.0, "h": 20.0],
            ])
            let b = try XCTUnwrap(button(try XCTUnwrap(p.views[1])))
            XCTAssertTrue(b.isEnabled, "\(style): drawn in its enabled colours")
            XCTAssertFalse(b.isUserInteractionEnabled, "\(style): but takes no touch")
            p.apply(wireBatch([["op": "props", "id": 1, "set": [:], "clear": ["disabled"]]]))
            XCTAssertTrue(b.isUserInteractionEnabled)
        }
    }

    /// Disabled with no colours of the author's, a system style is UIKit's
    /// disabled look: its colours are handed back, so UIKit greys the fill,
    /// the label and the symbol.
    func testADisabledSystemStyleIsUIKitsDisabledLook() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "button", "handlers": ["press"], "props": ["disabled": "true"],
             "style": ["exact_apple_button_style": "tinted"]],
            ["op": "create", "id": 2, "kind": "text", "props": ["text": "Front"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 120.0, "h": 44.0],
            ["op": "frame", "id": 2, "x": 30.0, "y": 12.0, "w": 60.0, "h": 20.0],
        ])
        let b = try XCTUnwrap(button(try XCTUnwrap(p.views[1])))
        XCTAssertFalse(b.isEnabled)
        try XCTUnwrap(b.configurationUpdateHandler)(b)
        XCTAssertNil(b.configuration?.baseForegroundColor, "UIKit's disabled foreground")
        XCTAssertNil(b.configuration?.baseBackgroundColor, "UIKit's disabled fill")
    }

    func testADisabledButtonIsADisabledUIButton() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "button", "handlers": ["press"], "props": ["disabled": "true"]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 120.0, "h": 44.0],
        ])
        XCTAssertFalse(try XCTUnwrap(button(try XCTUnwrap(p.views[1]))).isEnabled)
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
        XCTAssertTrue(p.menus.invokes(tip), "a content popover's invoker commands it")
        XCTAssertTrue(tip.activatable, "its invoker is pressable as itself (LLP 1035.001.001 D1)")
        XCTAssertFalse(p.menus.invokes(menu), "a popover of pressing rows is a menu")
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

    /// The menu points at the text pressed, not the whole box: a tall
    /// box's menu stood above or below it, away from the words.
    func testCopysMenuPointsAtTheTextPressed() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "view", "style": ["user_select": "text"]],
            ["op": "create", "id": 2, "kind": "text", "props": ["text": "TTI 289 ms"]],
            ["op": "create", "id": 3, "kind": "text", "props": ["text": "Phases: exec 53 ms, initializers 3 ms"]],
            ["op": "children", "id": 1, "ids": [2, 3]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 400.0],
            ["op": "frame", "id": 2, "x": 16.0, "y": 8.0, "w": 268.0, "h": 40.0],
            ["op": "frame", "id": 3, "x": 16.0, "y": 200.0, "w": 268.0, "h": 120.0],
        ])
        let box = try XCTUnwrap(p.views[1]), copy = try XCTUnwrap(box.textCopy)
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
        copy.pressedAt = CGPoint(x: 100, y: 250)
        XCTAssertEqual(copy.editMenuInteraction(copy.menu, targetRectFor: config), CGRect(x: 16, y: 200, width: 268, height: 120), "the paragraph under the finger")
        copy.pressedAt = CGPoint(x: 100, y: 120)
        XCTAssertEqual(copy.editMenuInteraction(copy.menu, targetRectFor: config), CGRect(x: 16, y: 8, width: 268, height: 40), "between paragraphs: the nearest")
    }

    /// The edit menu's Copy reaches a node through the responder chain. A
    /// node claims it only inside a `user-select: text` box or with a `copy`
    /// handler; anywhere else it is not the node's, and sending it to a node
    /// never reaches UIResponder, which implements none (it threw
    /// "unrecognized selector" and crashed the app).
    func testCopyIsANodesOnlyWhereItCanCopy() throws {
        let p = presenter([
            ["op": "create", "id": 1, "kind": "view", "style": ["user_select": "text"]],
            ["op": "create", "id": 2, "kind": "text", "props": ["text": "TTI 521 ms"]],
            ["op": "create", "id": 3, "kind": "text", "props": ["text": "Plain"]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1, 3]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 40.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 300.0, "h": 40.0],
            ["op": "frame", "id": 3, "x": 0.0, "y": 50.0, "w": 300.0, "h": 40.0],
        ])
        let inside = try XCTUnwrap(p.views[2]), plain = try XCTUnwrap(p.views[3])
        let copy = #selector(UIResponderStandardEditActions.copy(_:))
        XCTAssertTrue(inside.canPerformAction(copy, withSender: nil))
        XCTAssertFalse(plain.canPerformAction(copy, withSender: nil))
        XCTAssertFalse(plain.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        plain.copy(nil)
        plain.cut(nil)
        plain.paste(nil)
        // What it writes is TextCopy's (the test above); the pasteboard
        // reads nothing back under a test runner.
        inside.copy(nil)
    }
}
#endif
