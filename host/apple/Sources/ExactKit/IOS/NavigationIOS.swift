// @ref LLP 1008 §9; LLP 1035.001.000 — Contract routes projected into UIKit's
// containers, and what UIKit then shows read back. UIKit owns recognition,
// arbitration, progress and cancellation. The host has two directions: the
// app's routes to UIKit (`sync`, never while anything is in flight), and
// UIKit's settled state to the app (`settle`, NavigationSettleIOS.swift) —
// compared with what the host last applied, so any difference is the
// platform's, told to the app as the route it went back to, never as the
// gesture that took it there. The bar a stack shows, what a route projects
// into it and when the app module's hooks run are LLP 1075.003's
// (NavigationBarIOS.swift, NativeHooks.swift).
#if os(iOS) || os(tvOS)
import UIKit

final class RouteController: UIViewController {
    let node: NodeView
    var key: String { node.props["navigationKey"] ?? "" }
    /// What Exact last projected into the navigation item, and that plus the
    /// words the route hook last saw; whether the hook has run; the header
    /// lifted into the bar; the content scroll view a hook was handed.
    var projectedSource: String?, projected: String?, backSource: String?
    var hooked = false
    weak var lifted: NodeView?
    weak var host: NavigationHost?
    weak var ownedScroll: NodeView?
    /// The scroller a large title collapses with (LLP 1075.003 Stage 3).
    weak var collapseScroll: NodeView?
    /// The targets of the bar items projected from its header.
    var barPresses: [BarPress] = []
    /// The header's search field as UIKit's search controller (§9.6).
    var search: HeaderSearch?
    /// The title Exact drew from the heading's group, and the subtitle it
    /// wrote; whether the root's tablist was hidden when it last looked (§9.10).
    var titleView: HeaderTitleView?, subtitle: String?, tablistHidden: Bool?
    init(_ node: NodeView) {
        self.node = node
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    // The bar's height changed (a push to an inline title, a rotation, a
    // hook): the route's content area follows (LLP 1075.003 §3.5).
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        host?.coversChanged()
    }
    override func loadView() {
        view = UIView()
        // The sheet supplies its surface behind transparent authored corners.
        // Dimming belongs outside that surface, to UIKit's presentation.
        // A dynamic colour: the route's own background resolved for the
        // controller's current appearance, re-resolved by UIKit when it
        // changes (a route loaded before its window has a trait collection
        // would otherwise keep the light colour in dark mode). A route
        // without one shows the system background, not white.
        #if os(tvOS)
        // tvOS has no system backgrounds; white stands in, as the viewport's.
        view.backgroundColor = node.props["navigationPresentation"] == "modal"
            ? .white
            : UIColor { [weak node] traits in
                node?.channels("background_color", dark: traits.userInterfaceStyle == .dark).map { TextEngine.color($0) } ?? .white
            }
        #else
        view.backgroundColor = node.props["navigationPresentation"] == "modal"
            ? .secondarySystemGroupedBackground
            : UIColor { [weak node] traits in
                node?.channels("background_color", dark: traits.userInterfaceStyle == .dark).map { TextEngine.color($0) } ?? .systemBackground
            }
        #endif
        view.addSubview(node)
    }
    func mount() {
        loadViewIfNeeded()
        if node.superview !== view { view.addSubview(node) }
    }
    // A button can remove a route before UIKit starts its pop. Preserve its
    // outgoing pixels for that transition; an interactive pop uses live views.
    func freeze() {
        guard isViewLoaded, let snapshot = view.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(snapshot)
        snapshot.setPaintForeground()
    }
}

