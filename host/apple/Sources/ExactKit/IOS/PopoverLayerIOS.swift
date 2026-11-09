#if os(iOS) || os(tvOS)
import UIKit

extension MenuHost {
    /// Hears touches on the surface the popovers are lifted over: the top
    /// modal's view, or the view the document is mounted in.
    func observeTouches() {
        guard let presenter else { return }
        let surface = presenter.modals.coordinateView ?? presenter.documentHost
        guard touchObserver?.view !== surface else { return }
        if let observer = touchObserver { observer.view?.removeGestureRecognizer(observer) }
        let observer = PopoverTouch(host: self)
        surface.addGestureRecognizer(observer); touchObserver = observer
    }
}

/// Retain opening-time sheet eligibility and follow the current native card owner.
/// Keep authored popovers outside a platter's clip in its presentation container.
final class PopoverLayer: UIView {
    private struct Host { weak var controller: UIViewController? }
    private var hosts: [Host]
    let order: Int
    private(set) weak var sheet: UIViewController?
    private weak var popover: UIView?
    var rehost: (() -> Void)?
    #if os(iOS)
    weak var card: PopoverCard?
    private(set) weak var cardOwner: PopoverCard?
    #endif
    var externalOwner: Bool { sheet != nil || usesNativeCard }
    var usesNativeCard: Bool {
        #if os(iOS)
        cardOwner != nil
        #else
        false
        #endif
    }
    func closeCard() {
        #if os(iOS)
        card?.close()
        #endif
    }
    private var mounting = false

    init(presenter: Presenter, order: Int, popover: UIView) {
        hosts = presenter.menus.sheets.controllers(holding: popover).reversed().map { Host(controller: $0) }
        self.order = order
        self.popover = popover
        super.init(frame: .zero)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
    required init?(coder: NSCoder) { nil }

    /// Relocating the same open dialog preserves the popover's opening order.
    func replaceHost(_ old: UIViewController, with controller: UIViewController) {
        for index in hosts.indices where hosts[index].controller === old {
            hosts[index] = Host(controller: controller)
        }
    }

    func mount(in presenter: Presenter) {
        mounting = true
        defer { mounting = false }
        var host: UIView = presenter.modals.coordinateView ?? presenter.documentHost
        sheet = nil
        #if os(iOS)
        cardOwner = card ?? presenter.menus.cards.top
        if let cardOwner { host = card == nil ? cardOwner.presentationController?.containerView ?? cardOwner.view : cardOwner.view }
        #endif
        // A sheet hosts it only while its dialog still holds the popover: a move out of it leaves the sheet.
        let holding = popover.map { presenter.menus.sheets.controllers(holding: $0) } ?? []
        for candidate in hosts where !externalOwner {
            if let controller = candidate.controller,
               holding.contains(where: { $0 === controller }),
               controller.presentingViewController != nil,
               controller.viewIfLoaded?.window === presenter.viewport.window,
               let container = controller.presentationController?.containerView,
               container.window != nil, container.window === presenter.viewport.window {
                // UIKit's container is outside the rounded card and its scroller's clip.
                host = container; sheet = controller; break
            }
        }
        if superview !== host {
            if let above = host.subviews.compactMap({ $0 as? PopoverLayer }).first(where: { $0.order > order }) {
                host.insertSubview(self, belowSubview: above)
            } else { host.addSubview(self) }
        }
        // UIKit orders its own siblings; authored siblings use Exact's paint ranks.
        setPaintForeground(!externalOwner)
        if externalOwner {
            // Carry the session's theme and tint outside its root, as a dialog sheet does
            ThemeRoles.adopt(self, from: presenter.root)
            tintColor = ThemeRoles.color("AccentColor", in: self)
            if !(gestureRecognizers ?? []).contains(where: { $0 is PopoverTouch }) { addGestureRecognizer(PopoverTouch(host: presenter.menus)) }
        }
        // Hide the layer from accessibility with the presentation that owns it
        var covered = sheet?.viewIfLoaded?.accessibilityElementsHidden ?? false
        #if os(iOS)
        covered = covered || cardOwner?.viewIfLoaded?.accessibilityElementsHidden == true
        #endif
        if accessibilityElementsHidden != covered { accessibilityElementsHidden = covered }
        // Over the document, the page's area: not the bands the viewport is drawn past (LLP 1130).
        let place = (host as? UIScrollView)?.pageBounds ?? host.bounds
        if frame != place { frame = place }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if !mounting, window == nil, superview != nil { rehost?() }
    }

    static func containing(_ view: UIView?) -> PopoverLayer? {
        sequence(first: view, next: { $0?.superview }).compactMap { $0 as? PopoverLayer }.first
    }

    /// The layer takes no touch itself, only what it holds.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, bounds.contains(point) else { return nil }
        for child in NodeView.hitOrder(subviews) {
            if let hit = child.hitTest(convert(point, to: child), with: event) { return hit }
        }
        return nil
    }
}

/// Observes UIKit touches without consuming the underlying control's activation.
final class PopoverTouch: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var host: MenuHost?
    init(host: MenuHost) {
        self.host = host
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        delegate = self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touched = touches.first?.view { host?.lightDismiss(touched) }
        state = .failed
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
