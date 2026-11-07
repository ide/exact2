#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

extension NavigationBasicsIOSTests {
    /// Home's stack with Chat pushed on it.
    func chat(_ session: ExactSession) throws -> (UITabBarController, UINavigationController, RouteController) {
        let tabs = try XCTUnwrap(session.presenter.navigation.tabController)
        let nav = try XCTUnwrap(tabs.selectedViewController as? UINavigationController)
        try tapNode(session, "chat")
        until("Chat pushed") { nav.viewControllers.count == 2 && nav.transitionCoordinator == nil }
        spin(0.3)
        return (tabs, nav, try XCTUnwrap(nav.topViewController as? RouteController))
    }

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

    private func titleMenu(_ label: String) throws -> (ExactSession, RouteController, HeaderTitleView, UIContextMenuInteraction) {
        if ExactEnv.agentPaints { throw XCTSkip("UIKit owns these menus under native presentation") }
        let session = try fixture(label)
        let (_, nav, chat) = try chat(session)
        nav.view.layoutIfNeeded()
        nav.navigationBar.layoutIfNeeded()
        let view = try XCTUnwrap(chat.navigationItem.titleView as? HeaderTitleView)
        until("the projected title is mounted") { view.window != nil && view.bounds.width > 0 }
        let interaction = try XCTUnwrap(view.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
        return (session, chat, view, interaction)
    }

    private func configureTitle(_ session: ExactSession, _ view: HeaderTitleView, _ interaction: UIContextMenuInteraction) throws -> UIContextMenuConfiguration {
        try XCTUnwrap(session.presenter.menus.context.contextMenuInteraction(interaction,
            configurationForMenuAtLocation: CGPoint(x: view.bounds.midX, y: view.bounds.midY)))
    }

    func testADrawnTitleCarriesItsGroupsPreviewRowAndReturnsIt() throws {
        let (session, _, view, interaction) = try titleMenu("title-preview")
        let p = session.presenter, menus = p.menus.context
        let source = try node(session, "title-group"), card = try node(session, "title-card")
        XCTAssertTrue(try node(session, "header-chat").isHidden)
        XCTAssertFalse(p.menus.eligible(source, contextMenu: true))
        XCTAssertTrue(p.navigation.projectedTitle(for: source) === view)
        if view.window?.windowScene != nil {
            let aim = Agent(session: session).aim(["id": Int(source.id), "aim": true])
            XCTAssertNil(aim["error"], "\(aim)")
            XCTAssertNotNil(aim["aim"], "a physical touch aims at the visible title")
        }
        let configuration = try configureTitle(session, view, interaction)
        let owner = try XCTUnwrap(menus.open)
        let preview = try XCTUnwrap(menus.lift(owner))
        XCTAssertTrue(card.superview === preview.view)
        XCTAssertEqual(preview.preferredContentSize, card.bounds.size)
        XCTAssertNotNil(menus.menu(owner))
        let lifted = try XCTUnwrap(menus.contextMenuInteraction(interaction, configuration: configuration,
            highlightPreviewForItemWithIdentifier: configuration.identifier))
        XCTAssertTrue(lifted.view === view, "the explicit row keeps the whole title as its source after leaving the popover")
        let home = try XCTUnwrap(owner.container)
        menus.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
        XCTAssertNil(menus.open)
        XCTAssertTrue(card.superview === home)
        XCTAssertEqual(card.center, CGPoint(x: owner.home.midX, y: owner.home.midY))
        view.removeInteraction(interaction)
        try node(session, "header-chat").isHidden = false
        XCTAssertTrue(p.menus.eligible(source, contextMenu: true))
        XCTAssertNil(menus.menu(owner), "a detached title cannot reopen its menu through page eligibility")
    }

    func testATitleWithoutAPreviewRowLiftsItsLiveAvatarAtItsCurrentTarget() throws {
        let (session, _, view, interaction) = try titleMenu("title-avatar-lift")
        let menus = session.presenter.menus.context
        let card = try node(session, "title-card")
        card.isHidden = true
        view.transform = CGAffineTransform(translationX: 7, y: 3).scaledBy(x: 0.8, y: 0.8)
        view.avatar.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        let titleTransform = view.transform, avatarTransform = view.avatar.transform
        let configuration = try configureTitle(session, view, interaction)
        let lifted = try XCTUnwrap(menus.contextMenuInteraction(interaction, configuration: configuration,
            highlightPreviewForItemWithIdentifier: configuration.identifier))
        XCTAssertTrue(lifted.view === view.avatar)
        XCTAssertEqual(lifted.parameters.backgroundColor, .clear)
        let path = try XCTUnwrap(lifted.parameters.visiblePath)
        XCTAssertEqual(path.bounds, view.avatar.bounds)
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: view.avatar.bounds.midX, y: view.avatar.bounds.midY)))
        XCTAssertEqual(lifted.target.transform.a, 0.6, accuracy: 0.001)
        XCTAssertEqual(lifted.target.transform.d, 0.6, accuracy: 0.001)
        XCTAssertEqual(view.transform, titleTransform)
        XCTAssertEqual(view.avatar.transform, avatarTransform)
        view.avatar.isHidden = true // UIKit hides the source while lifting its live view.
        view.center.x += 11
        let returned = try XCTUnwrap(menus.contextMenuInteraction(interaction, configuration: configuration,
            dismissalPreviewForItemWithIdentifier: configuration.identifier))
        XCTAssertTrue(returned.view === view.avatar)
        XCTAssertEqual(returned.target.center, view.avatar.convert(CGPoint(x: view.avatar.bounds.midX, y: view.avatar.bounds.midY), to: returned.target.container))
        XCTAssertNotEqual(returned.target.center, lifted.target.center, "dismissal targets where the live avatar is now")
        menus.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
    }

    func testAProjectedTitleRefusesHiddenDisabledInertAndCoveredSources() throws {
        let (session, chat, view, interaction) = try titleMenu("title-eligibility")
        let p = session.presenter, source = try node(session, "title-group")
        let location = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        func configuration() -> UIContextMenuConfiguration? {
            p.menus.context.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
        }
        for prop in ["disabled", "inert"] {
            source.props[prop] = "true"
            XCTAssertNil(configuration(), prop)
            source.props[prop] = nil
        }
        view.isHidden = true
        XCTAssertNil(configuration(), "a retained title view is no visible menu surface")
        view.isHidden = false
        let cover = UIView(frame: try XCTUnwrap(view.window).bounds)
        view.window?.addSubview(cover)
        XCTAssertNil(configuration(), "the title behind an overlay cannot grant its source a menu")
        cover.removeFromSuperview()
        chat.navigationItem.titleView = UILabel()
        XCTAssertNil(configuration(), "a hatch's replacement retires the title's menu surface")
        chat.navigationItem.titleView = view
        let navigation = try XCTUnwrap(chat.navigationController)
        navigation.view.layoutIfNeeded()
        navigation.navigationBar.layoutIfNeeded()
        XCTAssertNotNil(view.window)
        XCTAssertTrue(view.isDescendant(of: navigation.navigationBar))
        let valid = try XCTUnwrap(configuration())
        p.menus.context.contextMenuInteraction(interaction, willEndFor: valid, animator: nil)
        p.apply(wireBatch([["op": "style", "id": source.id, "style": ["display": "none"]]]))
        XCTAssertNil(configuration(), "authored hiding cannot use the bar's hidden-source allowance")
    }

    private final class TitleCommit: NSObject, UIContextMenuInteractionCommitAnimating {
        var preferredCommitStyle: UIContextMenuInteractionCommitStyle = .pop
        var previewViewController: UIViewController? { nil }
        func addAnimations(_ animations: @escaping () -> Void) { animations() }
        func addCompletion(_ completion: @escaping () -> Void) { completion() }
    }

    func testADisabledTitleEndsItsPreviewAndCannotResumeItsOldMenu() throws {
        let (session, _, view, interaction) = try titleMenu("title-disabled-preview")
        let p = session.presenter, menus = p.menus.context
        let configuration = try configureTitle(session, view, interaction)
        let owner = try XCTUnwrap(menus.open), card = try node(session, "title-card")
        let preview = try XCTUnwrap(menus.lift(owner))
        XCTAssertTrue(card.superview === preview.view)
        let home = try XCTUnwrap(owner.container), source = try node(session, "title-group")
        p.apply(wireBatch([["op": "props", "id": source.id, "set": ["disabled": "true"]]]))
        XCTAssertNil(menus.open)
        XCTAssertTrue(card.superview === home)
        p.apply(wireBatch([["op": "props", "id": source.id, "clear": ["disabled"]]]))
        XCTAssertNil(menus.menu(owner), "reenabling a source does not resurrect its old presentation")
        XCTAssertNil(menus.lift(owner))
        menus.contextMenuInteraction(interaction, willPerformPreviewActionForMenuWith: configuration, animator: TitleCommit())
        XCTAssertEqual(text(session, "title-presses"), "title presses 0")
        let next = try configureTitle(session, view, interaction)
        XCTAssertNil(menus.contextMenuInteraction(interaction, configuration: configuration, dismissalPreviewForItemWithIdentifier: configuration.identifier))
        XCTAssertNotNil(menus.contextMenuInteraction(interaction, configuration: next, highlightPreviewForItemWithIdentifier: next.identifier))
        menus.contextMenuInteraction(interaction, willPerformPreviewActionForMenuWith: next, animator: TitleCommit())
        // With no lifted preview, a commit has no row to press.
        XCTAssertEqual(text(session, "title-presses"), "title presses 0")
        menus.contextMenuInteraction(interaction, willEndFor: next, animator: nil)
    }

    func testAPreviewCommitsOnlyForTheCurrentTitleAndReturnsAfterward() throws {
        let (session, chat, view, interaction) = try titleMenu("title-preview-commit")
        let menus = session.presenter.menus.context
        let configuration = try configureTitle(session, view, interaction)
        let owner = try XCTUnwrap(menus.open)
        _ = try XCTUnwrap(menus.lift(owner))
        menus.contextMenuInteraction(interaction, willPerformPreviewActionForMenuWith: configuration, animator: TitleCommit())
        until("the title preview pressed its authored row") { self.text(session, "title-presses") == "title presses 1" }
        menus.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
        let next = try configureTitle(session, view, interaction)
        let retired = try XCTUnwrap(menus.open), card = try node(session, "title-card")
        _ = try XCTUnwrap(menus.lift(retired))
        let home = try XCTUnwrap(retired.container)
        chat.navigationItem.titleView = UILabel()
        menus.sync()
        XCTAssertNil(menus.open)
        XCTAssertTrue(card.superview === home)
        menus.contextMenuInteraction(interaction, willPerformPreviewActionForMenuWith: next, animator: TitleCommit())
        XCTAssertEqual(text(session, "title-presses"), "title presses 1")
    }

    func testATitleHandlerCannotOpenItsMenuAfterReplacingTheSurface() throws {
        let (session, chat, view, interaction) = try titleMenu("title-handler-retires")
        let p = session.presenter, menus = p.menus.context
        let source = try node(session, "title-group")
        source.handlers.insert("contextmenu")
        var calls = 0
        p.onClipboard = { _, kind, _ in
            if kind == 10 { calls += 1; chat.navigationItem.titleView = UILabel() }
        }
        let configuration = try configureTitle(session, view, interaction)
        let owner = try XCTUnwrap(menus.open)
        XCTAssertNil(menus.menu(owner))
        XCTAssertEqual(calls, 1)
        XCTAssertNil(menus.lift(owner))
        menus.sync()
        XCTAssertNil(menus.open)
        chat.navigationItem.titleView = view
        XCTAssertNil(menus.menu(owner), "restoring the title cannot resurrect the menu its handler retired")
        menus.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
        p.apply(wireBatch([["op": "destroy", "id": source.id]]))
        XCTAssertNil(p.views[source.id])
        XCTAssertNil(p.navigation.projectedTitle(for: source))
        XCTAssertNil(menus.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero))
    }

    func testNavigationAndSourceRetirementInvalidateTheProjectedMenu() throws {
        let (session, _, view, interaction) = try titleMenu("title-retirement")
        let p = session.presenter, menus = p.menus.context
        let configuration = try configureTitle(session, view, interaction)
        let owner = try XCTUnwrap(menus.open), source = try node(session, "title-group")
        _ = try XCTUnwrap(menus.lift(owner))
        source.incarnation = NodePool.issue()
        menus.sync()
        XCTAssertNil(menus.open, "a reused source view is no longer this title's source")
        XCTAssertNil(menus.menu(owner))
        XCTAssertNil(menus.contextMenuInteraction(interaction, configuration: configuration, dismissalPreviewForItemWithIdentifier: configuration.identifier))
        // A fresh projection may own a new menu, without reviving the old one.
        p.apply(wireBatch([]))
        let nextInteraction = try XCTUnwrap(view.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
        let current = try configureTitle(session, view, nextInteraction)
        try tapNode(session, "chat-detail")
        until("Detail covers Chat") { !p.navigation.inTransition && p.navigation.projectedTitle(for: source) == nil }
        menus.sync()
        XCTAssertNil(menus.open)
        XCTAssertNil(menus.contextMenuInteraction(nextInteraction, configuration: current, dismissalPreviewForItemWithIdentifier: current.identifier))
        XCTAssertNotNil(Agent(session: session).tap(["id": Int(source.id), "contextmenu": true])["error"])
    }

    func testTheAgentsLongPressOnATitleUsesOnlyItsVisibleCurrentSource() throws {
        if !ExactEnv.agentPaints || ExactEnv.authoredChrome { throw XCTSkip("recognized title menus require --chrome platform with painted presentation") }
        let session = try fixture("title-recognized"), p = session.presenter
        let (_, _, chat) = try chat(session)
        let view = try XCTUnwrap(chat.navigationItem.titleView as? HeaderTitleView)
        let source = try node(session, "title-group"), popover = try XCTUnwrap(p.carrying("popover").first { $0.props["id"] == "title-menu" })
        let agent = Agent(session: session), request: [String: Any] = ["id": Int(source.id), "contextmenu": true]
        XCTAssertNil(agent.tap(request)["error"])
        XCTAssertTrue(p.menus.isOpen(popover))
        _ = agent.back()
        for prop in ["disabled", "inert"] {
            source.props[prop] = "true"
            XCTAssertNotNil(agent.tap(request)["error"], prop)
            XCTAssertFalse(p.menus.isOpen(popover))
            source.props[prop] = nil
        }
        let cover = UIView(frame: try XCTUnwrap(view.window).bounds)
        view.window?.addSubview(cover)
        XCTAssertNotNil(agent.tap(request)["error"])
        cover.removeFromSuperview()
        source.props["contextPopover"] = nil
        source.handlers.insert("contextmenu")
        var calls = 0
        p.onClipboard = { _, kind, _ in if kind == 10 { calls += 1 } }
        XCTAssertNotNil(agent.tap(request)["error"], "a bare handler is not a projected context popover")
        XCTAssertEqual(calls, 0)
        source.props["contextPopover"] = "title-menu"
        p.onClipboard = { _, kind, _ in
            if kind == 10 { calls += 1; chat.navigationItem.titleView = UILabel() }
        }
        XCTAssertNil(agent.tap(request)["error"], "the handler receives its long press")
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(p.menus.isOpen(popover), "its replacement title cannot open the old source's menu")
    }
}
#endif