final class NavigationHost: NSObject, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    unowned let presenter: Presenter
    var primaryNavigation: UINavigationController?
    private(set) var presentedNavigations: [UINavigationController] = []
    var modalNavigation: UINavigationController? { presentedNavigations.last }
    private var navigation: UINavigationController? { modalNavigation ?? primaryNavigation }
    /// Whether native navigation holds the screens: the app root is then no
    /// screen of its own, and never scrolls (each screen's root does).
    var holdsScreens: Bool { primaryOwner != nil }
    private(set) var syncing = false
    private var mounting = false
    private(set) weak var container: NodeView?
    private var routeIDs: [UInt32] = []
    private(set) var controllers: [UInt32: RouteController] = [:]
    /// Each route owner's logical children (the root's, each tabpanel's),
    /// while UIKit containment holds the route views (LLP 1075.003 §3.7).
    var logicalChildren: [UInt32: [UInt32]] = [:]
    /// Exact's tab container and its stacks by panel id; the tablist whose
    /// place its bar takes; the tab delegate Exact keeps and forwards.
    var tabController: UITabBarController?
    /// What holds the tabs: Exact's tab controller, or a container the app's
    /// `tabContainer` hook returned (LLP 1075.003 §3.6).
    var tabOwner: UIViewController?
    var tabsHooked = false, tabContainerAsked = false, routerTab = -1
    var tabNavigations: [UInt32: UINavigationController] = [:]
    var tabPanels: [UInt32] = []
    var adoptedTablist: UInt32?
    /// The root whose tablist last decided the bar, and whether Exact hid the
    /// bar for a root's hidden tablist (LLP 1075.003 §3.7, amended).
    weak var tablistRoot: RouteController?
    var tablistHidBar = false
    var tabItems: [String] = []
    /// The bar's tint as last written: the tablist's accent, light and dark.
    var tabTint: [[Double]?]?
    let tabProxy = TabDelegateProxy()
    /// A context menu's commit pushes without the stack's animation: UIKit
    /// animates it (`.pop`, LLP 1021 §5.1). The selected route's key tells
    /// whether its press navigated.
    var unanimated = false
    var activeKey: String? { container?.props["navigationKey"] }
    /// While a push or pop runs: paints what each frame newly reveals.
    /// LLP 1075.003: each stack Exact built, by controller; what each shown
    /// bar covers of its route; the ownership changes already journaled;
    /// whether the hooks are being replayed for a cold launch's objects.
    var stacks: [ObjectIdentifier: NavigationStack] = [:]
    var stackCount = 0
    var covers: [UInt32: HostCover] = [:]
    var ownedReported: Set<String> = []
    var replayingHooks = false
    private var coversPending = false
    /// Whether the session's view last took the whole of its own for a bar.
    var tookWholeView = false
    /// LLP 1035.001.000 D1 — the whole of the host's own navigation state:
    /// what it last set on UIKit (`applied`), a change UIKit made that the
    /// app has not been told yet (`owed`), and whether the app's tree moved
    /// while projection waited (`dirty`). In flight is UIKit's to say.
    var applied: NavigationRules.Snapshot?
    var owed: NavigationRules.Change?
    var dirty = false
    var settling = false
    var delivering = false
    /// The last platform change told to the app, for `state.navigation`.
    var reported: String?
    /// A presentation refused because the owner already presents (an alert,
    /// a popover, the share sheet): retried until it can start (D5).
    var retrying = false
    /// UIKit moved a stack, the tree moved while projection waited, or the
    /// last sync stopped early (no window yet, the first draw, a
    /// transition, a presentation it could not make): the next batch syncs,
    /// whatever it holds (a batch of list rows alone otherwise skips it).
    var syncOwed: Bool { dirty || owed != nil || settling || inFlight || windowless || nativeMoved || !settled }
    private var windowless = false, nativeMoved = false, settled = false
    /// Syncs asked for, for tests.
    private(set) var syncCalls = 0
    /// The root key last journaled as matching no route, so a refusal is one
    /// line, not one per batch (LLP 1035.001 D6).
    private var refusedKey: String?

    init(presenter: Presenter) { self.presenter = presenter }

    /// Logical child-list edits leave declared, retained routes inside their
    /// controllers; newly added or no-longer-declared nodes use normal mounting.
    /// A route's logical parent is the root or, with tabs, its tabpanel.
    func ownsContainment(of node: NodeView, under parent: NodeView) -> Bool {
        (parent === container || (parent !== container && logicalChildren[parent.id] != nil)) &&
            container?.props["navigationBack"] != nil &&
            node.props["navigationKey"] != nil && controllers[node.id]?.node === node
    }

    /// One batch's projection: the root, each stack's routes — one a tab
    /// (LLP 1075.003 §3.7), or the root's own — which stack holds the route
    /// the root names and where, and each stack's wanted controllers (the
    /// selected stack's prefix through that route; another tab's whole).
    struct Projection {
        let root: NodeView
        let tabs: NavigationTabs?
        let stacks: [[NodeView]]
        let at: Int, selected: Int
        let wanted: [[RouteController]]
        var routes: [NodeView] { stacks[at] }
        var chosen: [RouteController] { wanted[at] }
    }

    /// Put each route node back under its logical parent, before native
    /// ownership retires, so surviving content stays in the window.
    private func restoreLogicalChildren() {
        for (owner, ids) in logicalChildren {
            guard let parent = owner == container?.id ? container : presenter.views[owner] else { continue }
            for (index, node) in ids.compactMap({ presenter.views[$0] }).enumerated() where presenter.views[node.id] === node {
                parent.container.insertSubview(node, at: index)
            }
        }
    }

    func prepare(_ batch: Batch) {
        checkOwned()
        presenter.elements.checkOwned()
        guard let top = navigation?.topViewController as? RouteController else { return }
        if batch.ops.contains(where: { $0.op == .destroy && $0.id == top.node.id }) {
            top.freeze()
        }
    }

    /// Resolve the declared route stacks once for both structural installation
    /// and later presentation. UIKit containment never becomes route state.
    private func projection(_ batch: Batch) -> Projection? {
        guard let root = presenter.root.subviews.first as? NodeView,
              root.props["navigationBack"] != nil else {
            // Retiring native ownership must not remove surviving content.
            // Restore the logical children before detaching the controller so
            // an editor remains in the same window through the handoff.
            if container != nil { restoreLogicalChildren() }
            reset(clearFocus: container != nil)
            return nil
        }
        if container !== root {
            // A fresh owner after unmount must preserve focus requested while
            // offscreen. Replacing an existing root still retires its command.
            reset(clearFocus: container != nil)
            container = root
            logicalChildren = [root.id: root.container.subviews.compactMap { ($0 as? NodeView)?.id }]
        }
        for op in batch.ops where op.op == .children && logicalChildren[op.id] != nil {
            logicalChildren[op.id] = op.ids
        }
        // With tabs, each panel holds a stack; a panel seen for the first
        // time still holds its rows, and its children ops say the rest.
        let tabs = NavigationTabs.of(root, presenter)
        for panel in tabs?.panels ?? [] where logicalChildren[panel.id] == nil {
            logicalChildren[panel.id] = panel.container.subviews.compactMap { ($0 as? NodeView)?.id }
        }
        let owners = tabs?.panels ?? [root]
        let stacks = owners.map { owner in
            (logicalChildren[owner.id] ?? []).compactMap { presenter.views[$0] }.filter { $0.props["navigationKey"] != nil }
        }
        routeIDs = stacks.flatMap { $0.map(\.id) }
        // Every route left the tree (the root shows something else now): the
        // containers go with them, or their views — a removed route's frozen
        // snapshot among them — stay over the new content (mail F21).
        if routeIDs.isEmpty, primaryOwner != nil || !presentedNavigations.isEmpty {
            presenter.session?.log("navigation: the root has no routes now; its containers are retired")
            reset(clearFocus: false)
            return nil
        }
        // D1: the stack is the prefix through the route the root names; a
        // key that names none leaves the stack alone, and says so once.
        let rootKey = root.props["navigationKey"] ?? ""
        let keys = { (routes: [NodeView]) in routes.map { $0.props["navigationKey"] ?? "" } }
        guard let at = stacks.firstIndex(where: { NavigationRules.stack(routeKeys: keys($0), selected: rootKey) != nil }),
              let range = NavigationRules.stack(routeKeys: keys(stacks[at]), selected: rootKey) else {
            if refusedKey != rootKey {
                refusedKey = rootKey
                presenter.session?.log("navigationKey \"\(rootKey)\" matches no route among the root's children or those of the tabpanels its tablist names; the stack is unchanged")
            }
            return nil
        }
        refusedKey = nil
        let wanted = stacks.enumerated().map { index, routes in
            (index == at ? Array(routes[range]) : routes).map { node -> RouteController in
                let c = controllers[node.id] ?? RouteController(node)
                c.host = self
                controllers[node.id] = c
                c.mount()
                return c
            }
        }
        return Projection(root: root, tabs: tabs, stacks: stacks, at: at, selected: range.upperBound - 1, wanted: wanted)
    }

    private func installPrimary(_ p: Projection, first: [RouteController]) {
        guard primaryNavigation == nil else { return }
        // Find the containing controller before installing our child.
        var responder: UIResponder? = p.root
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let parent = responder as? UIViewController else { return }
        if let tabs = p.tabs {
            installTabs(p, tabs, first: first, in: parent)
            return
        }
        let nav = makeNavigation(first: first.first?.node)
        parent.addChild(nav)
        p.root.addSubview(nav.view)
        nav.view.setPaintForeground(aboveAuthored: false)
        nav.view.frame = p.root.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        nav.didMove(toParent: parent)
        primaryNavigation = nav
        prepareRoutes(first, in: nav)
        nav.setViewControllers(first, animated: false)
        recordOwned(nav)
        watchPops(nav)
    }

    /// A hidden navigation bar needs its availability check here. The
    /// recognizer, competing scroll views and transition stay UIKit's.
    /// UIKit gives both recognizers its own delegate when the controller's
    /// view loads: a tab's stack, built before its tab controller shows it,
    /// is loaded first, or the swipe never asks Exact.
    func watchPops(_ nav: UINavigationController) {
        nav.loadViewIfNeeded()
        // tvOS has no interactive pop gesture.
        #if !os(tvOS)
        nav.interactivePopGestureRecognizer?.delegate = self
        if #available(iOS 26.0, tvOS 26.0, *) { nav.interactiveContentPopGestureRecognizer?.delegate = self }
        #endif
    }

    /// Initial containment is ready before child frames. It does not present
    /// a sheet or flush focus commands from the partially applied batch.
    func installInitialOwner(_ batch: Batch) {
        guard primaryNavigation == nil, !syncing, presenter.session?.view?.window != nil else { return }
        syncing = true
        defer { syncing = false }
        guard let p = projection(batch) else { return }
        let parts = NavigationRules.segments(presentations: p.routes[...p.selected].map { $0.props["navigationPresentation"] })
        installPrimary(p, first: Array(p.chosen[parts[0]]))
        primaryOwner?.view.layoutIfNeeded()
        applied = observe()
        // The content area the bar leaves reaches layout in this turn, before
        // the first frame (LLP 1075.003 Q3 (c)).
        reportCovers()
        refitForBars()
    }

    /// A container that starts or stops showing its bars changes the view
    /// the session takes (ExactViewIOS `fit`): lay it out again this turn.
    func refitForBars() {
        guard wantsWholeView != tookWholeView else { return }
        tookWholeView = wantsWholeView
        presenter.session?.view?.setNeedsLayout()
    }

    func sync(_ batch: Batch) {
        // A commit made while the host delivers or projects still moves the
        // routes it will project next.
        if container != nil {
            for op in batch.ops where op.op == .children && logicalChildren[op.id] != nil { logicalChildren[op.id] = op.ids }
        }
        // Installing or moving a controller can synchronously cause layout.
        // That layout must not start another containment handoff inside this one.
        syncCalls += 1
        guard !syncing, !delivering else { return }
        let window = presenter.session?.view?.window
        windowless = presenter.session != nil && window == nil
        // With no session (a presenter on its own) nothing is projected or owed.
        if presenter.session == nil { settled = true }
        guard window != nil else { return }
        nativeMoved = false; settled = false
        syncing = true
        defer { syncing = false; presenter.flushPendingFocus() }
        guard let p = projection(batch) else { settled = true; return }
        // LLP 1035.001.000 D5: nothing is projected over a platform change
        // the app has not been told, nor under a transition (a tab switch
        // included); the latest tree is projected once it settles. The first
        // installation has nothing to wait for.
        if holdsScreens, owed != nil || settling || inFlight {
            dirty = true
            return
        }
        dirty = false
        let root = p.root, wanted = p.chosen
        let parts = NavigationRules.segments(presentations: p.routes[...p.selected].map { $0.props["navigationPresentation"] })
        reshape(p)
        installPrimary(p, first: Array(wanted[parts[0]]))
        // The other tabs' stacks, the selected tab and its items (LLP 1075.003 §3.7).
        if p.tabs != nil { syncTabs(p) }
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
        let owners = [primaryNavigation].compactMap { $0 } + presentedNavigations
        for index in 0...common where index < owners.count {
            let nav = owners[index]
            // The More list open at its root over the tab the app selects is
            // UIKit's chrome, as a menu is: left as it is.
            if index == 0, moreListOpen { continue }
            let stack = Array(wanted[parts[index]])
            prepareRoutes(stack, in: nav)
            // A stack tab shown inside the More list sits on UIKit's list.
            let wantedStack = held(nav) + stack
            let same = nav.viewControllers.count == wantedStack.count && zip(nav.viewControllers, wantedStack).allSatisfy { $0 === $1 }
            if !same {
                // @ref LLP 1038 D6 — a tab change swaps immediately. A replacement within one stack
                // whose new top was not on it (a finished screen giving way to its result) arrives
                // as UIKit's own push, rather than cutting.
                let pushOrPop = NavigationRules.isPushOrPop(from: nav.viewControllers.map(ObjectIdentifier.init), to: stack.map(ObjectIdentifier.init))
                let arrives = stack.count > 1 && nav.viewControllers.first === stack.first
                    && !nav.viewControllers.contains { $0 === stack.last }
                nav.setViewControllers(wantedStack, animated: (pushOrPop || arrives) && index == owners.count - 1 && mounted.count == boundaries.count && !ExactEnv.agentFreezes && !unanimated && nav.view.window != nil)
                recordOwned(nav)
                // D5: what UIKit reports is what was applied; a call it did
                // not take is the host's, never mistaken for the person's.
                if nav.viewControllers.count != wantedStack.count || !zip(nav.viewControllers, wantedStack).allSatisfy({ $0 === $1 }) {
                    presenter.session?.log("navigation: UIKit did not take the stack the routes name")
                }
            }
            nav.view.layoutIfNeeded()
        }
        unanimated = false
        if mounted.count > common {
            dirty = true
            presenter.modals.closeTop()
            return
        }
        if boundaries.count > mounted.count, let background = modalNavigation ?? primaryOwner, let owner {
            let source = navigation?.topViewController as? RouteController
            let part = parts[mounted.count + 1], route = wanted[part.lowerBound].node
            // D5: an alert, a popover or the share sheet over the owner defers
            // the sheet; it starts once that has gone (B6).
            guard presenter.modals.canPresent(from: owner, route: route) else { dirty = true; retry(); return }
            let nav = makeNavigation(first: route)
            owner.addChild(nav)
            root.addSubview(nav.view)
            nav.view.setPaintForeground(aboveAuthored: false)
            nav.view.frame = root.bounds
            nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            nav.didMove(toParent: owner)
            presentedNavigations.append(nav)
            prepareRoutes(Array(wanted[part]), in: nav)
            nav.setViewControllers(Array(wanted[part]), animated: false)
            recordOwned(nav)
            watchPops(nav)
            nav.view.layoutIfNeeded()
            dirty = boundaries.count > mounted.count + 1
            let preceding = part.lowerBound > 0 ? wanted[part.lowerBound - 1].node : nil
            presenter.modals.present(route, navigation: nav, from: background, node: source?.node,
                                     preceding: preceding, owner: owner)
        }
        if let top = modalNavigation ?? primaryOwner {
            top.view.frame = root.bounds
            if top === primaryOwner { placeOwner() } else { root.bringSubviewToFront(top.view) }
            top.view.layoutIfNeeded()
        }
        for (id, c) in controllers where !routeIDs.contains(id) { end(c) }
        controllers = controllers.filter { routeIDs.contains($0.key) }
        presenter.modals.updatePermissions()
        if p.tabs != nil { replayTabs() }
        reportCovers()
        refitForBars()
        settled = true
    }

    /// The container standing in for the routes paints where they are in
    /// the root's children, as CSS paints siblings in tree order (LLP
    /// 1083.000): above the children before them, under those after them —
    /// an authored tablist, a toast. On top of every child it hid a sibling
    /// tablist and a root overlay, and took their taps (shop F21, recipes F23).
    func placeOwner() {
        guard let root = container, let owner = primaryOwner?.view, owner.superview === root else { return }
        let ids = logicalChildren[root.id] ?? []
        let panels = tabPanels.compactMap { presenter.views[$0] }
        let region = ids.firstIndex { id in
            routeIDs.contains(id) || presenter.views[id].map { child in panels.contains { $0 === child || $0.isDescendant(of: child) } } == true
        }
        let after = Set(region.map { ids[($0 + 1)...] } ?? [])
        guard let next = root.subviews.first(where: { ($0 as? NodeView).map { after.contains($0.id) } == true }) else {
            if root.subviews.last !== owner { root.bringSubviewToFront(owner) }
            return
        }
        let at = root.subviews.firstIndex { $0 === next }!
        if at == 0 || root.subviews[at - 1] !== owner { root.insertSubview(owner, belowSubview: next) }
    }

    /// A route's controller leaves for good: its header paints again and the
    /// route hook hears `routeEnded` (LLP 1075.003 §3.2).
    private func end(_ c: RouteController) {
        if let header = c.lifted { header.isHidden = false; c.lifted = nil }
        guard c.hooked else { return }
        c.hooked = false
        presenter.session?.natives.routeHook(.ended, controller: c, navigation: nil, scroll: nil, key: c.key, dataset: c.node.props["dataset"])
    }

    /// At a cold launch the module loads a turn after first pixel (LLP
    /// 1075.003 Q3 (c)): each hook runs once for every object already live,
    /// stacks first, in the order they were built.
    func replayHooks() {
        guard presenter.session?.natives.hooksConnected == true else { return }
        replayingHooks = true
        defer { replayingHooks = false }
        let navs = allNavigations
        for nav in navs { hookNavigation(nav) }
        replayTabs()
        for nav in navs {
            prepareRoutes(nav.viewControllers.compactMap { $0 as? RouteController }, in: nav)
            nav.view.layoutIfNeeded()
        }
        reportCovers()
        refitForBars()
    }

    /// A route's safe area moved: report its cover once this turn is done.
    func coversChanged() {
        guard !coversPending else { return }
        coversPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            coversPending = false
            reportCovers()
        }
    }

    /// What presents a sheet: the last sheet, else the primary owner's
    /// parent — with tabs the tab controller's, never a tab's own stack.
    var owner: UIViewController? { presenter.modals.owner ?? primaryOwner?.parent }
    /// The controller Exact installed under the root: the tab container, or
    /// the one stack.
    var primaryOwner: UIViewController? { tabOwner ?? primaryNavigation }

    func willMount() { mounting = true }

    func mounted() {
        mounting = false
        sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
    }

    func unmounted() {
        mounting = false
        let root = container, logical = logicalChildren
        reset(clearFocus: false)
        // Release controller containment while preserving the actual nodes.
        // Offscreen batches now reconcile their ordinary logical child list.
        guard let root, presenter.views[root.id] === root else { return }
        for (owner, ids) in logical {
            guard let parent = owner == root.id ? root : presenter.views[owner] else { continue }
            for (index, node) in ids.compactMap({ presenter.views[$0] }).enumerated() where presenter.views[node.id] === node {
                parent.container.insertSubview(node, at: index)
            }
        }
    }

    /// A presentation began, ended, or was dismissed by the platform: a
    /// settle point (LLP 1035.001.000 D3).
    func modalDidDismiss() { settle() }

    /// Retire only the named owner; a late completion cannot remove its
    /// successor or the retained owner beneath it.
    func retireNavigation(_ controller: UIViewController, preserving: Bool) {
        guard let nav = controller as? UINavigationController,
              presentedNavigations.contains(where: { $0 === nav }) else { return }
        presentedNavigations.removeAll { $0 === nav }
        // A presentation gone (UIKit's own dismissal included): the next
        // batch syncs, whatever it holds, so a route still declared returns.
        nativeMoved = true
        retireStack(nav)
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
        nav.view.setPaintForeground(false)
        nav.view.frame = frame
        nav.view.accessibilityElementsHidden = true
        return nav
    }

    /// Focus waits through controller installation as well as UIKit's push/pop.
    /// `clock settle` observes the asynchronous part under platform timing.
    var defersFocus: Bool { syncing || mounting || delivering || (holdsScreens && inFlight) }
    var inTransition: Bool { defersFocus || dirty || settling || owed != nil }
    /// A stack moving, as UIKit's coordinators say (D1); the status bar
    /// resolves once none is (LLP 1105). `started` is the same: in this
    /// model nothing is begun that UIKit does not report.
    var transitioning: Bool { inFlight }
    var started: Bool { inFlight }

    /// For `state.navigation` (LLP 1035.002 D2; LLP 1035.001.000 D9): the
    /// route the root names, UIKit's stack by key, what UIKit shows, what the
    /// host last applied, what the app's tree asks, a change not yet told,
    /// the last one that was, and the tabs in the order UIKit shows them —
    /// observations.
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
                "tabs": tabController.map { tabOrder(of: $0) } ?? NSNull()]
    }

    func move(to parent: UIViewController, mount: () -> Void) {
        guard let nav = modalNavigation ?? primaryOwner, nav.parent !== parent else { mount(); return }
        let container = nav.view.superview
        nav.willMove(toParent: nil)
        nav.view.removeFromSuperview()
        nav.removeFromParent()
        parent.addChild(nav)
        mount()
        container?.addSubview(nav.view)
        nav.didMove(toParent: parent)
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

    func isInactiveRoute(containing view: UIView) -> Bool {
        guard let selected = container?.props["navigationKey"],
              let key = routeKey(containing: view) else { return false }
        return key != selected
    }

    /// D1: resolved at use, by HTML id, among live enabled press controls —
    /// never captured at a gesture's start (`NavigationRules.backControl`).
    var backControl: NodeView? {
        guard let route = activeRoute else { return nil }
        return NavigationRules.backControl(named: container?.props["navigationBack"], among: presenter.carrying("id"),
                                           id: \.id, htmlID: { $0.props["id"] }, pressable: { $0.handlers.contains("press") }, disabled: \.disabled,
                                           inActiveRoute: { $0 === route || $0.isDescendant(of: route) })
    }

    /// Where each pop recognizer's first touch went down, in its view. A
    /// pan's translation at `shouldBegin` leaves out the travel before it
    /// recognized: a real touch from x = 1 read as starting at 30, past the
    /// 20-point edge, and over a `swiperight` row the pop was refused (LLP
    /// 1080.000 §11). The edge rule judges where the finger landed.
    /// Keyed weakly: a retired stack's recognizers take their entries with them.
    private let popTouchDown = NSMapTable<UIGestureRecognizer, NSValue>.weakToStrongObjects()

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The first finger of each gesture replaces the last gesture's; a second finger does not.
        if gestureRecognizer.numberOfTouches == 0 { notePopTouchDown(gestureRecognizer, at: touch.location(in: gestureRecognizer.view)) }
        return true
    }
    func notePopTouchDown(_ gestureRecognizer: UIGestureRecognizer, at point: CGPoint) { popTouchDown.setObject(NSValue(cgPoint: point), forKey: gestureRecognizer) }

    /// The swipe's start: its first touch's point, else (no touch seen) its translation's origin.
    func popStart(_ pan: UIPanGestureRecognizer, in view: UIView) -> CGPoint {
        if let down = popTouchDown.object(forKey: pan)?.cgPointValue { return down }
        let location = pan.location(in: view), delta = pan.translation(in: view)
        return CGPoint(x: location.x - delta.x, y: location.y - delta.y)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else {
            return popMayBegin(gestureRecognizer, from: nil, in: nil, velocity: .zero)
        }
        // A pan's velocity at shouldBegin is often zero (a finger that
        // started slowly, or one sample in): read that way every back swipe
        // is refused as not horizontal. Its travel so far says the direction.
        return popShouldBegin(pan, in: view, velocity: NavigationRules.popDirection(velocity: pan.velocity(in: view), travel: pan.translation(in: view)))
    }
    /// `shouldBegin` for a pan at `velocity`: from where its finger landed.
    func popShouldBegin(_ pan: UIPanGestureRecognizer, in view: UIView, velocity: CGPoint) -> Bool {
        popMayBegin(pan, from: popStart(pan, in: view), in: view, velocity: velocity)
    }

    /// Whether a pop recognizer's swipe, starting at `start` in `view` (a
    /// pan's) with `velocity`, may pop: the showing stack's (a tab's, or a
    /// sheet's over it), by its own depth, with an enabled back control in
    /// its active route (D1), and not a pan a `swiperight` node or a canvas
    /// owns, nor more vertical than horizontal.
    func popMayBegin(_ gestureRecognizer: UIGestureRecognizer, from start: CGPoint?, in view: UIView?, velocity: CGPoint) -> Bool {
        // tvOS has no interactive pop gesture.
        #if os(tvOS)
        let owner: UINavigationController? = nil
        #else
        let owner = allNavigations.first { nav in
            if nav.interactivePopGestureRecognizer === gestureRecognizer { return true }
            if #available(iOS 26.0, *) { return nav.interactiveContentPopGestureRecognizer === gestureRecognizer }
            return false
        }
        #endif
        if let owner, owner !== navigation { return false }
        let depth = navigation?.viewControllers.count ?? 0
        let permitted = backPermittedNow
        guard NavigationRules.popMayBegin(depth: depth, inFlight: inFlight || owed != nil, modalActive: presenter.modals.inTransition,
                                          permitted: permitted,
                                          contextPreviewActive: !presenter.chrome.ids("contextTarget").isEmpty) else {
            if depth > 1, !inFlight, !permitted {
                presenter.session?.log("back gesture refused: the active route does not permit leaving (no enabled navigationBack control)")
            }
            return false
        }
        guard let start, let view else { return true }
        var overSwipeRight = false
        var hit = view.hitTest(start, with: nil)
        if CanvasInput.owns(hit) { return false }
        while let current = hit {
            if let node = current as? NodeView, node.handlers.contains("swiperight") { overSwipeRight = true; break }
            if current === view { break }
            hit = current.superview
        }
        return NavigationRules.panMayBegin(startX: start.x, overSwipeRight: overSwipeRight, velocity: velocity)
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        guard owns(navigationController) else { return }
        // UIKit's own (its Back button, a swipe): Observe's render mark is now.
        if !syncing { NavigationMarks.shared.platformBeganShowing() }
        let transition = navigationController.transitionCoordinator
        // The route coming into view was out of the window while it was
        // covered, so no scroll asked for its text; paint what shows of it
        // as the transition starts, not when the reader next scrolls.
        // Completed or cancelled, the transition's end is a settle point
        // (LLP 1035.001.000 D3).
        transition?.animate(alongsideTransition: { [weak self] _ in self?.presenter.paintVisibleText() }) { [weak self] _ in self?.settle() }
        // That paints what shows as it starts. A swipe reveals the route a
        // strip at a time, and painting stopped there until the swipe ended
        // (a back swipe showed the list's top half, then its bottom half).
        // Paint each frame's newly revealed text until the transition is over.
        if animated, transition != nil { startRevealing() }
    }

    private func startRevealing() {
        guard !FrameClock.shared.wants(self) else { return }
        FrameClock.shared.want(self, .navigationReveal, rate: FrameClock.full(on: presenter.viewport.window?.screen)) { [weak self] _ in self?.revealTick() }
    }

    private func revealTick() {
        guard inFlight else { stopRevealing(); return }
        presenter.paintVisibleText()
    }

    private func stopRevealing() {
        FrameClock.shared.drop(self)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        guard owns(navigationController) else { return }
        nativeMoved = true
        stopRevealing()
        presenter.session?.view?.fit()
        presenter.syncModal()
        // What the settled route shows has pixels (the swipe may have
        // left a band of it unpainted, or a cancelled pop the source).
        presenter.paintVisibleText()
        presenter.flushPendingFocus()
        recordPop(navigationController)
        // Settled on a stack's root: once UIKit has finished the
            // transition (its own bar restoration included), a root whose
            // arrival no projection has handled yet reconciles the bar with
            // its tablist (§3.7).
            DispatchQueue.main.async { [weak self, weak navigationController] in
                if let navigationController { self?.settleTablist(navigationController) }
            }
            // At rest: a large title's insets are sampled now (§9.10).
        coversChanged()
        settle()
    }

    /// A stack Exact retired: its handle goes.
    func retireStack(_ nav: UINavigationController) {
        guard let stack = stacks.removeValue(forKey: ObjectIdentifier(nav)), stack.hooked else { return }
        _ = presenter.session?.natives.navigationHook(nav, built: false, showsBar: stack.showsBar, label: stack.label)
    }

    func reset(clearFocus: Bool = true) {
        unanimated = false
        presenter.modals.reset()
        for nav in presentedNavigations { retireNavigation(nav, preserving: false) }
        for c in controllers.values { end(c) }
        retireTabs()
        if let primaryNavigation { retireStack(primaryNavigation) }
        if !covers.isEmpty {
            let cleared = covers.keys.filter { presenter.views[$0] != nil }
            covers = [:]
            if !cleared.isEmpty { presenter.onCovers?(cleared.map { ($0, nil) }) }
        }
        primaryNavigation?.delegate = nil
        primaryNavigation?.willMove(toParent: nil)
        primaryNavigation?.view.removeFromSuperview()
        primaryNavigation?.removeFromParent()
        primaryNavigation = nil
        container = nil
        logicalChildren = [:]
        refitForBars()
        controllers.removeAll()
        routeIDs = []
        applied = nil
        owed = nil
        dirty = false
        reported = nil
        if clearFocus { presenter.cancelPendingFocus() }
    }
}
#if os(tvOS)
extension NavigationHost {
    /// Whether the Siri Remote's Menu goes back: a route to pop and a Back control.
    var menuGoesBack: Bool { (navigation?.viewControllers.count ?? 0) > 1 && backControl != nil }
    func menuBack() {
        guard menuGoesBack, !inFlight, let control = backControl else { return }
        presenter.press(control.id)
    }
}
#endif
#endif
