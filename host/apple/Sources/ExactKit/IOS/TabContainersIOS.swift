// @ref LLP 1038 — what a tab bar controller holds for one tab. A tab is not a
// navigation stack by fiat: its root route names a container
// (`navigationContainer`), and the container shows the tab's screens — route
// controllers, root first, as far as the router's stack for that tab goes
// before a presented route — its own way. Navigation stays Contract's: no
// container adds or removes a screen.
//
// - "stack" (the default): a UINavigationController, which NavigationHost
//   drives for the selected tab (push, pop, the back swipe, sheets).
// - "screen": the root screen alone, with no navigation controller.
// - any other name: the app's native module's screen container
//   (`ExactModule.controllers`, NativeModule.swift), user space's own view
//   controller.
#if os(iOS)
import UIKit

protocol TabContainer: AnyObject {
    /// The `navigationContainer` this container answers.
    var kind: String { get }
    var controller: UIViewController { get }
    /// A stack container's navigation controller; nil for the others.
    var stack: UINavigationController? { get }
    /// The tab's screens, root first. A stack container's selected tab is
    /// NavigationHost's to drive, with animation; this is the plain swap.
    func show(_ screens: [UIViewController])
}

final class StackContainer: TabContainer {
    let kind = "stack"
    let navigation: UINavigationController
    init(_ navigation: UINavigationController) { self.navigation = navigation }
    var controller: UIViewController { navigation }
    var stack: UINavigationController? { navigation }
    func show(_ screens: [UIViewController]) {
        let current = navigation.viewControllers
        if current.count != screens.count || !zip(current, screens).allSatisfy({ $0 === $1 }) {
            navigation.setViewControllers(screens, animated: false)
        }
    }
}

/// The root screen as the tab's whole content: a tab that never pushes.
final class ScreenContainer: UIViewController, TabContainer {
    let kind: String
    private weak var shown: UIViewController?
    /// `kind` is "screen", or the module container this one stands in for
    /// until the module's artifact has loaded.
    init(kind: String = "screen") {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    var controller: UIViewController { self }
    var stack: UINavigationController? { nil }
    func show(_ screens: [UIViewController]) {
        let root = screens.first
        guard root !== shown else { return }
        if let shown, shown.parent === self {
            shown.willMove(toParent: nil)
            shown.view.removeFromSuperview()
            shown.removeFromParent()
        }
        shown = root
        guard let root else { return }
        root.willMove(toParent: nil)
        root.view.removeFromSuperview()
        root.removeFromParent()
        addChild(root)
        root.view.frame = view.bounds
        root.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(root.view)
        root.didMove(toParent: self)
    }
}

/// An app module's screen container.
final class ModuleContainer: TabContainer {
    let native: NativeContainer
    init(_ native: NativeContainer) { self.native = native }
    var kind: String { native.name }
    var controller: UIViewController { native.controller }
    var stack: UINavigationController? { nil }
    func show(_ screens: [UIViewController]) { native.setScreens(screens) }
}
#endif
