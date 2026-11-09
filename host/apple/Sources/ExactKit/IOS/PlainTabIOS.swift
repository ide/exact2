// @ref LLP 1075.003 §3.7 — each tab's controller, made with the tab container
// and never replaced. "You can use navigation controllers or custom view
// controllers as the root view controller for a tab" (UITabBarController): a
// tab whose panel draws its stack is a navigation controller, its bar hidden
// where its first route shows none; a tab whose panel shows one fixed route
// uses no stack navigator and is a plain view controller, as a hand-built app
// shows such a tab (`Runner::panels_draw_stacks` reads which from the plan, so
// it is known for a tab not built yet). A plain tab has no navigation bar:
// its route's header is its content. A tab the runner has not built yet
// (§9.14) is its controller, empty, until its routes arrive.
#if os(iOS) || os(tvOS)
import UIKit

/// A tab that shows one route, with no navigation controller.
final class PlainTab: UIViewController {
    private(set) var route: RouteController?

    override func loadView() { view = UIView() }

    /// Show `next` in place of the route shown now, unanimated.
    func show(_ next: RouteController?) {
        guard next !== route else { return }
        if let old = route {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
            route = nil
        }
        guard let next else {
            for edge in [NSDirectionalRectEdge.top, .bottom] { setContentScrollView(nil, for: edge) }
            return
        }
        route = next
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        for edge in [NSDirectionalRectEdge.top, .bottom] { setContentScrollView(next.contentScrollView(for: edge), for: edge) }
    }

    // The tab bar follows its tab's content scroll view, which a navigation
    // controller takes from its top: here, the route's.
    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        route?.contentScrollView(for: edge) ?? super.contentScrollView(for: edge)
    }
}

extension UIViewController {
    /// The routes of a stack Exact built, its root first: a navigation
    /// controller's, after what UIKit keeps in front of them (`stackFront`),
    /// or the one a plain tab shows.
    var stackRoutes: [UIViewController] {
        if let nav = self as? UINavigationController { return Array(nav.viewControllers.drop { !($0 is RouteController) }) }
        return ((self as? PlainTab)?.route).map { [$0] } ?? []
    }

    /// What UIKit keeps in front of a navigation controller's routes: More's
    /// list (iOS). Every write of the routes keeps it.
    var stackFront: [UIViewController] {
        (self as? UINavigationController).map { Array($0.viewControllers.prefix { !($0 is RouteController) }) } ?? []
    }
}

extension NavigationHost {
    /// A tab's controller: its navigation controller, or its plain tab.
    func tabStack(_ panel: UInt32) -> UIViewController? { tabNavigations[panel] ?? plainTabs[panel] }

    /// The stacks under the root, in tab order (or the one): each tab's
    /// where UIKit holds its routes (`routesStack`, More's for a tab under More).
    var primaryStacks: [UIViewController] {
        tabPanels.isEmpty ? [primaryNavigation, split?.detail, split?.inspector].compactMap { $0 } : tabPanels.indices.compactMap(routesStack)
    }

    /// The selected tab, when it is a plain tab.
    var primaryPlain: PlainTab? { tabPanels.indices.contains(routerTab) ? plainTabs[tabPanels[routerTab]] : nil }

    /// The routes of each navigation controller whose routes may show the
    /// bar, unless its hatch said otherwise; the primary stacks first, then
    /// the sheets'.
    var barStackRoutes: [[UIViewController]] {
        (primaryStacks + presentedNavigations).filter { stack in
            (stack as? UINavigationController).map { stacks[ObjectIdentifier($0)]?.showsBar == true } ?? false
        }.map(\.stackRoutes)
    }

    /// A tab's controller, made once: a navigation controller for a tab
    /// whose panel draws its stack (`drawsStack`), else a plain tab.
    func makeTabStack(_ panel: UInt32, _ routes: [RouteController], drawsStack: Bool) -> UIViewController {
        guard drawsStack else {
            let plain = PlainTab()
            plainTabs[panel] = plain
            show(routes, in: plain)
            return plain
        }
        let nav = makeNavigation(first: routes.first?.node)
        prepareRoutes(routes, in: nav)
        nav.setViewControllers(routes, animated: false)
        recordOwned(nav)
        watchPops(nav)
        tabNavigations[panel] = nav
        return nav
    }

    /// A plain tab's route, projected and then shown.
    func show(_ routes: [RouteController], in plain: PlainTab) {
        prepareRoutes(routes, in: plain)
        plain.show(routes.first)
    }

    /// Build the tabs More's list shows a row for that the runner has not
    /// built (LLP 1075.003 §9.14), selecting none: a row for an empty
    /// navigation controller does nothing (iOS 27, measured), so each is
    /// built before a person can pick it. A plain tab needs nothing: More
    /// pushes a plain controller, empty or not.
    func buildTabsUnderMore() {
        #if os(iOS)
        guard !syncing, tabController != nil, let session = presenter.session else { return }
        let waiting = tabPanels.indices.filter { index in
            let panel = tabPanels[index]
            // (A built panel's children are its routes' nodes, which UIKit containment holds)
            return !barHasItem(ofTab: index) && tabNavigations[panel]?.viewControllers.isEmpty == true
                && logicalChildren[panel]?.isEmpty != false
        }.map { tabPanels[$0] }
        guard !waiting.isEmpty else { return }
        session.log("navigation: More's list shows tabs not built yet (panels \(waiting)); the runner builds them")
        session.buildTabs(waiting)
        #endif
    }

    /// UIKit moved tabs between the bar and More, and their routes with
    /// them (Edit, a width change; measured): a sync in the next turn writes
    /// each tab's routes where UIKit now holds them and follows the selected
    /// tab's, and More's list gets the tabs it now shows built.
    func syncNextTurn() {
        DispatchQueue.main.async { [weak self] in
            guard let self, tabOwner != nil else { return }
            sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
            buildTabsUnderMore()
        }
    }
}

extension ExactSession {
    /// Build the tab panels `panels`, selecting none (LLP 1075.003 §9.14).
    func buildTabs(_ panels: [UInt32]) {
        guard state != .destroyed, booted else { return }
        apply(runtime.buildTabs(panels, now: now()))
    }
}
#endif
