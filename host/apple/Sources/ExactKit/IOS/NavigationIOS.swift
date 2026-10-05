// @ref LLP 1008 §9; LLP 1035.001.000 — Contract routes projected into UIKit's
// containers, and what UIKit then shows read back. UIKit owns recognition,
// arbitration, progress and cancellation. The host has two directions: the
// app's routes to UIKit (`sync`, never while anything is in flight), and
// UIKit's settled state to the app (`settle`) — compared with what the host
// last applied, so any difference is the platform's, told to the app as the
// route it went back to, never as the gesture that took it there.
#if os(iOS)
import UIKit

private final class RouteController: UIViewController {
    let node: NodeView
    var key: String { node.props["navigationKey"] ?? "" }
    init(_ node: NodeView) {
        self.node = node
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = UIView()
        // The sheet supplies its surface behind transparent authored corners.
        // Dimming belongs outside that surface, to UIKit's presentation.
        view.backgroundColor = node.props["navigationPresentation"] == "modal"
            ? .secondarySystemGroupedBackground : node.color("background_color", .white)
        view.addSubview(node)
    }
    func mount() {
        loadViewIfNeeded()
        if node.superview !== view { view.addSubview(node) }
    }
    /// The route's native navigation bar (LLP 1038): a `navigationTitle`
    /// shows UIKit's bar with that title, large unless `navigationLargeTitle`
    /// is "false", and `navigationSubtitle` under it (iOS 26's subtitle,
    /// which the large title shows too); `navigationBackButton` "minimal"
    /// shows the chevron alone;
    /// the route's own `role="toolbar" toolbarPlacement="navigation-bar"`
    /// shows its buttons as the bar's items (`projectToolbar`).
    /// A route with no title keeps the bar hidden, as before; a blank one
    /// (" ", a title still loading) shows the bar with no words in it —
    /// UIKit draws a whitespace title as a pair of quotes.
    var hasBar: Bool { !(node.props["navigationTitle"] ?? "").isEmpty }
    func configure(backHidden: Bool, presenter: Presenter) {
        let item = navigationItem
        // D6: the back button and its menu show only where leaving is the
        // app's to permit; a route that refuses it has none to tap.
        if item.hidesBackButton != backHidden { item.setHidesBackButton(backHidden, animated: false) }
        let raw = node.props["navigationTitle"] ?? ""
        let title: String? = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
        if item.title != title { item.title = title }
        if #available(iOS 26.0, *) {
            let raw = node.props["navigationSubtitle"] ?? ""
            let subtitle: String? = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
            if item.subtitle != subtitle { item.subtitle = subtitle }
        }
        item.largeTitleDisplayMode = node.props["navigationLargeTitle"] == "false" ? .never : .always
        item.backButtonDisplayMode = node.props["navigationBackButton"] == "minimal" ? .minimal : .default
        projectToolbar(presenter)
        // Large titles collapse as the route's own scroll view scrolls under
        // the bar: UIKit insets it and tracks it as the content scroll view.
        guard hasBar, isViewLoaded, let scroll = firstScroll(in: node) else { return }
        if scroll.contentInsetAdjustmentBehavior != .automatic { scroll.contentInsetAdjustmentBehavior = .automatic }
        if contentScrollView(for: .top) !== scroll { setContentScrollView(scroll, for: .top) }
    }
    private func firstScroll(in root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView, view !== root { return scroll }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
    // MARK: The route's toolbar (LLP 1035.001.001 D6)

    /// The bar item each projected toolbar button is shown as, by view id —
    /// what a presentation it opens points at (`NavigationHost.barItem`).
    private(set) var barItems: [UInt32: UIBarButtonItem] = [:]
    private weak var projected: NodeView?
    private weak var host: Presenter?
    private var faces: [UInt32: String] = [:]
    private var refusal: String?
    /// The route's first direct child `role="toolbar"
    /// toolbarPlacement="navigation-bar"`, where the route shows UIKit's bar:
    /// its direct buttons become the bar's items — `toolbarPlacement=
    /// "navigation"` ones leading, after the back button, the rest trailing,
    /// in authored order — each mirroring its button every projection (its
    /// symbol or text, label, test id, enabled) and activating it as a tap
    /// would (`Presenter.press`; a menu's invoker opens the menu). The
    /// authored toolbar is hidden only once its items are installed;
    /// anything else (no bar, a second toolbar, a child that is not a
    /// button) keeps its authored rendering, refused in the journal once.
    private func projectToolbar(_ presenter: Presenter) {
        host = presenter
        let toolbars = node.container.subviews.compactMap { $0 as? NodeView }
            .filter { $0.props["accessibilityRole"] == "toolbar" && $0.props["toolbarPlacement"] == "navigation-bar" }
        let toolbar = toolbars.first
        let buttons = toolbar.map { $0.container.subviews.compactMap { $0 as? NodeView } } ?? []
        var why: String?
        if toolbar != nil && !hasBar { why = "the route shows no navigation bar (navigationTitle)" }
        else if toolbars.count > 1 { why = "a route has one navigation-bar toolbar; the first is projected" }
        if toolbar != nil, hasBar, buttons.isEmpty || !buttons.allSatisfy(\.isButton) { why = "a navigation-bar toolbar holds direct buttons only; keeping its authored rendering" }
        if why != refusal, let why { presenter.session?.log("toolbar refused: \(why)") }
        refusal = why
        guard let toolbar, hasBar, !buttons.isEmpty, buttons.allSatisfy(\.isButton) else {
            restoreToolbar()
            if !barItems.isEmpty { barItems = [:]; navigationItem.leftBarButtonItems = nil; navigationItem.rightBarButtonItems = nil }
            faces = [:]
            return
        }
        var next: [UInt32: UIBarButtonItem] = [:]
        for button in buttons {
            if barItems[button.id] == nil { faces[button.id] = nil }
            let item = barItems[button.id] ?? UIBarButtonItem()
            next[button.id] = item
            let face = button.isNativeButton ? button.face : nil
            let symbol = face?.symbol ?? button.container.subviews.compactMap { $0 as? NodeView }.first { $0.kind == "image" }?.props["symbolName"]
            let text = face?.shown ?? NavigationHost.text(of: button)
            let face_ = symbol.flatMap { $0.isEmpty ? nil : "symbol:\($0)" } ?? "text:\(text)"
            let label = button.props["accessibilityLabel"] ?? text
            if item.accessibilityLabel != label { item.accessibilityLabel = label }
            // Each property is set only as it changes: a reassigned item
            // rebuilds its button, which drops a touch already down on it.
            let identifier = button.props["testId"] ?? button.props["id"]
            if item.accessibilityIdentifier != identifier { item.accessibilityIdentifier = identifier }
            // UIKit shows a route's items only while it is on top; whether
            // the app has caught up with a pop is not the item's to say (a
            // tap in that moment activates once the route is selected).
            let enabled = presenter.activationRefusal(button, routeSelected: false) == nil
            if item.isEnabled != enabled { item.isEnabled = enabled }
            // Its face (a symbol, else its words) and what a tap does: the
            // button's activation, or its menu, which UIKit opens.
            let menu = presenter.menus.menu(for: button) != nil
            if faces[button.id] != face_ || (item.menu != nil) != menu {
                faces[button.id] = face_
                let image = face_.hasPrefix("symbol:") ? UIImage(systemName: String(face_.dropFirst(7))) : nil
                let title = image == nil ? text : ""
                if menu {
                    item.primaryAction = nil
                    item.image = image; item.title = image == nil ? text : nil
                    item.menu = presenter.menus.menu(for: button)
                } else {
                    item.menu = nil
                    let id = button.id
                    item.primaryAction = UIAction(title: title, image: image) { [weak self] _ in self?.host?.press(id) }
                }
            }
        }
        barItems = next
        faces = faces.filter { next[$0.key] != nil }
        let leading = buttons.filter { $0.props["toolbarPlacement"] == "navigation" }.compactMap { next[$0.id] }
        let trailing = buttons.filter { $0.props["toolbarPlacement"] != "navigation" }.compactMap { next[$0.id] }
        let item = navigationItem
        if !(item.leftBarButtonItems ?? []).elementsEqual(leading, by: ===) { item.leftBarButtonItems = leading.isEmpty ? nil : leading }
        if !(item.rightBarButtonItems ?? []).elementsEqual(trailing.reversed(), by: ===) { item.rightBarButtonItems = trailing.isEmpty ? nil : trailing.reversed() }
        if item.leftItemsSupplementBackButton != !leading.isEmpty { item.leftItemsSupplementBackButton = !leading.isEmpty }
        if projected !== toolbar { restoreToolbar(); projected = toolbar }
        toolbar.isHidden = true
        toolbar.accessibilityElementsHidden = true
    }
    private func restoreToolbar() {
        guard let toolbar = projected else { return }
        projected = nil
        toolbar.isHidden = false
        toolbar.accessibilityElementsHidden = false
    }

    // A button can remove a route before UIKit starts its pop. Preserve its
    // outgoing pixels for that transition; an interactive pop uses live views.
    func freeze() {
        guard isViewLoaded, let snapshot = view.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(snapshot)
    }
}

