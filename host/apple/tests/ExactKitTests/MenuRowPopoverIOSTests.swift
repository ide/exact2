#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// exact2's menu rule on UIKit (LLP 1021; theme2 2026-10-21 19:47, 22:05):
/// a popover a row of a menu opens, no menu itself, is no submenu: the row is
/// an action that presses it and then opens the popover as if by the menu's
/// own invoker (the node the context menu opened on), so the menu closing
/// as its row is chosen doesn't take it along. A row opening a menu is still
/// its submenu. UIKit, so a simulator runs it.
final class MenuRowPopoverIOSTests: XCTestCase {
    private var window: UIWindow!

    private final class Links: ExactSessionDelegate {
        var urls: [String] = []
        func exactSession(_ session: ExactSession, command name: String, args: [Any]) {
            if name == "openURL", let url = args.first as? String { urls.append(url) }
        }
    }

    private func addLink(_ p: Presenter, href: String, in menu: UInt32 = 2) throws -> NodeView {
        p.apply(wireBatch([
            ["op": "create", "id": 110, "kind": "text", "props": ["text": "Call"]],
            ["op": "frame", "id": 110, "x": 0.0, "y": 0.0, "w": 180.0, "h": 20.0],
            ["op": "create", "id": 10, "kind": "button", "props": ["href": href]],
            ["op": "frame", "id": 10, "x": 0.0, "y": 0.0, "w": 200.0, "h": 30.0],
            ["op": "children", "id": 10, "ids": [110]],
            ["op": "children", "id": menu, "ids": menu == 2 ? [3, 4, 10] : [8, 10]],
        ]))
        return try XCTUnwrap(p.views[10])
    }

    private func linkAction(_ p: Presenter) throws -> UIAction {
        func actions(_ items: [UIMenuElement]) -> [UIAction] {
            items.flatMap { item in
                if let action = item as? UIAction { return [action] }
                return (item as? UIMenu).map { actions($0.children) } ?? []
            }
        }
        let items = p.menus.items(of: try XCTUnwrap(p.views[2]), opener: p.views[1])
        return try XCTUnwrap(actions(items).first { $0.title == "Call" }, "a link is an action, including in a submenu")
    }

