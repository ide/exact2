#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit
import ExactGroupedLists

/// LLP 1075.003 §9.10 and LLP 1116 D2 over the native fixture's Chat route: a
/// pressable group around the heading (an avatar, a subtitle) is the item's
/// title, drawn and tapped, and a heading the header holds directly takes the
/// first text after it as its subtitle. They share `NavigationBasicsIOSTests`'
/// fixture and helpers.
extension NavigationBasicsIOSTests {
    func testAPressableGroupAroundTheHeadingIsTheItemsTitleDrawnAndTapped() throws {
        let session = try fixture("basics-title")
        let (_, _, chat) = try chat(session)
        let item = chat.navigationItem
        XCTAssertEqual(item.title, "Chat", "the heading stays the title, which Back reads")
        let view = try XCTUnwrap(item.titleView as? HeaderTitleView, "an avatar and a press make a drawn title view")
        XCTAssertEqual(view.title.text, "Chat")
        XCTAssertEqual(view.subtitle.text, "Online")
        XCTAssertFalse(view.subtitle.isHidden)
        XCTAssertEqual(view.avatar.image?.size, CGSize(width: 32, height: 32), "the avatar at the size the author gave its box (headerBoxSize)")
        XCTAssertFalse(view.avatar.isHidden)
        // Dark mode keeps the box: the asset's dark variant once drew at 3x.
        view.window?.overrideUserInterfaceStyle = .dark
        view.layoutIfNeeded()
        XCTAssertEqual(view.avatar.bounds.size, CGSize(width: 32, height: 32), "the avatar's box in dark mode")
        view.window?.overrideUserInterfaceStyle = .unspecified
        XCTAssertEqual(view.accessibilityIdentifier, "title-group")
        XCTAssertTrue(view.accessibilityTraits.contains(.button))
        XCTAssertEqual(view.accessibilityValue, "Online")
        if #available(iOS 26.0, *) { XCTAssertNil(item.subtitle, "the drawn view holds the subtitle") }
        XCTAssertTrue(try node(session, "header-chat").isHidden, "the header itself is not painted")
        // A tap on the title presses the group, as a tap on it would.
        XCTAssertEqual(text(session, "title-presses"), "title presses 0")
        // (The registered action, sent as a touch up sends it: the test
        // host does not deliver `sendActions`, §9.8.)
        for target in view.allTargets {
            for action in view.actions(forTarget: target, forControlEvent: .touchUpInside) ?? [] {
                _ = (target as NSObject).perform(Selector(action))
            }
        }
        until("the title pressed its group") { self.text(session, "title-presses") == "title presses 1" }
        // The subtitle follows the Contract, in the same view.
        try tapNode(session, "toggle-subtitle")
        until("the subtitle left") { view.subtitle.isHidden }
        XCTAssertNil(view.accessibilityValue)
        XCTAssertTrue(item.titleView === view)
        // A subtitle that is a line of symbols and texts draws them inline.
        try tapNode(session, "toggle-muted")
        until("the glyph line") { view.accessibilityValue == "Muted, disappearing messages after 1 week" }
        let line = try XCTUnwrap(view.subtitle.attributedText)
        var attachments: [NSTextAttachment] = []
        line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length)) { value, _, _ in
            if let a = value as? NSTextAttachment { attachments.append(a) }
        }
        XCTAssertEqual(attachments.count, 2, "bell.slash and timer, inline")
        // Template images, tinted by the run's dynamic colour: they follow
        // the appearance with no rebuild.
        XCTAssertEqual(attachments.map { $0.image?.renderingMode }, [.alwaysTemplate, .alwaysTemplate])
        XCTAssertEqual(line.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, view.subtitle.textColor)
        XCTAssertTrue(line.string.contains("Muted") && line.string.contains("1w"))
        try tapNode(session, "toggle-muted")
        until("back to no subtitle (it was toggled off)") { view.accessibilityValue == nil && view.subtitle.isHidden }
        // A title view a hatch sets stays: Exact draws only its own.
        let hatches = UILabel()
        item.titleView = hatches
        try tapNode(session, "toggle-subtitle")
        until("the subtitle came back") { !view.subtitle.isHidden }
        XCTAssertTrue(item.titleView === hatches, "the hatch's title view is left alone")
    }

    func testARIAUnavailablePressableTitleKeepsItsAction() throws {
        let session = try fixture("aria-title")
        let (_, _, chat) = try chat(session)
        let view = try XCTUnwrap(chat.navigationItem.titleView as? HeaderTitleView)
        let group = try node(session, "title-group")
        let header = try node(session, "header-chat")
        let heading = try node(session, "title-chat")
        group.props["accessibilityDisabled"] = "true"
        view.update(try XCTUnwrap(HeaderTitle(header: header, heading: heading, tap: group, apart: [])), title: "Chat")
        XCTAssertTrue(view.isEnabled, "ARIA does not disable the title action")
        XCTAssertTrue(view.accessibilityTraits.contains(.notEnabled))
        group.props["accessibilityDisabled"] = "false"
        view.update(try XCTUnwrap(HeaderTitle(header: header, heading: heading, tap: group, apart: [])), title: "Chat")
        XCTAssertFalse(view.accessibilityTraits.contains(.notEnabled))
    }

    /// LLP 1116 D2 (amending LLP 1075.003 §9.10): a heading the header holds
    /// directly takes the first text after it as its subtitle, UIKit's own
    /// on iOS 26 (a drawn title view before). A second text is not the
    /// bar's: the agent marks it in its tree and screenshot and refuses a
    /// tap on it, by the rule the bar follows (`HeaderShape.presents`).
    func testAHeadingTheHeaderHoldsDirectlyTakesTheFirstTextAfterItAsItsSubtitle() throws {
        let session = try fixture("basics-direct-subtitle")
        let tabs = try XCTUnwrap(session.presenter.navigation.tabController)
        let nav = try XCTUnwrap(tabs.selectedViewController as? UINavigationController)
        try tapNode(session, "open-plain")
        until("Plain pushed") { nav.viewControllers.count == 2 && nav.transitionCoordinator == nil }
        spin(0.3)
        let plain = try XCTUnwrap(nav.topViewController as? RouteController)
        let item = plain.navigationItem
        XCTAssertEqual(item.title, "Plain")
        if #available(iOS 26.0, *) {
            XCTAssertEqual(item.subtitle, "No Back control", "UIKit's own subtitle")
            XCTAssertNil(item.titleView, "nothing drawn: no avatar, no press")
        } else {
            let view = try XCTUnwrap(item.titleView as? HeaderTitleView, "a subtitle before iOS 26 is a drawn title view")
            XCTAssertEqual(view.subtitle.text, "No Back control")
        }
        XCTAssertTrue(try node(session, "header-plain").isHidden, "the bar shows the header; iOS does not paint it")
        // What the bar leaves out, as the agent reports it.
        let unshown = session.presenter.navigation.unshownByBar()
        let aside = try node(session, "aside-plain")
        XCTAssertEqual(unshown[aside.id], NavigationHost.unshownReason)
        for shown in ["header-plain", "title-plain", "subtitle-plain", "compose-plain"] {
            XCTAssertNil(unshown[try node(session, shown).id], "\(shown) is the bar's")
        }
        let agent = Agent(session: session)
        let tap = agent.tap(["id": Int(aside.id)])
        XCTAssertTrue((tap["error"] as? String)?.contains("the iOS navigation bar does not show this node") == true, "\(tap)")
        let rows = agent.decorateTree(["nodes": [["id": Int(aside.id)], ["id": Int(try node(session, "subtitle-plain").id)]]])["nodes"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["unshown"] as? String, NavigationHost.unshownReason)
        XCTAssertNil(rows?.last?["unshown"])
        // A heading in a wrapper with a bar item (Chat's press group aside)
        // and a box before a direct heading are not avatars: Home's badge
        // button is an item, and its title stays UIKit's.
        nav.popViewController(animated: false)
        spin(0.3)
        let home = try XCTUnwrap(nav.topViewController)
        XCTAssertFalse(home.navigationItem.titleView is HeaderTitleView, "Home's segments keep the title view")
        if #available(iOS 26.0, *) { XCTAssertNil(home.navigationItem.subtitle, "Home has no text after its heading") }
    }
}
#endif