final class NavigationHost: NSObject, UINavigationControllerDelegate, UIGestureRecognizerDelegate, UITabBarControllerDelegate {
    unowned let presenter: Presenter
    private var primaryNavigation: UINavigationController?
    /// Tabbed routes (`navigationTab`): one container per tab under a tab
    /// bar controller (TabContainersIOS.swift), each showing its own tab's
    /// screens. A selected stack container's navigation controller is
    /// `primaryNavigation`; any other selected container leaves it nil.
    private var tabs: UITabBarController?
    private var tabContainers: [String: TabContainer] = [:]
    private var selectedContainer: TabContainer? { selectedTab.flatMap { tabContainers[$0] } }
    private var tabRoutes: [NodeView] = []
    private var selectedTab: String?
    private var presentedNavigations: [UINavigationController] = []
    private var modalNavigation: UINavigationController? { presentedNavigations.last }
    private var navigation: UINavigationController? { modalNavigation ?? primaryNavigation }
    /// Whether native navigation holds the screens: the app root is then no
    /// screen of its own, and never scrolls (each screen's root does).
    var holdsScreens: Bool { primaryNavigation != nil || tabs != nil }
    private var syncing = false
    private var mounting = false
    private weak var container: NodeView?
    private var routeIDs: [UInt32] = []
    private var controllers: [UInt32: RouteController] = [:]
    /// LLP 1035.001.000 D1 — the whole of the host's own navigation state:
    /// what it last set on UIKit (`applied`), a change UIKit made that the
    /// app has not been told yet (`owed`), and whether the app's tree moved
    /// while projection waited (`dirty`). In flight is UIKit's to say.
    private var applied: NavigationRules.Snapshot?
    private var owed: NavigationRules.Change?
    private var dirty = false
    private var settling = false
    private var delivering = false
    /// The last platform change told to the app, for `state.navigation`.
    private var reported: String?
    /// A presentation refused because the owner already presents (an alert,
    /// a popover, the share sheet): retried until it can start (D5).
    private var retrying = false
    /// The root key last journaled as matching no route, so a refusal is one
    /// line, not one per batch (LLP 1035.001 D6).
    private var refusedKey: String?
    /// A tab the person chose in the More list, owed at the next settle.
    private var moreChoice: String?

    init(presenter: Presenter) { self.presenter = presenter }

    /// Logical child-list edits leave declared, retained routes inside their
    /// controllers; newly added or no-longer-declared nodes use normal mounting.
    func ownsContainment(of node: NodeView, under parent: NodeView) -> Bool {
        parent === container && parent.props["navigationKey"] != nil &&
            node.props["navigationKey"] != nil && controllers[node.id]?.node === node
    }

    func prepare(_ batch: Batch) {
        guard let top = navigation?.topViewController as? RouteController else { return }
        if batch.ops.contains(where: { $0.op == .destroy && $0.id == top.node.id }) {
            top.freeze()
        }
    }