    /// A message (1) whose context menu is `message-menu` (2): React (3,
    /// opening `picker`, 5, a popover of an emoji button, 6) and More (4,
    /// opening `more-menu`, 7, a menu of one row, 8).
    private func presenter() -> Presenter {
        let p = Presenter()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        func button(_ id: Int, _ label: String, _ props: [String: String] = [:]) -> [[String: Any]] {
            [["op": "create", "id": 100 + id, "kind": "text", "props": ["text": label]],
             ["op": "frame", "id": 100 + id, "x": 0.0, "y": 0.0, "w": 180.0, "h": 20.0],
             ["op": "create", "id": id, "kind": "button", "handlers": ["press"], "props": props],
             ["op": "frame", "id": id, "x": 0.0, "y": 0.0, "w": 200.0, "h": 30.0], ["op": "children", "id": id, "ids": [100 + id]]]
        }
        var ops: [[String: Any]] = [
            ["op": "create", "id": 1, "kind": "button", "handlers": ["press"], "props": ["contextPopover": "message-menu", "id": "message"]],
            ["op": "create", "id": 2, "kind": "view", "props": ["popover": "auto", "id": "message-menu", "accessibilityRole": "menu"]],
            ["op": "create", "id": 5, "kind": "view", "props": ["popover": "auto", "id": "picker"]],
            ["op": "create", "id": 7, "kind": "view", "props": ["popover": "auto", "id": "more-menu", "accessibilityRole": "menu"]],
            ["op": "create", "id": 9, "kind": "view"],
        ]
        ops += button(3, "Add Reaction", ["popovertarget": "picker"]) + button(4, "More", ["popovertarget": "more-menu"])
        ops += button(6, "👍") + button(8, "Deep")
        ops += [["op": "children", "id": 2, "ids": [3, 4]], ["op": "children", "id": 5, "ids": [6]], ["op": "children", "id": 7, "ids": [8]],
                ["op": "children", "id": 9, "ids": [1, 2, 5, 7]], ["op": "roots", "ids": [9]],
                ["op": "frame", "id": 9, "x": 0.0, "y": 0.0, "w": 400.0, "h": 600.0],
                ["op": "frame", "id": 1, "x": 20.0, "y": 300.0, "w": 200.0, "h": 40.0],
                ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 220.0, "h": 120.0],
                ["op": "frame", "id": 5, "x": 0.0, "y": 0.0, "w": 220.0, "h": 60.0],
                ["op": "frame", "id": 7, "x": 0.0, "y": 0.0, "w": 220.0, "h": 60.0]]
        p.apply(wireBatch(ops))
        return p
    }

    func testAMenuRowsPopoverOpensFromTheMenusInvokerAndAMenuIsStillASubmenu() throws {
        let p = presenter()
        let items = p.menus.items(of: try XCTUnwrap(p.views[2]), opener: p.views[1])
        let titles = items.flatMap { ($0 as? UIMenu)?.options.contains(.displayInline) == true ? ($0 as! UIMenu).children : [$0] }
        let react = try XCTUnwrap(titles.first { $0.title == "Add Reaction" } as? UIAction, "the picker is no submenu: an action")
        XCTAssertNotNil(titles.first { $0.title == "More" } as? UIMenu, "a menu is still its submenu")
        var pressed: [UInt32] = []
        p.onPress = { pressed.append($0) }
        UIButton().sendAction(react)
        let picker = try XCTUnwrap(p.views[5])
        let end = Date(timeIntervalSinceNow: 5) // the picker opens a turn after the press
        while !p.menus.isOpen(picker) && Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        XCTAssertEqual(pressed, [3], "the row's own press")
        XCTAssertTrue(p.menus.isOpen(picker), "then the picker opens")
        // From the message the menu opened on: beside it, not where the menu's row was.
        let at = picker.convert(picker.bounds, to: window), message = try XCTUnwrap(p.views[1]).convert(p.views[1]!.bounds, to: window)
        XCTAssertLessThan(min(abs(at.minY - message.maxY), abs(at.maxY - message.minY)), 40, "anchored to the message: \(at) by \(message)")
        // Chosen again, the row toggles it closed, as its invoker would.
        UIButton().sendAction(react)
        let closing = Date(timeIntervalSinceNow: 5)
        while p.menus.isOpen(picker) && Date() < closing { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        XCTAssertFalse(p.menus.isOpen(picker), "toggled closed")
    }

    func testALinkInAMenuIsAnItemThatFollowsItsURL() throws {
        let links = Links(), session = ExactApp.shared.makeSession(delegate: links, label: "menu-link")
        defer { session.destroy() }
        let p = presenter()
        defer { p.reset(); window.isHidden = true }
        p.session = session
        _ = try addLink(p, href: "tel:+14155550101")
        var pressed: [UInt32] = []
        p.onPress = { pressed.append($0) }
        for href in ["tel:+14155550101", "mailto:a@example.com", "https://example.com/map", "//example.com/map", "item/2", "#intro", "?tab=2"] {
            p.apply(wireBatch([["op": "props", "id": 10, "set": ["href": href]]]))
            let action = try linkAction(p)
            XCTAssertTrue(links.urls.isEmpty, "building a menu follows nothing")
            UIButton().sendAction(action)
            XCTAssertEqual(links.urls, [href], "one default action, with the same URL as a direct press")
            XCTAssertTrue(pressed.isEmpty, "a followed link does not also dispatch a handler")
            links.urls.removeAll()
        }
        _ = try linkAction(p)
        p.menus.reset()
        waitForMainQueue()
        XCTAssertTrue(links.urls.isEmpty, "discarding unchosen items schedules no activation")
    }

    func testAMenuLinkUsesTheSessionsNavigationDefaultForARootPath() throws {
        let links = Links(), session = ExactApp.shared.makeSession(delegate: links, label: "menu-route")
        defer { session.destroy() }
        XCTAssertNil(session.boot(plan: try fixturePlan("PUSHED_TITLE"), size: CGSize(width: 390, height: 844)).error)
        let p = presenter()
        defer { p.reset(); window.isHidden = true }
        p.session = session
        _ = try addLink(p, href: "/short?from=menu#intro")
        var pressed: [UInt32] = []
        p.onPress = { pressed.append($0) }
        UIButton().sendAction(try linkAction(p))
        XCTAssertEqual(session.routerOp?["url"] as? String, "/short?from=menu#intro")
        XCTAssertTrue(session.presenter.views.values.contains { $0.props["testId"] == "route-short" })
        XCTAssertTrue(links.urls.isEmpty, "an app route is not also opened externally")
        XCTAssertTrue(pressed.isEmpty, "successful navigation does not also dispatch press")
        p.apply(wireBatch([["op": "props", "id": 10, "set": ["href": "/missing"]]]))
        UIButton().sendAction(try linkAction(p))
        XCTAssertEqual(session.routerOp?["url"] as? String, "/short?from=menu#intro", "a refused route keeps the current visit")
        XCTAssertTrue(links.urls.isEmpty, "preserve the direct press's refusal")
    }

    func testAMenuLinksCurrentHandlerEnablementAndIncarnationGovernActivation() throws {
        let links = Links(), session = ExactApp.shared.makeSession(delegate: links, label: "menu-link-state")
        defer { session.destroy() }
        let p = presenter()
        defer { p.reset(); window.isHidden = true }
        p.session = session
        let row = try addLink(p, href: "tel:+14155550101"), action = try linkAction(p)
        var pressed: [UInt32] = []
        p.onPress = { pressed.append($0) }
        p.apply(wireBatch([["op": "props", "id": 10, "set": ["disabled": "true"]]]))
        XCTAssertTrue(try linkAction(p).attributes.contains(.disabled))
        UIButton().sendAction(action)
        XCTAssertTrue(links.urls.isEmpty, "an old enabled action cannot bypass a newly disabled row")
        p.apply(wireBatch([["op": "props", "id": 10, "set": ["disabled": "false", "href": "mailto:current@example.com"]]]))
        row.handlers = ["press"]
        UIButton().sendAction(action)
        XCTAssertEqual(pressed, [10], "the authored handler replaces the link default, once")
        XCTAssertTrue(links.urls.isEmpty)
        row.handlers = []
        p.apply(wireBatch([["op": "props", "id": 10, "set": ["inert": "true"]]]))
        UIButton().sendAction(action)
        XCTAssertTrue(links.urls.isEmpty, "an inert link does not follow")
        p.apply(wireBatch([["op": "props", "id": 10, "set": ["inert": "false"]]]))
        UIButton().sendAction(action)
        XCTAssertEqual(links.urls, ["mailto:current@example.com"], "the existing default resolves the current URL")
        p.apply(wireBatch([["op": "props", "id": 10, "set": ["href": ""]]]))
        UIButton().sendAction(action)
        XCTAssertEqual(links.urls.count, 1, "an emptied link has no default action")
        p.apply(wireBatch([["op": "destroy", "id": 10],
                           ["op": "create", "id": 10, "kind": "button", "props": ["href": "tel:+14155550202"]]]))
        UIButton().sendAction(action)
        XCTAssertEqual(links.urls.count, 1, "the old menu cannot activate a reused id")
        XCTAssertEqual(pressed, [10])
    }

    func testALinkInASubmenuFollowsOnceWithoutPressingItsOpener() throws {
        let links = Links(), session = ExactApp.shared.makeSession(delegate: links, label: "submenu-link")
        defer { session.destroy() }
        let p = presenter()
        defer { p.reset(); window.isHidden = true }
        p.session = session
        _ = try addLink(p, href: "mailto:a@example.com", in: 7)
        var pressed: [UInt32] = []
        p.onPress = { pressed.append($0) }
        UIButton().sendAction(try linkAction(p))
        XCTAssertEqual(links.urls, ["mailto:a@example.com"])
        XCTAssertTrue(pressed.isEmpty, "choosing a submenu link presses no opener")
    }

    func testAMenuLinksDefaultDoesNotAlsoOpenItsPopoverTarget() throws {
        let links = Links(), session = ExactApp.shared.makeSession(delegate: links, label: "menu-link-default")
        defer { session.destroy() }
        let p = presenter()
        defer { p.reset(); window.isHidden = true }
        p.session = session
        _ = try addLink(p, href: "mailto:a@example.com")
        for (name, id) in [("more-menu", UInt32(7)), ("picker", UInt32(5))] {
            p.apply(wireBatch([["op": "props", "id": 10, "set": ["popovertarget": name]]]))
            UIButton().sendAction(try linkAction(p))
            waitForMainQueue()
            XCTAssertEqual(links.urls, ["mailto:a@example.com"], "one link default")
            XCTAssertFalse(p.menus.isOpen(try XCTUnwrap(p.views[id])), "the link's target does not also open")
            links.urls.removeAll()
        }
    }
}
#endif
