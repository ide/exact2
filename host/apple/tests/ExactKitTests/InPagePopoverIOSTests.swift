#if os(iOS)
import XCTest
@testable import ExactKit
import UIKit

/// LLP 1021 D3 in the page (theme2 2026-10-22 06:53): a custom (non-native)
/// button opening a popover that is no menu opens it as itself, anchored on
/// the button, as a native button's does, and a second press closes it; one
/// opening a menu keeps UIKit's pull-down over the button.
final class InPagePopoverIOSTests: XCTestCase {
    private var window: UIWindow?
    override func tearDown() { window?.isHidden = true; window = nil; super.tearDown() }

    func testACustomButtonsTextPopoverOpensAsItselfAndAMenuStaysThePullDown() throws {
        let p = Presenter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        self.window = window
        defer { p.reset() }
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view"],
            ["op": "create", "id": 2, "kind": "button", "props": ["popovertarget": "about", "accessibilityLabel": "About", "appearance": "none"]],
            ["op": "create", "id": 3, "kind": "view", "props": ["popover": "auto", "id": "about"]],
            ["op": "create", "id": 4, "kind": "text", "props": ["text": "Words, not rows"]],
            ["op": "create", "id": 5, "kind": "button", "props": ["popovertarget": "menu", "accessibilityLabel": "More", "appearance": "none"]],
            ["op": "create", "id": 6, "kind": "view", "props": ["popover": "auto", "id": "menu", "accessibilityRole": "menu"]],
            ["op": "create", "id": 7, "kind": "button", "props": [String: String](), "handlers": ["press"]],
            ["op": "create", "id": 8, "kind": "text", "props": ["text": "Bump"]],
            ["op": "children", "id": 3, "ids": [4]], ["op": "children", "id": 7, "ids": [8]], ["op": "children", "id": 6, "ids": [7]],
            ["op": "children", "id": 1, "ids": [2, 5, 3, 6]], ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0, "y": 0, "w": 400, "h": 800],
            ["op": "frame", "id": 2, "x": 20, "y": 100, "w": 80, "h": 44],
            ["op": "frame", "id": 5, "x": 200, "y": 100, "w": 80, "h": 44],
            ["op": "frame", "id": 3, "x": 0, "y": 0, "w": 200, "h": 60],
            ["op": "frame", "id": 4, "x": 0, "y": 0, "w": 200, "h": 20],
            ["op": "frame", "id": 6, "x": 0, "y": 0, "w": 200, "h": 44],
            ["op": "frame", "id": 7, "x": 0, "y": 0, "w": 200, "h": 44],
        ]))
        let about = try XCTUnwrap(p.views[2]), pop = try XCTUnwrap(p.views[3]), more = try XCTUnwrap(p.views[5])
        XCTAssertFalse(about.subviews.contains { $0 is UIButton && ($0 as! UIButton).showsMenuAsPrimaryAction }, "no pull-down over a text popover's invoker")
        XCTAssertTrue(more.subviews.contains { $0 is UIButton && ($0 as! UIButton).showsMenuAsPrimaryAction }, "a menu's invoker keeps UIKit's pull-down")
        p.press(about.id)
        let end = Date().addingTimeInterval(3)
        while !p.menus.isOpen(pop), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(p.menus.isOpen(pop), "the press opens it as itself")
        XCTAssertFalse(pop.isHidden)
        let anchor = about.convert(about.bounds, to: nil), frame = pop.convert(pop.bounds, to: nil)
        XCTAssertLessThan(abs(frame.minY - anchor.maxY), 20, "anchored under the button: \(frame) \(anchor)")
        p.press(about.id)
        let shut = Date().addingTimeInterval(3)
        while p.menus.isOpen(pop), Date() < shut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(p.menus.isOpen(pop), "a second press closes it")
    }

    /// A popover with no authored placement whose invoker is at the bottom
    /// (Harmony's emoji button under the composer) opens above it, as the
    /// web's default flips, rather than held over its own invoker.
    func testAPopoverFromTheBottomOpensAboveItsInvoker() throws {
        let p = Presenter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        self.window = window
        defer { p.reset() }
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view"],
            ["op": "create", "id": 2, "kind": "button", "props": ["popovertarget": "emoji", "accessibilityLabel": "Emoji", "appearance": "none"]],
            ["op": "create", "id": 3, "kind": "view", "props": ["popover": "auto", "id": "emoji"]],
            ["op": "create", "id": 4, "kind": "text", "props": ["text": "Pick one"]],
            ["op": "children", "id": 3, "ids": [4]], ["op": "children", "id": 1, "ids": [2, 3]], ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0, "y": 0, "w": 400, "h": 800],
            ["op": "frame", "id": 2, "x": 12, "y": 740, "w": 40, "h": 40],
            ["op": "frame", "id": 3, "x": 0, "y": 0, "w": 300, "h": 240],
            ["op": "frame", "id": 4, "x": 0, "y": 0, "w": 300, "h": 20],
        ]))
        let button = try XCTUnwrap(p.views[2]), pop = try XCTUnwrap(p.views[3])
        p.press(button.id)
        let end = Date().addingTimeInterval(3)
        while !p.menus.isOpen(pop), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(p.menus.isOpen(pop))
        let anchor = button.convert(button.bounds, to: nil), frame = pop.convert(pop.bounds, to: nil)
        XCTAssertLessThanOrEqual(frame.maxY, anchor.minY + 0.5, "above its invoker: \(frame) over \(anchor)")
        XCTAssertEqual(frame.minX, anchor.minX, accuracy: 0.5, "from its left edge")
    }

    // MARK: Popovers opened over a card (PopoverCardIOS.swift, PopoverLayerIOS.swift)

    /// The main loop runs in 5 ms turns until `done`, failing only at `cap`.
    private func waitFor(_ what: String, cap: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line, _ done: () -> Bool) {
        let until = Date().addingTimeInterval(cap)
        while !done(), Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        if !done() { XCTFail("\(what): not within \(cap) s", file: file, line: line) }
    }

    /// A page with a glass button (2) opening a card (3) that holds a hide
    /// button (4), text (5) and openers of a plain (9), a native (11) and a
    /// manual (13) nested popover; an independent manual popover (15).
    private func cards(in scene: UIWindowScene, using p: Presenter = Presenter()) -> Presenter {
        let window = UIWindow(windowScene: scene), root = UIViewController()
        self.window = window
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = root
        window.makeKeyAndVisible()
        p.viewport.frame = root.view.bounds
        root.view.addSubview(p.viewport)
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view"],
            ["op": "create", "id": 2, "kind": "button", "props": ["id": "open", "popovertarget": "card", "appearance": "none", "backgroundMaterial": "glass"], "style": ["border_radius": 22]],
            ["op": "create", "id": 3, "kind": "view", "props": ["id": "card", "popover": "auto", "defaultSurface": "true", "defaultSurfaceRadius": "30"]],
            ["op": "create", "id": 4, "kind": "button", "props": ["appearance": "none", "popovertarget": "card", "popovertargetaction": "hide"], "handlers": ["press"]],
            ["op": "create", "id": 5, "kind": "text", "props": ["text": "Content card"]],
            ["op": "create", "id": 6, "kind": "button", "props": ["appearance": "none", "popovertarget": "plain", "id": "plain-open"]],
            ["op": "create", "id": 7, "kind": "button", "props": ["appearance": "none", "popovertarget": "native", "id": "native-open", "backgroundMaterial": "glass"], "style": ["border_radius": 20]],
            ["op": "create", "id": 8, "kind": "button", "props": ["appearance": "none", "popovertarget": "manual", "id": "manual-open"]],
            ["op": "create", "id": 9, "kind": "view", "props": ["id": "plain", "popover": "auto"]],
            ["op": "create", "id": 10, "kind": "button", "props": ["appearance": "none", "popovertarget": "plain", "popovertargetaction": "hide"]],
            ["op": "create", "id": 11, "kind": "view", "props": ["id": "native", "popover": "auto"]],
            ["op": "create", "id": 12, "kind": "text", "props": ["text": "Native child"]],
            ["op": "create", "id": 13, "kind": "view", "props": ["id": "manual", "popover": "manual"]],
            ["op": "create", "id": 14, "kind": "text", "props": ["text": "Manual child"]],
            ["op": "create", "id": 15, "kind": "view", "props": ["id": "independent", "popover": "manual"]],
            ["op": "create", "id": 16, "kind": "text", "props": ["text": "Independent manual"]],
            ["op": "children", "id": 3, "ids": [4, 5, 6, 7, 8]],
            ["op": "children", "id": 9, "ids": [10]], ["op": "children", "id": 11, "ids": [12]],
            ["op": "children", "id": 13, "ids": [14]], ["op": "children", "id": 15, "ids": [16]],
            ["op": "children", "id": 1, "ids": [2, 3, 9, 11, 13, 15]], ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0, "y": 0, "w": window.bounds.width, "h": window.bounds.height],
            ["op": "frame", "id": 2, "x": 20, "y": 400, "w": 44, "h": 44],
            ["op": "frame", "id": 3, "x": 0, "y": 0, "w": 280, "h": 260],
            ["op": "frame", "id": 4, "x": 12, "y": 12, "w": 220, "h": 44],
            ["op": "frame", "id": 5, "x": 12, "y": 60, "w": 240, "h": 24],
            ["op": "frame", "id": 6, "x": 12, "y": 88, "w": 220, "h": 44],
            ["op": "frame", "id": 7, "x": 12, "y": 140, "w": 220, "h": 44],
            ["op": "frame", "id": 8, "x": 12, "y": 192, "w": 220, "h": 44],
        ] + [9, 11, 13, 15].flatMap { id in [
            ["op": "frame", "id": id, "x": 0, "y": 0, "w": 180, "h": 80],
            ["op": "frame", "id": id + 1, "x": 12, "y": 12, "w": 156, "h": 44],
        ] }))
        return p
    }

    private func openCard(_ p: Presenter) throws -> PopoverCard {
        p.menus.action("showPopover", ["card", "open"])
        waitFor("the card's native presentation", cap: 10) { !p.menus.inTransition }
        let pop = try XCTUnwrap(p.views[3]), layer = try XCTUnwrap(PopoverLayer.containing(pop))
        let card = try XCTUnwrap(layer.card)
        XCTAssertNotNil(card.presentingViewController)
        XCTAssertNotNil(card.view.window)
        XCTAssertNil(pop.materialView, "the native platter supplies the default surface")
        XCTAssertTrue(p.presentations().contains { $0 === layer }, "native content belongs to the session")
        return card
    }

    func testPlainAndManualChildrenStayVisibleInTheCurrentCardAndRetireWithIt() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "nested popovers need the native card's scene") }
        let p = cards(in: scene)
        defer { p.reset() }
        let card = try openCard(p), plain = try XCTUnwrap(p.views[9]), manual = try XCTUnwrap(p.views[13])
        p.menus.action("showPopover", ["plain", "plain-open"])
        XCTAssertTrue(p.menus.isOpen(plain))
        XCTAssertTrue(PopoverLayer.containing(plain)?.cardOwner === card)
        XCTAssertTrue(plain.superview?.superview === card.presentationController?.containerView)
        let target = try XCTUnwrap(p.views[10]), point = target.convert(CGPoint(x: 50, y: 20), to: window)
        let hit = try XCTUnwrap(window?.hitTest(point, with: nil))
        XCTAssertTrue(hit === target || hit.isDescendant(of: target), "a native hit reaches the plain child")
        p.press(target.id)
        XCTAssertFalse(p.menus.isOpen(plain))
        XCTAssertTrue(p.menus.isOpen(try XCTUnwrap(p.views[3])))
        p.menus.action("showPopover", ["manual", "manual-open"])
        XCTAssertTrue(PopoverLayer.containing(manual)?.cardOwner === card)
        XCTAssertNil(PopoverLayer.containing(manual)?.card, "manual dismissal stays authored")
        p.menus.lightDismiss(try XCTUnwrap(p.views[5]))
        XCTAssertTrue(p.menus.isOpen(manual), "touching its parent's content does not dismiss a manual popover")
        p.menus.action("hidePopover", ["card"])
        waitFor("the parent card and its children retire", cap: 10) { !p.menus.inTransition }
        XCTAssertFalse(p.menus.isOpen(manual))
        XCTAssertFalse(p.menus.isOpen(plain))
        XCTAssertTrue(manual.superview === p.views[1]?.container)
    }

    func testANestedNativeCardAndAnIndependentManualPopoverFollowTheirCurrentOwners() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("native content cards require iOS 26") }
        guard let scene = hostedWindowScene() else { throw missing("scene", "native nesting needs a scene") }
        let p = cards(in: scene)
        defer { p.reset() }
        let parent = try openCard(p)
        p.menus.action("showPopover", ["native", "native-open"])
        waitFor("the native child arrives", cap: 10) { !p.menus.inTransition }
        let child = try XCTUnwrap(PopoverLayer.containing(p.views[11])?.card)
        XCTAssertTrue(child.presentingViewController === parent)
        XCTAssertTrue(p.menus.isOpen(try XCTUnwrap(p.views[3])))
        p.menus.action("showPopover", ["independent"])
        let manual = try XCTUnwrap(p.views[15])
        XCTAssertTrue(PopoverLayer.containing(manual)?.cardOwner === child)
        p.menus.action("hidePopover", ["native"])
        waitFor("the child leaves", cap: 10) { !p.menus.inTransition }
        XCTAssertTrue(p.menus.isOpen(manual))
        XCTAssertTrue(PopoverLayer.containing(manual)?.cardOwner === parent, "an unrelated manual opening survives and follows the visible owner")
        p.menus.action("hidePopover", ["card"])
        waitFor("the parent leaves", cap: 10) { !p.menus.inTransition }
        XCTAssertTrue(p.menus.isOpen(manual))
        XCTAssertTrue(manual.isDescendant(of: p.documentHost))
    }
}
#endif