    /// Resolve the declared route stack once for both structural installation
    /// and later presentation. UIKit containment never becomes route state.
    private func projection(_ batch: Batch) -> (NodeView, [NodeView], Int, [RouteController])? {
        // LLP 1035.001.001 D2 — the first root is the page's navigator when
        // it is keyed; with no keyed child it is dormant (below).
        guard let root = presenter.root.subviews.first as? NodeView,
              root.props["navigationKey"] != nil else {
            // Retiring native ownership must not remove surviving content.
            // Restore the logical children before detaching the controller so
            // an editor remains in the same window through the handoff.
            if let container {
                for (index, node) in routeIDs.compactMap({ presenter.views[$0] }).enumerated() {
                    container.container.insertSubview(node, at: index)
                }
            }
            reset(clearFocus: container != nil)
            return nil
        }
        if container !== root {
            // A fresh owner after unmount must preserve focus requested while
            // offscreen. Replacing an existing root still retires its command.
            reset(clearFocus: container != nil)
            container = root
            routeIDs = root.container.subviews.compactMap { ($0 as? NodeView)?.id }
        }
        for op in batch.ops where op.op == .children && op.id == root.id {
            routeIDs = op.ids
        }
        var routes = routeIDs.compactMap { presenter.views[$0] }.filter { $0.props["navigationKey"] != nil }
        // No route among the root's children (a signed-out app shows its
        // sign-in as plain content): native containment retires, its views
        // leave the window, and the plain content is what shows and is
        // touched — never a stale stack over it.
        if routes.isEmpty {
            if primaryNavigation != nil || tabs != nil {
                let children = routeIDs.compactMap { presenter.views[$0] }
                reset(clearFocus: false)
                for (index, node) in children.enumerated() { root.container.insertSubview(node, at: index) }
            }
            return nil
        }
        // D1: the stack is the prefix through the route the root names; a
        // key that names none leaves the stack alone, and says so once.
        let rootKey = root.props["navigationKey"] ?? ""
        // Tabbed: every tab's stack is rendered, each row naming its tab; the
        // selected tab is the one holding the route the root names, and the
        // rules below apply to its rows alone.
        if routes.contains(where: { !($0.props["navigationTab"] ?? "").isEmpty }) {
            tabRoutes = routes
            let tab = routes.first(where: { $0.props["navigationKey"] == rootKey })?.props["navigationTab"]
                ?? selectedTab ?? routes.first?.props["navigationTab"] ?? ""
            selectedTab = tab
            routes = routes.filter { $0.props["navigationTab"] == tab }
        } else {
            tabRoutes = []
            selectedTab = nil
        }
        guard let range = NavigationRules.stack(routeKeys: routes.map { $0.props["navigationKey"] ?? "" }, selected: rootKey) else {
            if refusedKey != rootKey {
                refusedKey = rootKey
                presenter.session?.log("navigationKey \"\(rootKey)\" matches no route; the stack is unchanged")
            }
            return nil
        }
        refusedKey = nil
        let selected = range.upperBound - 1
        let wanted = routes[range].map(controller(for:))
        return (root, routes, selected, wanted)
    }

    private func controller(for node: NodeView) -> RouteController {
        let c = controllers[node.id] ?? RouteController(node)
        controllers[node.id] = c
        c.mount()
        c.configure(backHidden: !leavingPermitted(node), presenter: presenter)
        return c
    }

    private func makeNavigation() -> UINavigationController {
        let nav = UINavigationController()
        nav.setNavigationBarHidden(true, animated: false)
        nav.navigationBar.prefersLargeTitles = true
        nav.delegate = self
        nav.interactivePopGestureRecognizer?.delegate = self
        if #available(iOS 26.0, *) { nav.interactiveContentPopGestureRecognizer?.delegate = self }
        return nav
    }
    /// The tab bar controller over one container per tab, in the order the
    /// tabs' rows come. Each tab's root route names its container
    /// (`navigationContainer`, `navigationContainerProps`) and its item
    /// (`navigationTabTitle`, `navigationTabSymbol`,
    /// `navigationTabSelectedSymbol`); the tabs not selected show their own
    /// screens, through their first presented route.
    private func installTabs(root: NodeView, selected: String, wanted: [RouteController]) {
        if tabs == nil {
            var responder: UIResponder? = root
            while responder != nil && !(responder is UIViewController) { responder = responder?.next }
            guard let parent = responder as? UIViewController else { return }
            let controller = UITabBarController()
            controller.delegate = self
            // The More list shows a tab past the bar by pushing it, which no
            // tab bar delegate hears: its stack's own transitions settle (D3).
            controller.moreNavigationController.delegate = self
            parent.addChild(controller)
            attach(controller.view, root: root)
            controller.didMove(toParent: parent)
            tabs = controller
        }
        guard let tabs else { return }
        var order: [String] = []
        for node in tabRoutes {
            let tab = node.props["navigationTab"] ?? ""
            if !tab.isEmpty, !order.contains(tab) { order.append(tab) }
        }
        for tab in order {
            let rows = tabRoutes.filter { $0.props["navigationTab"] == tab }
            guard let first = rows.first else { continue }
            let kind = (first.props["navigationContainer"] ?? "").isEmpty ? "stack" : first.props["navigationContainer"]!
            // A module container's stand-in is replaced once the module has one.
            let current = tabContainers[tab]
            var fresh = false
            if current == nil || current!.kind != kind || (kind != "screen" && current is ScreenContainer),
               let made = makeContainer(kind, props: first.props["navigationContainerProps"] ?? ""),
               current == nil || current!.kind != kind || made is ModuleContainer {
                current?.stack?.delegate = nil
                tabContainers[tab] = made
                fresh = true
            }
            guard let container = tabContainers[tab] else { continue }
            let item = container.controller.tabBarItem!
            let title = first.props["navigationTabTitle"], symbol = first.props["navigationTabSymbol"] ?? ""
            let selectedSymbol = first.props["navigationTabSelectedSymbol"] ?? symbol
            if item.title != title { item.title = title }
            if item.accessibilityIdentifier != "\(symbol)|\(selectedSymbol)" {
                item.image = UIImage(systemName: symbol)
                item.selectedImage = UIImage(systemName: selectedSymbol)
                item.accessibilityIdentifier = "\(symbol)|\(selectedSymbol)"
            }
            if tab == selected {
                // A selected stack is driven by sync, animated; installation
                // only seeds a new one.
                if fresh || container.stack == nil {
                    container.show(wanted)
                    if let nav = container.stack { showBar(nav, animated: false) }
                }
            } else {
                container.show(rows.prefix { !["modal", "fullscreen"].contains($0.props["navigationPresentation"] ?? "") }.map(controller(for:)))
                if let nav = container.stack { showBar(nav, animated: false) }
            }
        }
        for tab in Array(tabContainers.keys) where !order.contains(tab) {
            tabContainers.removeValue(forKey: tab)?.stack?.delegate = nil
        }
        let controllers = order.compactMap { tabContainers[$0]?.controller }
        // The routes say which tabs there are; the order they show in is the
        // person's once they have rearranged them through More's Edit, as
        // UIKit keeps it — a presentation, as a sheet's detent is.
        let shown = tabs.viewControllers ?? []
        if shown.count != controllers.count || !controllers.allSatisfy({ c in shown.contains { $0 === c } }) {
            tabs.setViewControllers(controllers, animated: false)
            tabs.customizableViewControllers = controllers
        }
        // Selected by identity: a tab past the bar shows inside the More list.
        // The More list itself, open over the tab the app still selects, is
        // left open: it is the person's, as a menu would be.
        let moreList = tabs.selectedViewController === tabs.moreNavigationController && shownTab(of: tabs) == nil
        if let controller = tabContainers[selected]?.controller, shownTab(of: tabs) != selected,
           !(moreList && applied?.tab == selected) {
            tabs.selectedViewController = controller
        }
        // A stack tab past the bar is shown by the More list's own navigation
        // controller, which UIKit hands its screens to (and gives them back
        // when it leaves): that is the stack the routes drive while it does.
        let more = tabs.moreNavigationController
        primaryNavigation = moreTab(of: tabs) == selected && more.viewControllers.dropFirst().first is RouteController
            ? more : tabContainers[selected]?.stack
    }

