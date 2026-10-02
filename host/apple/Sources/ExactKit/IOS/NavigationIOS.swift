// @ref LLP 1008 §9 — Contract routes projected into UIKit's navigation
// controller. UIKit owns recognition, arbitration, progress and cancellation.
// Only a completed pop invokes the Contract back control.
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
    /// is "false"; `navigationBackButton` "minimal" shows the chevron alone;
    /// `navigationTrailing` names (by HTML id) an authored control a trailing
    /// bar button presses, drawn as the `navigationTrailingSymbol` SF Symbol.
    /// A route with no title keeps the bar hidden, as before.
    var hasBar: Bool { !(node.props["navigationTitle"] ?? "").isEmpty }
    func configure(press: @escaping (String) -> Void) {
        let item = navigationItem
        let title = node.props["navigationTitle"] ?? ""
        if item.title != title { item.title = title.isEmpty ? nil : title }
        item.largeTitleDisplayMode = node.props["navigationLargeTitle"] == "false" ? .never : .always
        item.backButtonDisplayMode = node.props["navigationBackButton"] == "minimal" ? .minimal : .default
        if let target = node.props["navigationTrailing"], !target.isEmpty {
            let symbol = node.props["navigationTrailingSymbol"] ?? ""
            if item.rightBarButtonItem?.accessibilityIdentifier != "\(target)|\(symbol)" {
                let button = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in press(target) })
                button.accessibilityIdentifier = "\(target)|\(symbol)"
                item.rightBarButtonItem = button
            }
        } else if item.rightBarButtonItem != nil {
            item.rightBarButtonItem = nil
        }
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
    private var syncing = false
    private var mounting = false
    private weak var container: NodeView?
    private var routeIDs: [UInt32] = []
    private var controllers: [UInt32: RouteController] = [:]
    private var changing = false
    private var pendingSync = false
    private var interactiveSource: (node: NodeView, key: String)?
    /// The stack's depth when the interactive pop began, source included.
    private var interactiveDepth = 0
    /// The root key last journaled as matching no route, so a refusal is one
    /// line, not one per batch (LLP 1035.001 D6).
    private var refusedKey: String?

    init(presenter: Presenter) { self.presenter = presenter }

    /// Logical child-list edits leave declared, retained routes inside their
    /// controllers; newly added or no-longer-declared nodes use normal mounting.
    func ownsContainment(of node: NodeView, under parent: NodeView) -> Bool {
        parent === container && parent.props["navigationBack"] != nil &&
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
        guard let root = presenter.root.subviews.first as? NodeView,
              root.props["navigationBack"] != nil else {
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
        c.configure { [weak self] target in self?.pressControl(named: target, in: node) }
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
            parent.addChild(controller)
            root.addSubview(controller.view)
            controller.view.frame = root.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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
        if (tabs.viewControllers ?? []).count != controllers.count || !zip(tabs.viewControllers ?? [], controllers).allSatisfy({ $0 === $1 }) {
            tabs.setViewControllers(controllers, animated: false)
        }
        if let index = order.firstIndex(of: selected), tabs.selectedIndex != index { tabs.selectedIndex = index }
        primaryNavigation = tabContainers[selected]?.stack
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

    /// Agent activation (LLP 1012) of a control UIKit's chrome stands in for
    /// — a tab's `navigationTabControl`, a route's `navigationTrailing`, the
    /// Back control under a native back button — presses it as the tab bar
    /// or bar button would; nil for anything else.
    func activate(_ node: NodeView) -> Bool? {
        guard let id = node.props["id"], !id.isEmpty else { return nil }
        let routes = routeIDs.compactMap { presenter.views[$0] }
        let stands = routes.contains { $0.props["navigationTabControl"] == id || $0.props["navigationTrailing"] == id }
            || (id == container?.props["navigationBack"] && navigation?.isNavigationBarHidden == false)
        guard stands else { return nil }
        guard node.handlers.contains("press"), !node.disabled else { return false }
        presenter.press(node.id)
        return true
    }

    /// A tab is chosen in Contract: a tap presses the tab's root route's
    /// `navigationTabControl` (by HTML id), whose action selects it, and the
    /// projection follows. UIKit never selects on its own.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard let tab = tabContainers.first(where: { $0.value.controller === viewController })?.key,
              let control = tabRoutes.first(where: { $0.props["navigationTab"] == tab })?.props["navigationTabControl"] else { return false }
        pressControl(named: control, in: nil)
        return false
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
        root.addSubview(nav.view)
        nav.view.frame = root.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        nav.didMove(toParent: parent)
        primaryNavigation = nav
        nav.setViewControllers(wanted, animated: false)
        // A hidden navigation bar needs its availability check here. The
        // recognizer, competing scroll views and transition stay UIKit's.
        nav.interactivePopGestureRecognizer?.delegate = self
        if #available(iOS 26.0, *) { nav.interactiveContentPopGestureRecognizer?.delegate = self }
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
    }

    func sync(_ batch: Batch) {
        // Installing or moving a controller can synchronously cause layout.
        // That layout must not start another containment handoff inside this one.
        guard !syncing, presenter.session?.view?.window != nil else { return }
        syncing = true
        defer { syncing = false; presenter.flushPendingFocus() }
        guard let (root, routes, selected, wanted) = projection(batch) else { return }
        let parts = NavigationRules.segments(presentations: routes[...selected].map { $0.props["navigationPresentation"] })
        installPrimary(root: root, wanted: Array(wanted[parts[0]]))
        // Initial content draws before presentation takes over its viewport.
        if parts.count > 1, let session = presenter.session, session.firstDrawMs == nil { return }
        guard !changing, !presenter.modals.inTransition else { pendingSync = true; return }
        pendingSync = false
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
            guard let nav = owners[index] else { continue }
            let stack = Array(wanted[parts[index]])
            let same = nav.viewControllers.count == stack.count && zip(nav.viewControllers, stack).allSatisfy { $0 === $1 }
            if !same {
                // @ref LLP 1038 D6 — a tab change swaps immediately. A replacement within one stack
                // whose new top was not on it (a finished screen giving way to its result) arrives
                // as UIKit's own push, rather than cutting.
                let pushOrPop = NavigationRules.isPushOrPop(from: nav.viewControllers.map(ObjectIdentifier.init), to: stack.map(ObjectIdentifier.init))
                let arrives = stack.count > 1 && nav.viewControllers.first === stack.first
                    && !nav.viewControllers.contains { $0 === stack.last }
                nav.setViewControllers(stack, animated: (pushOrPop || arrives) && index == owners.count - 1 && mounted.count == boundaries.count && !ExactEnv.agentFreezes && nav.view.window != nil)
            }
            showBar(nav, animated: false)
            nav.view.layoutIfNeeded()
        }
        if mounted.count > common {
            pendingSync = true
            presenter.modals.closeTop()
            return
        }
        // Under tabs, the first presentation is over the whole tab bar
        // controller, and its owner is the tab bar controller's parent.
        let background: UIViewController? = presentedNavigations.isEmpty && tabs != nil ? tabs : navigation
        if boundaries.count > mounted.count, let background, let owner {
            let source = (navigation?.topViewController as? RouteController) ?? wanted[parts[0]].last
            let part = parts[mounted.count + 1], route = wanted[part.lowerBound].node
            guard presenter.modals.canPresent(from: owner, route: route) else { return }
            let nav = UINavigationController()
            nav.setNavigationBarHidden(true, animated: false)
            nav.navigationBar.prefersLargeTitles = true
            nav.delegate = self
            owner.addChild(nav)
            root.addSubview(nav.view)
            nav.view.frame = root.bounds
            nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            nav.didMove(toParent: owner)
            presentedNavigations.append(nav)
            nav.setViewControllers(Array(wanted[part]), animated: false)
            showBar(nav, animated: false)
            nav.interactivePopGestureRecognizer?.delegate = self
            if #available(iOS 26.0, *) { nav.interactiveContentPopGestureRecognizer?.delegate = self }
            nav.view.layoutIfNeeded()
            pendingSync = boundaries.count > mounted.count + 1
            let preceding = part.lowerBound > 0 ? wanted[part.lowerBound - 1].node : nil
            presenter.modals.present(route, navigation: nav, from: background, node: source?.node,
                                     preceding: preceding, owner: owner)
        }
        if let tabs, presentedNavigations.isEmpty {
            tabs.view.frame = root.bounds
            root.bringSubviewToFront(tabs.view)
            tabs.view.layoutIfNeeded()
        } else if let nav = navigation {
            nav.view.frame = root.bounds
            root.bringSubviewToFront(nav.view)
            nav.view.layoutIfNeeded()
        }
        controllers = controllers.filter { routeIDs.contains($0.key) }
        presenter.modals.updatePermissions()
    }

    var owner: UIViewController? { presenter.modals.owner ?? tabs?.parent ?? primaryNavigation?.parent }

    /// UIKit's bar shows for a route that declares a title, and hides for one
    /// that does not, as each becomes the top of its stack.
    private func showBar(_ nav: UINavigationController, for controller: UIViewController? = nil, animated: Bool) {
        let hidden = !((controller ?? nav.topViewController) as? RouteController).map(\.hasBar).orFalse
        if nav.isNavigationBarHidden != hidden { nav.setNavigationBarHidden(hidden, animated: animated) }
    }

    /// A bar button presses the authored control the route names by HTML id
    /// (anywhere, for a tab's control).
    private func pressControl(named target: String, in route: NodeView?) {
        guard let control = presenter.carrying("id").first(where: { node in
            node.props["id"] == target && (route.map { node === $0 || node.isDescendant(of: $0) } ?? true)
                && node.handlers.contains("press") && !node.disabled
        }) else {
            presenter.session?.log("navigationTrailing \"\(target)\" names no enabled control in its route")
            return
        }
        presenter.press(control.id)
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

    func modalDidDismiss() {
        guard pendingSync else { return }
        pendingSync = false
        sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
    }

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

    /// Focus waits through controller installation as well as UIKit's push/pop.
    /// `clock settle` observes the asynchronous part under platform timing.
    var defersFocus: Bool { changing || syncing || mounting }
    var inTransition: Bool { defersFocus || pendingSync }
    /// How the last transition ended — `completed` (the Back control was
    /// pressed), `cancelled` (an interactive pop returned), `idle` (a
    /// programmatic change, or nothing yet) — for `state.navigation`.
    private var lastTransition = "idle"
    private var interactiveTransition = false

    /// For `state.navigation` (LLP 1035.002 D2): the route the root names,
    /// UIKit's stack by key, and the transition's phase — observations.
    func observation() -> [String: Any] {
        let stack = (navigation?.viewControllers ?? []).compactMap { ($0 as? RouteController)?.key }
        let transition: [String: Any] = ["interactive": navigation?.transitionCoordinator?.isInteractive ?? false,
                                         "phase": changing || pendingSync || presenter.modals.inTransition ? "in-progress" : lastTransition]
        let root = container ?? presenter.root.subviews.first as? NodeView
        return ["route": root?.props["navigationKey"] ?? NSNull(), "stack": stack, "transition": transition]
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

    func invokeBack(from source: NodeView) {
        guard presenter.session?.view?.window != nil,
              presenter.views[source.id] === source, routeIDs.contains(source.id),
              source.props["navigationKey"] == container?.props["navigationKey"] else { return }
        if let control = backControl { presenter.press(control.id) }
    }

    var canInvokeBack: Bool { backControl != nil }

    var preservesKeyboardViewport: Bool {
        NavigationRules.freezesViewport(modalActive: presenter.modals.active, changing: changing,
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
    private var backControl: NodeView? {
        guard let key = container?.props["navigationKey"],
              let route = routeIDs.compactMap({ presenter.views[$0] }).first(where: { $0.props["navigationKey"] == key }) else { return nil }
        return NavigationRules.backControl(named: container?.props["navigationBack"], among: presenter.carrying("id"),
                                           id: \.id, htmlID: { $0.props["id"] }, pressable: { $0.handlers.contains("press") }, disabled: \.disabled,
                                           inActiveRoute: { $0 === route || $0.isDescendant(of: route) })
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let depth = navigation?.viewControllers.count ?? 0
        let control = backControl
        guard NavigationRules.popMayBegin(depth: depth, changing: changing, modalActive: presenter.modals.inTransition,
                                          hasBackControl: control != nil,
                                          contextPreviewActive: !presenter.chrome.ids("contextTarget").isEmpty) else {
            if depth > 1, !changing, !presenter.modals.inTransition, control == nil {
                presenter.session?.log("back gesture refused: no enabled navigationBack control in the active route")
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
        guard navigationController === navigation else { return }
        // A presented owner's appearance also calls willShow, using its
        // enclosing presentation coordinator. Only a transition to this route
        // belongs to navigation and has a matching didShow completion.
        // @ref LLP 1038 D6/D11; LLP 1035.001 D2 — cancellation calls
        // willShow again for the source, although the coordinator's .to is
        // still the pop destination. Keep that contact's source until didShow.
        if interactiveTransition, interactiveSource != nil { return }
        let transition = navigationController.transitionCoordinator
        showBar(navigationController, for: viewController, animated: animated)
        changing = animated && transition?.viewController(forKey: .to) === viewController
        interactiveTransition = changing && transition?.initiallyInteractive == true
        interactiveSource = nil
        if interactiveTransition,
           let source = navigationController.transitionCoordinator?.viewController(forKey: .from) as? RouteController {
            interactiveSource = (source.node, source.key)
            interactiveDepth = navigationController.viewControllers.count + 1
        }
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        guard navigationController === navigation,
              navigationController.topViewController === viewController else { return }
        changing = false
        defer {
            // Tree updates during UIKit's transition retain their latest
            // intent. Apply it once the native stack is available again.
            if pendingSync {
                pendingSync = false
                sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
            }
            presenter.session?.view?.fit()
            presenter.flushPendingFocus()
        }
        let source = interactiveSource
        interactiveSource = nil
        let sourceKey = source.flatMap { presenter.views[$0.node.id] === $0.node ? $0.key : nil }
        // Replaced in place while the finger was down: the source's node is gone and the app's
        // stack is as deep as it was when the swipe began.
        let sourceReplaced = source != nil && sourceKey == nil
            && routeIDs.compactMap({ presenter.views[$0] }).filter({ $0.props["navigationKey"] != nil }).count == interactiveDepth
        let dispatches = (viewController as? RouteController).map {
            NavigationRules.dispatchesBack(shownKey: $0.key, rootKey: container?.props["navigationKey"] ?? "",
                                           sourceKey: sourceKey, sourceReplaced: sourceReplaced,
                                           modalActive: presenter.modals.inTransition)
        } ?? false
        let cancelled = interactiveTransition && (viewController as? RouteController)?.node === source?.node
        lastTransition = dispatches ? "completed" : (cancelled ? "cancelled" : "idle")
        interactiveTransition = false
        guard dispatches, let control = backControl else { return }
        presenter.press(control.id)
    }

    func reset(clearFocus: Bool = true) {
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
        changing = false
        pendingSync = false
        interactiveSource = nil
        interactiveTransition = false
        lastTransition = "idle"
        if clearFocus { presenter.cancelPendingFocus() }
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
#endif
