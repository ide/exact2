// @ref LLP 1035.001.000 — what UIKit shows, read back and told to the app.
// The host changed nothing since it last applied the app's routes, so any
// difference UIKit settles on is the platform's: the back button, its
// long-press menu, a swipe, a sheet pulled down, the More list. It reaches
// the app as the route the person went back to (one `traverse`, or the
// route's own Back control until it is the top), before anything is
// projected again (`sync`, NavigationIOS.swift).
#if os(iOS) || os(tvOS)
import UIKit

extension NavigationHost {
    /// The More list's navigation controller (iOS; tvOS has none).
    var moreNavigation: UINavigationController? {
        #if os(iOS)
        tabController?.moreNavigationController
        #else
        nil
        #endif
    }

    /// D1: in flight is UIKit's to say — a stack's, the tab bar controller's
    /// or the More list's transition coordinator, a presentation's — never a
    /// flag a callback that did not come could leave set.
    var inFlight: Bool {
        presenter.modals.inTransition || tabController?.transitionCoordinator != nil
            || moreNavigation?.transitionCoordinator != nil
            || allNavigations.contains { $0.transitionCoordinator != nil }
    }

    /// A navigation controller whose transitions are the host's to settle:
    /// one it built, or the More list's.
    func owns(_ nav: UINavigationController) -> Bool {
        allNavigations.contains { $0 === nav } || nav === moreNavigation
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
                let navs = allNavigations + [moreNavigation].compactMap { $0 }
                for nav in navs { nav.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.settle() } }
                return
            }
            let observed = observe()
            if let applied, owed == nil, let change = NavigationRules.platformChange(applied: applied, observed: observed) {
                owed = change
            }
            applied = observed
            deliver()
            sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
            presenter.syncModal()
            presenter.session?.view?.fit()
            presenter.flushPendingFocus()
            #if os(iOS)
            // At rest, the status bar's style resolves (LLP 1105).
            presenter.resolveStatusBar(settled: true)
            #endif
        }
    }

    /// D4: tell the app what the platform did, once, through what the app
    /// declared — its root's `traverse` with the destination's key, or else
    /// its Back control until the destination is the top, each resolved
    /// anew — with projection suspended until it has answered (I1: never a
    /// count of presses taken from the transition).
    func deliver() {
        guard let change = owed else { return }
        owed = nil
        delivering = true
        defer { delivering = false }
        switch change {
        case .select(let tab):
            reported = "select \(tab)"
            guard let root = container, let tabs = NavigationTabs.of(root, presenter),
                  let index = tabs.panels.firstIndex(where: { tabName($0) == tab }) else { return }
            _ = act(tabs.tabs[index].id, 0)
        case .backTo(let key):
            guard let chain = appSnapshot()?.chain, NavigationRules.backs(app: chain, to: key) != nil else {
                // The app has gone elsewhere since: its state wins.
                return
            }
            reported = "backTo \(key)"
            if let root = container, root.handlers.contains("traverse") {
                presenter.onTraverse?(root.id, key)
                if appSnapshot()?.chain.last != key { presenter.session?.log("navigation: traverse to \"\(key)\" left the app elsewhere") }
                return
            }
            while true {
                let before = appSnapshot()?.chain ?? []
                guard before.last != key, before.contains(key) else { return }
                guard canInvokeBack else {
                    presenter.session?.log("navigation: back to \"\(key)\" refused: \(backRefusal)")
                    return
                }
                goBack()
                // Each press must shorten the chain; one that does not is the
                // app's refusal, and stops it.
                let after = appSnapshot()?.chain ?? []
                if after.count >= before.count {
                    presenter.session?.log("navigation: back to \"\(key)\" refused by the app")
                    return
                }
            }
        }
    }

    /// D2: what UIKit shows now, by route key — never a callback's argument.
    func observe() -> NavigationRules.Snapshot {
        let keys = { (controllers: [UIViewController]) in controllers.compactMap { ($0 as? RouteController)?.key } }
        var tab: String?, stack: [String] = []
        if tabOwner != nil {
            if let tabs = tabController {
                tab = shownTab(of: tabs) ?? applied?.tab
                let more = moreNavigation
                if moreListOpen {
                    stack = applied?.stack ?? []
                } else if let more, moreTab(of: tabs) == tab, more.viewControllers.dropFirst().first is RouteController {
                    stack = keys(more.viewControllers)
                } else if let nav = tab.flatMap(navigation(ofTab:)) {
                    stack = keys(nav.viewControllers)
                }
            } else {
                // The app's own container (a `tabContainer` hook): the tab the
                // router selected is the one it shows.
                tab = tabPanels.indices.contains(routerTab) ? presenter.views[tabPanels[routerTab]].map(tabName) : applied?.tab
                stack = keys(primaryNavigation?.viewControllers ?? [])
            }
        } else if let primaryNavigation {
            stack = keys(primaryNavigation.viewControllers)
        }
        return .init(tab: tab, stack: stack, presented: presentedNavigations.map { keys($0.viewControllers) })
    }

    /// The same snapshot, of the app's tree: its selected tab, the stack
    /// through the route the root names up to its first presentation, then
    /// each presentation's own.
    func appSnapshot() -> NavigationRules.Snapshot? {
        guard let root = container else { return nil }
        let rootKey = root.props["navigationKey"] ?? ""
        let tabs = NavigationTabs.of(root, presenter)
        for owner in tabs?.panels ?? [root] {
            let routes = (logicalChildren[owner.id] ?? []).compactMap { presenter.views[$0] }.filter { $0.props["navigationKey"] != nil }
            let keys = routes.map { $0.props["navigationKey"] ?? "" }
            guard let range = NavigationRules.stack(routeKeys: keys, selected: rootKey) else { continue }
            let parts = NavigationRules.segments(presentations: routes[range].map { $0.props["navigationPresentation"] })
            return .init(tab: tabs == nil ? nil : tabName(owner), stack: Array(keys[parts[0]]),
                         presented: parts.dropFirst().map { Array(keys[$0]) })
        }
        return nil
    }

    /// A tab by its panel: its HTML id, else its node.
    func tabName(_ panel: NodeView) -> String { panel.props["id"] ?? "#\(panel.id)" }

    private func navigation(ofTab tab: String) -> UINavigationController? {
        tabPanels.first { presenter.views[$0].map(tabName) == tab }.flatMap { tabNavigations[$0] }
    }

    /// The tab UIKit shows: the selected stack's, or the one shown inside the
    /// More list. The More list alone is UIKit's chrome over the tabs, not a
    /// route: nil, and the snapshot keeps the tab it had.
    private func shownTab(of tabs: UITabBarController) -> String? {
        if let more = moreNavigation, tabs.selectedViewController === more { return moreTab(of: tabs) }
        return tabName(of: tabs.selectedViewController)
    }

    private func tabName(of controller: UIViewController?) -> String? {
        guard let controller, let panel = tabNavigations.first(where: { $0.value === controller })?.key else { return nil }
        return presenter.views[panel].map(tabName)
    }

    /// The tab the More list's navigation controller shows past its list: a
    /// stack's screens, which UIKit hands it while it does.
    func moreTab(of tabs: UITabBarController) -> String? {
        guard let first = moreNavigation?.viewControllers.dropFirst().first else { return nil }
        if let route = first as? RouteController {
            return logicalChildren.first { $0.value.contains(route.node.id) }.flatMap { presenter.views[$0.key] }.map(tabName)
        }
        return tabName(of: first)
    }

    /// The tabs in the order UIKit shows them — the person's, once they have
    /// rearranged them through More's Edit.
    func tabOrder(of tabs: UITabBarController) -> [String] {
        (tabs.viewControllers ?? []).compactMap { tabName(of: $0) }
    }

    /// The controllers at the bottom of a stack that are UIKit's, not routes:
    /// the More list under a tab shown through it.
    func held(_ nav: UINavigationController) -> [UIViewController] {
        nav === moreNavigation ? Array(nav.viewControllers.prefix(1)) : []
    }

    /// The More list open at its root over the tab the app still selects:
    /// UIKit's chrome, as a menu is, so neither reported nor undone.
    var moreListOpen: Bool {
        guard let tabs = tabController, let more = moreNavigation, tabs.selectedViewController === more else { return false }
        return more.viewControllers.count <= 1 && applied?.tab == appSnapshot()?.tab
    }

    /// D5: a sheet waiting on an owner that already presents starts once that
    /// has gone. Menus, popovers and the share sheet settle as they leave;
    /// this catches whatever else UIKit or the app's module put there.
    func retry() {
        guard !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            retrying = false
            if dirty, container != nil { settle() }
        }
    }

    /// A sheet's backdrop (`closedby="any"`) asks to leave the presentation
    /// the route opens, as pulling it down does: back to the route beneath it.
    func requestBack(from source: NodeView) {
        guard presenter.session?.view?.window != nil, presenter.views[source.id] === source,
              let key = source.props["navigationKey"], let chain = appSnapshot()?.chain,
              let index = chain.firstIndex(of: key), index > 0, owed == nil else { return }
        owed = .backTo(chain[index - 1])
        deliver()
        sync(Batch(ops: [], timers: false, motion: false, clock: nil, error: nil))
    }

    /// D6: whether the app permits leaving its active route — what the swipe
    /// and a sheet's pull-down ask before they may begin.
    var backPermittedNow: Bool {
        guard let route = selectedRoute else { return false }
        return backPermitted(in: route)
    }

    /// D6: a route's own Back control decides — enabled, leaving is
    /// permitted; disabled, it is not. With none, a root that hears
    /// `traverse` is told by that event, and a visit beneath is a way back
    /// (LLP 1115 D5), so leaving is permitted.
    func backPermitted(in route: NodeView) -> Bool {
        let name = container?.props["navigationBack"]
        let named = presenter.carrying("id").filter { $0.props["id"] == name && ($0 === route || $0.isDescendant(of: route)) }
        return NavigationRules.backPermitted(hasControl: !named.isEmpty,
                                             controlEnabled: named.contains { $0.handlers.contains("press") && !$0.disabled },
                                             traverses: container?.handlers.contains("traverse") == true,
                                             beneath: route.props["navigationKey"].flatMap { presenter.session?.runtime.locationBeneath($0) }.map { !$0.isEmpty } ?? false)
    }
}
#endif