    /// The controllers at the bottom of a stack that are UIKit's, not routes:
    /// the More list under a tab shown through it.
    private func held(_ nav: UINavigationController) -> [UIViewController] {
        nav === tabs?.moreNavigationController ? Array(nav.viewControllers.prefix(1)) : []
    }

    /// The More list open at its root over the tab the app still selects:
    /// UIKit's chrome, as a menu is, so neither reported nor undone.
    private var moreListOpen: Bool {
        guard let tabs, tabs.selectedViewController === tabs.moreNavigationController else { return false }
        return tabs.moreNavigationController.viewControllers.count <= 1 && applied?.tab == selectedTab
    }

    /// A tab's container: "stack", "screen", or the app module's own. A
    /// module container stands in as a plain screen until the module has
    /// loaded (navigation is told, and installs it then) or when the module
    /// has none by that name (logged once).
    private func makeContainer(_ kind: String, props: String) -> TabContainer? {
        switch kind {
        case "stack": return StackContainer(makeNavigation())
        case "screen": return ScreenContainer()
        default:
            guard let natives = presenter.session?.natives else { return ScreenContainer(kind: kind) }
            if let native = natives.container(named: kind, props: props) { return ModuleContainer(native) }
            natives.containersReady = { [weak self] in
                self?.sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
            }
            return ScreenContainer(kind: kind)
        }
    }

    /// The agent's root-scoped taps on the chrome (LLP 1035.001.001 D7): the
    /// back button UIKit shows, popped as UIKit's own button pops (observed
    /// and delivered as any other Back), or a tab, chosen as the tab bar
    /// chooses it. Refused where a person could not: no back button, a
    /// presentation over the bar, a transition in flight, no such tab.
    func chromeTap(_ node: NodeView, what: String, name: String?) -> [String: Any] {
        guard node === container else { return ["error": "chrome taps address the navigator (the first root, keyed)"] }
        if chromeCovered || inFlight || owed != nil { return ["error": "a presentation or transition covers the chrome"] }
        if what == "escape" {
            // The close request on the topmost presentation: back beneath
            // the sheet (or cover) on top, whatever it pushed (D4).
            guard let chain = appSnapshot()?.chain, let routes = Optional(routeIDs.compactMap { presenter.views[$0] }),
                  let at = chain.lastIndex(where: { k in ["modal", "fullscreen"].contains(routes.first { $0.props["navigationKey"] == k }?.props["navigationPresentation"] ?? "") }),
                  at > 0 else { return ["error": "nothing is presented"] }
            guard permitsBack(to: chain[at - 1]) else { return ["error": "Back refused: closedby=\"none\", or the navigator does not hear traverse"] }
            owed = .backTo(chain[at - 1])
            deliver()
            sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
            return ["delivery": "chrome"]
        }
        if what == "tab" {
            guard let name, tabRoutes.contains(where: { $0.props["navigationTab"] == name }) else { return ["error": "no tab \(name ?? "") in the tab bar"] }
            guard presentedNavigations.isEmpty else { return ["error": "a sheet covers the tab bar"] }
            return selectTab(name) ? ["delivery": "chrome"] : ["error": "tabselect refused: the navigator does not hear it"]
        }
        guard backButtonShown, let nav = navigation else { return ["error": "no back button is shown"] }
        nav.popViewController(animated: !ExactEnv.agentFreezes)
        return ["delivery": "chrome"]
    }
    /// Whether UIKit shows a back button on the top screen: what a person
    /// could tap, and what `state.navigation.back` reports.
    private var backButtonShown: Bool {
        guard let nav = navigation, nav.presentedViewController == nil, !nav.isNavigationBarHidden,
              let top = nav.topViewController as? RouteController else { return false }
        return nav.viewControllers.count > held(nav).count + 1 && !top.navigationItem.hidesBackButton
    }
    /// Something that is not a route covers the chrome — an alert, a
    /// popover, a menu, the share sheet — so a person could not reach it.
    var chromeCovered: Bool {
        if presenter.menus.observation() != nil { return true }
        var controller: UIViewController? = tabs ?? primaryNavigation
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            if !presentedNavigations.contains(where: { $0 === presented }) { return true }
            controller = presented
        }
        return false
    }

    /// LLP 1035.001.001 D5: a tab chosen in the tab bar — or the More list,
    /// the one shown included — is the navigator's `tabselect`; the app
    /// selects (`select`: the tab's retained stack, or its root on a
    /// reselect) and the projection follows. Opening More is UIKit's chrome.
    @discardableResult
    private func selectTab(_ tab: String) -> Bool {
        reported = "select \(tab)"
        guard let root = container, root.handlers.contains("tabselect") else {
            presenter.session?.log("navigation: tab \"\(tab)\" refused: the navigator does not hear tabselect")
            return false
        }
        presenter.onTabSelect?(root.id, tab)
        return true
    }
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if viewController === tabBarController.moreNavigationController { return true }
        guard let tab = tabContainers.first(where: { $0.value.controller === viewController })?.key else { return false }
        selectTab(tab)
        return false
    }

    /// UIKit selected something itself (the More list): a settle point.

    /// The person rearranged the tabs through More's Edit: UIKit keeps the
    /// order (the observation reports it); what is selected is settled.
    func tabBarController(_ tabBarController: UITabBarController, didEndCustomizing viewControllers: [UIViewController], changed: Bool) { settle() }

    /// The app's root container (its tab bar controller, or its navigation
    /// controller) is the host's own child, its view beside the session's —
    /// over it, at its frame — never a view inside the viewport's scroller.
    private func attach(_ view: UIView, root: NodeView) {
        var current: UIView? = root
        while let v = current, !(v is ExactView) { current = v.superview }
        guard let session = current, let stage = session.superview else {
            if view.superview !== root { root.addSubview(view) }
            view.frame = root.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.bringSubviewToFront(view)
            return
        }
        if view.superview !== stage { stage.insertSubview(view, aboveSubview: session) }
        if view.frame != session.frame { view.frame = session.frame }
        view.autoresizingMask = session.autoresizingMask
    }

    private func installPrimary(root: NodeView, wanted: [RouteController]) {
        if let selectedTab { installTabs(root: root, selected: selectedTab, wanted: wanted); return }
        guard primaryNavigation == nil else { return }
        // Find the containing controller before installing our child.
        var responder: UIResponder? = root
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let parent = responder as? UIViewController else { return }
        let nav = UINavigationController()
        nav.setNavigationBarHidden(true, animated: false)
        nav.navigationBar.prefersLargeTitles = true
        nav.delegate = self
        parent.addChild(nav)
        attach(nav.view, root: root)
        nav.didMove(toParent: parent)
        primaryNavigation = nav
        nav.setViewControllers(wanted, animated: false)
        // A hidden navigation bar needs its availability check here. The
        // recognizer, competing scroll views and transition stay UIKit's.
        nav.interactivePopGestureRecognizer?.delegate = self
        if #available(iOS 26.0, *) { nav.interactiveContentPopGestureRecognizer?.delegate = self }
        applied = observe()
    }

    /// Initial containment is ready before child frames. It does not present
    /// a sheet or flush focus commands from the partially applied batch.
    func installInitialOwner(_ batch: Batch) {
        guard primaryNavigation == nil, tabs == nil, !syncing, presenter.session?.view?.window != nil else { return }
        syncing = true
        defer { syncing = false }
        guard let (root, routes, selected, wanted) = projection(batch) else { return }
        let parts = NavigationRules.segments(presentations: routes[...selected].map { $0.props["navigationPresentation"] })
        installPrimary(root: root, wanted: Array(wanted[parts[0]]))
        (tabs?.view ?? primaryNavigation?.view)?.layoutIfNeeded()
        applied = observe()
    }

    func sync(_ batch: Batch) {
        // A commit made while the host delivers or projects still moves the
        // routes it will project next.
        if let root = container {
            for op in batch.ops where op.op == .children && op.id == root.id { routeIDs = op.ids }
        }
        // Installing or moving a controller can synchronously cause layout.
        // That layout must not start another containment handoff inside this one.
        guard !syncing, !delivering, presenter.session?.view?.window != nil else { return }
        syncing = true
        defer { syncing = false; presenter.flushPendingFocus() }
        guard let (root, routes, selected, wanted) = projection(batch) else { return }
        // D5: nothing is projected over a platform change the app has not been
        // told, nor under a transition; the latest tree is projected once it
        // settles. The first installation has nothing to wait for.
        if holdsScreens, owed != nil || settling || inFlight {
            dirty = true
            return
        }
        dirty = false
        let parts = NavigationRules.segments(presentations: routes[...selected].map { $0.props["navigationPresentation"] })
        installPrimary(root: root, wanted: Array(wanted[parts[0]]))
        defer { applied = observe() }
        // Initial content draws before presentation takes over its viewport.
        if parts.count > 1, let session = presenter.session, session.firstDrawMs == nil { return }
        let boundaries = parts.dropFirst().map { wanted[$0.lowerBound].node }
        let mounted = presenter.modals.routes
        let common = zip(boundaries, mounted).prefix {
            $0.0 === $0.1.node && $0.0.props["navigationPresentation"] == $0.1.kind
        }.count
        // Mount the destination under a departing presentation before starting
        // dismissal, so its editor can accept the batch's focus handoff.
        // A selected tab container that is not a stack shows its screens its
        // own way; the stacks it may present still sync below.
        let owners: [UINavigationController?] = [primaryNavigation] + presentedNavigations
        if primaryNavigation == nil, let selectedContainer { selectedContainer.show(Array(wanted[parts[0]])) }
        for index in 0...common where index < owners.count {
            guard let nav = owners[index], !(index == 0 && moreListOpen) else { continue }
            let stack = held(nav) + Array(wanted[parts[index]])
            let same = nav.viewControllers.count == stack.count && zip(nav.viewControllers, stack).allSatisfy { $0 === $1 }
            if !same {
                // @ref LLP 1038 D6 — a tab change swaps immediately. A replacement within one stack
                // whose new top was not on it (a finished screen giving way to its result) arrives
                // as UIKit's own push, rather than cutting.
                let pushOrPop = NavigationRules.isPushOrPop(from: nav.viewControllers.map(ObjectIdentifier.init), to: stack.map(ObjectIdentifier.init))
                let arrives = stack.count > 1 && nav.viewControllers.first === stack.first
                    && !nav.viewControllers.contains { $0 === stack.last }
                nav.setViewControllers(stack, animated: (pushOrPop || arrives) && index == owners.count - 1 && mounted.count == boundaries.count && !ExactEnv.agentFreezes && nav.view.window != nil)
                // D5: what UIKit reports is what was applied; a call it did
                // not take is the host's, never mistaken for the person's.
                if nav.viewControllers.count != stack.count || !zip(nav.viewControllers, stack).allSatisfy({ $0 === $1 }) {
                    presenter.session?.log("navigation: UIKit did not take the stack the routes name")
                }
            }
            showBar(nav, animated: false)
            nav.view.layoutIfNeeded()
        }
        if mounted.count > common {
            dirty = true
            presenter.modals.closeTop()
            return
        }
        // Under tabs, the first presentation is over the whole tab bar
        // controller, and its owner is the tab bar controller's parent.
        let background: UIViewController? = presentedNavigations.isEmpty && tabs != nil ? tabs : navigation
        if boundaries.count > mounted.count, let background, let owner {
            let source = (navigation?.topViewController as? RouteController) ?? wanted[parts[0]].last
            let part = parts[mounted.count + 1], route = wanted[part.lowerBound].node
            // D5: an alert, a popover or the share sheet over the owner defers
            // the sheet; it starts once that has gone (B6).
            guard presenter.modals.canPresent(from: owner, route: route) else { dirty = true; retry(); return }
            let nav = makeNavigation()
            owner.addChild(nav)
            root.addSubview(nav.view)
            nav.view.frame = root.bounds
            nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            nav.didMove(toParent: owner)
            presentedNavigations.append(nav)
            nav.setViewControllers(Array(wanted[part]), animated: false)
            showBar(nav, animated: false)
            nav.view.layoutIfNeeded()
            dirty = boundaries.count > mounted.count + 1
            let preceding = part.lowerBound > 0 ? wanted[part.lowerBound - 1].node : nil
            presenter.modals.present(route, navigation: nav, from: background, node: source?.node,
                                     preceding: preceding, owner: owner)
        }
        if let tabs, presentedNavigations.isEmpty {
            attach(tabs.view, root: root)
            tabs.view.layoutIfNeeded()
        } else if let nav = navigation {
            if nav === primaryNavigation { attach(nav.view, root: root) } else {
                nav.view.frame = root.bounds
                root.bringSubviewToFront(nav.view)
            }
            nav.view.layoutIfNeeded()
        }
        controllers = controllers.filter { routeIDs.contains($0.key) }
        presenter.modals.updatePermissions()
    }

    var owner: UIViewController? { presenter.modals.owner ?? tabs?.parent ?? primaryNavigation?.parent }

    /// UIKit's bar shows for a route that declares a title, and hides for one
    /// that does not, as each becomes the top of its stack.
    private func showBar(_ nav: UINavigationController, for controller: UIViewController? = nil, animated: Bool) {
        // The More list's own bar (its title, Edit) is UIKit's.
        guard let route = (controller ?? nav.topViewController) as? RouteController else { return }
        let hidden = !route.hasBar
        if nav.isNavigationBarHidden != hidden { nav.setNavigationBarHidden(hidden, animated: animated) }
    }

    /// The bar item a route's toolbar button is shown as (LLP 1035.001.001
    /// D6): what a presentation it opens points at.
    func barItem(for node: NodeView) -> UIBarButtonItem? {
        controllers.values.lazy.compactMap { $0.barItems[node.id] }.first
    }
    /// A button's words, for a bar item that has no symbol.
    static func text(of node: NodeView) -> String {
        if node.kind == "text" { return node.paragraphSpec().runs.map(\.text).joined() }
        return node.container.subviews.compactMap { ($0 as? NodeView).map(text(of:)) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func willMount() { mounting = true }

    func mounted() {
        mounting = false
        sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
    }

    func unmounted() {
        mounting = false
        let root = container
        let children = routeIDs.compactMap { presenter.views[$0] }
        reset(clearFocus: false)
        // Release controller containment while preserving the actual nodes.
        // Offscreen batches now reconcile their ordinary logical child list.
        if let root, presenter.views[root.id] === root {
            for (index, node) in children.enumerated() where presenter.views[node.id] === node {
                root.container.insertSubview(node, at: index)
            }
        }
    }

    /// A presentation began, ended, or was dismissed by the platform: a
    /// settle point (D3).
    func modalDidDismiss() { settle() }

    /// Retire only the named owner; a late completion cannot remove its
    /// successor or the retained owner beneath it.
    func retireNavigation(_ controller: UIViewController, preserving: Bool) {
        guard let nav = controller as? UINavigationController,
              presentedNavigations.contains(where: { $0 === nav }) else { return }
        presentedNavigations.removeAll { $0 === nav }
        nav.delegate = nil
        if !preserving {
            nav.willMove(toParent: nil)
            nav.view.removeFromSuperview()
            nav.removeFromParent()
        }
    }

    /// The removed editor stays in its outgoing presentation while the
    /// viewport returns independently to the destination owner.
    func preserveModalContent(in parent: UIViewController) -> UIViewController? {
        guard let nav = presentedNavigations.first(where: { $0.parent === parent }) else { return nil }
        let frame = nav.view.convert(nav.view.bounds, to: parent.view)
        parent.view.insertSubview(nav.view, at: 0)
        nav.view.frame = frame
        nav.view.accessibilityElementsHidden = true
        return nav
    }

    /// Every navigation controller the host owns.
    private var stacks: [UINavigationController] {
        (tabs.map { [$0.moreNavigationController] + tabContainers.values.compactMap(\.stack) } ?? [primaryNavigation].compactMap { $0 })
            + presentedNavigations
    }
    /// D1: in flight is UIKit's to say — a stack's or the tab bar
    /// controller's transition coordinator, a presentation's — never a flag
    /// a callback that did not come could leave set.
    private var inFlight: Bool {
        presenter.modals.inTransition || tabs?.transitionCoordinator != nil
            || tabs?.moreNavigationController.transitionCoordinator != nil
            || stacks.contains { $0.transitionCoordinator != nil }
    }
    /// Focus waits through controller installation as well as UIKit's push/pop.
    /// `clock settle` observes the asynchronous part under platform timing.
    var defersFocus: Bool { syncing || mounting || delivering || (holdsScreens && inFlight) }
    var inTransition: Bool { defersFocus || dirty || settling || owed != nil }

    /// For `state.navigation` (LLP 1035.002 D2; LLP 1035.001.000 D9): the
    /// route the root names, UIKit's stack by key, what UIKit shows, what the
    /// host last applied, what the app's tree asks, a change not yet told,
    /// and the last one that was — observations.
    func observation() -> [String: Any] {
        let stack = (navigation?.viewControllers ?? []).compactMap { ($0 as? RouteController)?.key }
        let transition: [String: Any] = ["interactive": navigation?.transitionCoordinator?.isInteractive ?? false,
                                         "phase": inTransition || presenter.modals.inTransition ? "in-progress" : "idle"]
        let root = container ?? presenter.root.subviews.first as? NodeView
        func json(_ s: NavigationRules.Snapshot?) -> Any {
            guard let s else { return NSNull() }
            return ["tab": s.tab ?? NSNull(), "stack": s.stack, "presented": s.presented] as [String: Any]
        }
        let change: (NavigationRules.Change?) -> Any = {
            switch $0 {
            case .backTo(let key)?: return "backTo \(key)"
            case .select(let tab)?: return "select \(tab)"
            case nil: return NSNull()
            }
        }
        return ["route": root?.props["navigationKey"] ?? NSNull(), "stack": stack, "transition": transition,
                "native": json(holdsScreens ? observe() : nil), "applied": json(applied), "app": json(appSnapshot()),
                "owed": change(owed), "reported": reported ?? NSNull(),
                "back": backButtonShown && !chromeCovered && !inFlight && owed == nil,
                "tabs": tabs.map { tabOrder(of: $0) } ?? NSNull()]
    }

    func move(to parent: UIViewController, mount: () -> Void) {
        let moving: UIViewController? = tabs != nil && presentedNavigations.isEmpty ? tabs : navigation
        guard let nav = moving, nav.parent !== parent else { mount(); return }
        let container = nav.view.superview
        nav.willMove(toParent: nil)
        nav.view.removeFromSuperview()
        nav.removeFromParent()
        parent.addChild(nav)
        mount()
        container?.addSubview(nav.view)
        nav.didMove(toParent: parent)
    }

    /// A sheet's backdrop asks to leave the presentation the route opens, as
    /// pulling it down does: back to the route beneath it.
    func requestBack(from source: NodeView) {
        guard presenter.session?.view?.window != nil, presenter.views[source.id] === source,
              let key = source.props["navigationKey"], let chain = appSnapshot()?.chain,
              let index = chain.firstIndex(of: key), index > 0, owed == nil else { return }
        owed = .backTo(chain[index - 1])
        deliver()
        sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
    }

    /// LLP 1035.001.001 D3: whether the platform may take the person back to
    /// `key` — the navigator hears `traverse`, and no route that Back removes
    /// (each above `key` in the app's chain) says `closedby="none"`.
    func permitsBack(to key: String) -> Bool {
        guard let chain = appSnapshot()?.chain, let at = chain.firstIndex(of: key), at < chain.count - 1 else { return false }
        let routes = routeIDs.compactMap { presenter.views[$0] }
        let removed = chain[(at + 1)...].map { k in routes.first { $0.props["navigationKey"] == k }?.props["closedby"] }
        return NavigationRules.backPermitted(removing: removed, traverses: container?.handlers.contains("traverse") == true)
    }
    /// Whether the platform may take the person off `route` — what its back
    /// button, a swipe from it, or (for a sheet's lowest route) its pull-down
    /// asks: back to the route beneath it in the chain.
    func leavingPermitted(_ route: NodeView) -> Bool {
        guard let key = route.props["navigationKey"], let chain = appSnapshot()?.chain,
              let at = chain.firstIndex(of: key), at > 0 else {
            return NavigationRules.backPermitted(removing: [route.props["closedby"]], traverses: container?.handlers.contains("traverse") == true)
        }
        return permitsBack(to: chain[at - 1])
    }
    /// Whether leaving the active route is permitted: what the swipe asks
    /// before it may begin.
    var backPermittedNow: Bool {
        guard let chain = appSnapshot()?.chain, chain.count > 1 else { return false }
        return permitsBack(to: chain[chain.count - 2])
    }

    var preservesKeyboardViewport: Bool {
        NavigationRules.freezesViewport(modalActive: presenter.modals.active, inFlight: inFlight,
                                        initiallyInteractive: navigation?.transitionCoordinator?.initiallyInteractive == true)
    }

    /// The key of the route a view is mounted under, for `layout <node>`
    /// (LLP 1035.002 D1) — an observation of UIKit's containment.
    func routeKey(containing view: UIView) -> String? {
        var responder: UIResponder? = view
        while let current = responder {
            if let route = current as? RouteController { return route.key }
            responder = current.next
        }
        return nil
    }

    /// The navigator whose routes UIKit holds, in the logical tree.
    var navigator: NodeView? { container }

    func isInactiveRoute(containing view: UIView) -> Bool {
        guard let selected = container?.props["navigationKey"],
              let key = routeKey(containing: view) else { return false }
        return key != selected
    }


    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let depth = navigation?.viewControllers.count ?? 0
        let permitted = backPermittedNow
        guard NavigationRules.popMayBegin(depth: depth, inFlight: inFlight || owed != nil, modalActive: presenter.modals.inTransition,
                                          permitted: permitted,
                                          contextPreviewActive: !presenter.chrome.ids("contextTarget").isEmpty) else {
            if depth > 1, !inFlight, !permitted {
                presenter.session?.log("back gesture refused: the navigator does not hear traverse, or the route says closedby=\"none\"")
            }
            return false
        }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view {
            let location = pan.location(in: view), delta = pan.translation(in: view)
            let start = CGPoint(x: location.x - delta.x, y: location.y - delta.y)
            var overSwipeRight = false
            var hit = view.hitTest(start, with: nil)
            if CanvasInput.owns(hit) { return false }
            while let current = hit {
                if let node = current as? NodeView, node.handlers.contains("swiperight") { overSwipeRight = true; break }
                if current === view { break }
                hit = current.superview
            }
            return NavigationRules.panMayBegin(startX: start.x, overSwipeRight: overSwipeRight, velocity: pan.velocity(in: pan.view))
        }
        return true
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        guard stacks.contains(where: { $0 === navigationController }) else { return }
        // LLP 1035.001.001 D5: a tab chosen in the More list, the one shown
        // included, is a choice — seen as UIKit shows it from the list, not
        // inferred from what the stack became — owed at the settle.
        // The host's own projection through More (`syncing`, a delivery's
        // batch) is not a choice.
        if let tabs, navigationController === tabs.moreNavigationController, !syncing, !delivering,
           let list = navigationController.viewControllers.first, viewController !== list,
           (navigationController.transitionCoordinator?.viewController(forKey: .from)
               ?? (animated ? nil : navigationController.viewControllers.count == 2 ? list : nil)) === list {
            moreChoice = (viewController as? RouteController)?.node.props["navigationTab"]
                ?? tabContainers.first(where: { $0.value.controller === viewController })?.key
        }
        showBar(navigationController, for: viewController, animated: animated)
        // Completed or cancelled, the transition's end is a settle point.
        navigationController.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.settle() }
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        guard stacks.contains(where: { $0 === navigationController }) else { return }
        // A cancelled swipe ends on its source, whose bar returns with it.
        showBar(navigationController, animated: false)
        presenter.session?.view?.fit()
        presenter.flushPendingFocus()
        settle()
    }

    /// D3: a settle point. On the next turn — outside UIKit's callback, its
    /// coordinator gone — read what UIKit shows. If it differs from what the
    /// host applied, the platform changed it: tell the app first (D4), then
    /// project the app's latest tree (D5). Idempotent: called twice over one
    /// state, it owes nothing the second time.
    func settle() {
        guard !settling else { return }
        settling = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            settling = false
            guard holdsScreens, container != nil, presenter.session?.view?.window != nil, !syncing, !delivering else { return }
            // Its own completion settles again.
            if inFlight {
                for nav in stacks { nav.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.settle() } }
                return
            }
            let observed = observe()
            if let tab = moreChoice {
                moreChoice = nil
                if owed == nil { owed = .select(tab) }
            } else if let applied, owed == nil, let change = NavigationRules.platformChange(applied: applied, observed: observed) {
                owed = change
            }
            applied = observed
            deliver()
            sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
            presenter.session?.view?.fit()
            presenter.flushPendingFocus()
        }
    }

    /// D4: tell the app what the platform did, once, through what the app
    /// declared — its root's `traverse` with the destination's key, or else
    /// its Back control, resolved anew, until the destination is the top —
    /// with projection suspended until it has answered. A destination, never
    /// a count (I1).
    private func deliver() {
        guard let change = owed else { return }
        owed = nil
        delivering = true
        defer { delivering = false }
        switch change {
        case .select(let tab):
            selectTab(tab)
        case .backTo(let key):
            guard let chain = appSnapshot()?.chain, NavigationRules.isBeneath(key, in: chain) else {
                // The app has gone elsewhere since: its state wins.
                return
            }
            reported = "backTo \(key)"
            // LLP 1035.001.001 D3/D4: one `traverse`, where leaving is
            // permitted; a refused Back (a route it removes says
            // `closedby="none"`, or nothing hears it) is not delivered, and
            // the projection that follows puts the screens back.
            guard let root = container, permitsBack(to: key) else {
                presenter.session?.log("navigation: back to \"\(key)\" refused: the navigator does not hear traverse, or a route it removes says closedby=\"none\"")
                return
            }
            presenter.onTraverse?(root.id, key)
            if appSnapshot()?.chain.last != key { presenter.session?.log("navigation: traverse to \"\(key)\" left the app elsewhere") }
        }
    }

    /// D2: what UIKit shows now, by route key — never a callback's argument.
    private func observe() -> NavigationRules.Snapshot {
        let keys = { (controllers: [UIViewController]) in controllers.compactMap { ($0 as? RouteController)?.key } }
        var tab: String?, stack: [String] = []
        if let tabs {
            tab = shownTab(of: tabs) ?? applied?.tab
            let more = tabs.moreNavigationController
            if moreListOpen {
                stack = applied?.stack ?? []
            } else if moreTab(of: tabs) == tab, more.viewControllers.dropFirst().first is RouteController {
                stack = keys(more.viewControllers)
            } else if let container = tab.flatMap({ tabContainers[$0] }) {
                stack = keys(container.stack?.viewControllers ?? container.screens)
            }
        } else if let primaryNavigation {
            stack = keys(primaryNavigation.viewControllers)
        }
        return .init(tab: tab, stack: stack, presented: presentedNavigations.map { keys($0.viewControllers) })
    }

    /// The tab UIKit shows: the selected container's, or the one shown inside
    /// the More list. The More list alone is UIKit's chrome over the tabs, not
    /// a route: nil, and the snapshot keeps the tab it had.
    private func shownTab(of tabs: UITabBarController) -> String? {
        if tabs.selectedViewController === tabs.moreNavigationController { return moreTab(of: tabs) }
        return tabs.selectedViewController.flatMap { c in tabContainers.first { $0.value.controller === c }?.key }
    }

    /// The tab the More list's navigation controller shows past its list: a
    /// stack tab's screens, which UIKit hands it, or another container whole.
    private func moreTab(of tabs: UITabBarController) -> String? {
        guard let first = tabs.moreNavigationController.viewControllers.dropFirst().first else { return nil }
        if let route = first as? RouteController { return route.node.props["navigationTab"] }
        return tabContainers.first { $0.value.controller === first }?.key
    }

    /// The tabs in the order UIKit shows them — the person's, once they have
    /// rearranged them through More's Edit.
    private func tabOrder(of tabs: UITabBarController) -> [String] {
        (tabs.viewControllers ?? []).compactMap { c in tabContainers.first { $0.value.controller === c }?.key }
    }

    /// The same snapshot, of the app's tree: its selected tab, the stack
    /// through the route the root names up to its first presentation, then
    /// each presentation's own.
    private func appSnapshot() -> NavigationRules.Snapshot? {
        guard let root = container else { return nil }
        var routes = routeIDs.compactMap { presenter.views[$0] }.filter { $0.props["navigationKey"] != nil }
        let rootKey = root.props["navigationKey"] ?? ""
        var tab: String?
        if routes.contains(where: { !($0.props["navigationTab"] ?? "").isEmpty }) {
            tab = routes.first(where: { $0.props["navigationKey"] == rootKey })?.props["navigationTab"] ?? selectedTab
            routes = routes.filter { $0.props["navigationTab"] == tab }
        }
        let keys = routes.map { $0.props["navigationKey"] ?? "" }
        guard let range = NavigationRules.stack(routeKeys: keys, selected: rootKey) else { return nil }
        let parts = NavigationRules.segments(presentations: routes[range].map { $0.props["navigationPresentation"] })
        return .init(tab: tab, stack: Array(keys[parts[0]]), presented: parts.dropFirst().map { Array(keys[$0]) })
    }

    /// D5: a sheet waiting on an owner that already presents starts once that
    /// has gone. Menus, popovers and the share sheet settle as they leave;
    /// this catches whatever else UIKit or the app's module put there.
    private func retry() {
        guard !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            retrying = false
            if dirty, container != nil { settle() }
        }
    }

    func reset(clearFocus: Bool = true) {
        moreChoice = nil
        presenter.modals.reset()
        for nav in presentedNavigations { retireNavigation(nav, preserving: false) }
        for container in tabContainers.values { container.stack?.delegate = nil }
        if let tabs {
            tabs.delegate = nil
            tabs.willMove(toParent: nil)
            tabs.view.removeFromSuperview()
            tabs.removeFromParent()
            self.tabs = nil
            primaryNavigation = nil
        }
        tabContainers.removeAll()
        tabRoutes = []
        selectedTab = nil
        primaryNavigation?.delegate = nil
        primaryNavigation?.willMove(toParent: nil)
        primaryNavigation?.view.removeFromSuperview()
        primaryNavigation?.removeFromParent()
        primaryNavigation = nil
        container = nil
        controllers.removeAll()
        routeIDs = []
        applied = nil
        owed = nil
        dirty = false
        reported = nil
        if clearFocus { presenter.cancelPendingFocus() }
    }
}

#endif
