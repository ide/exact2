#if os(iOS) || os(tvOS)
import UIKit

/// The dialog sheets that may host it are captured at opening: a later
/// sheet must cover this layer. Elsewhere it is where BASE put every lifted
/// popover, the top live route modal's view or the viewport.
final class PopoverLayer: UIView {
    private struct Host { weak var controller: UIViewController? }
    private let hosts: [Host]
    let order: Int
    private(set) weak var sheet: UIViewController?
    private weak var popover: UIView?
    var rehost: (() -> Void)?
    private var mounting = false

    init(presenter: Presenter, order: Int, popover: UIView) {
        hosts = presenter.menus.sheets.controllers(holding: popover).reversed().map { Host(controller: $0) }
        self.order = order
        self.popover = popover
        super.init(frame: .zero)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
    required init?(coder: NSCoder) { nil }

    func mount(in presenter: Presenter) {
        mounting = true
        defer { mounting = false }
        var host: UIView = presenter.modals.coordinateView ?? presenter.viewport
        sheet = nil
        // A sheet hosts it only while its dialog still holds the popover: a move out of it leaves the sheet.
        let holding = popover.map { presenter.menus.sheets.controllers(holding: $0) } ?? []
        for candidate in hosts {
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
        setPaintForeground(sheet == nil)
        if sheet != nil {
            // Outside the session's root, as a sheet is: its theme and tint, as the sheet's (DialogSheetController).
            ThemeRoles.adopt(self, from: presenter.root)
            tintColor = ThemeRoles.color("AccentColor", in: self)
        }
        // Beside its sheet's card, it is hidden from accessibility with that card when a later sheet covers it.
        let covered = sheet?.viewIfLoaded?.accessibilityElementsHidden ?? false
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

extension MenuHost {
    /// A popover the agent opened (`agentOpen`): out of its parent into its
    /// `PopoverLayer` while open, and back at its index after.
    final class Lifted {
        var placement = PositionArea.History()
        /// Anchored to its opener at least once.
        var placed = false
        let source: UInt32?
        weak var popover: NodeView?
        weak var parent: UIView?
        var index: Int
        let center: CGPoint
        /// Its place in HTML's popover stack: when it opened, and the open
        /// popover it is nested in (its opener or its parent inside that
        /// one), which hiding hides it with (LLP 1021 §5, "Submenus").
        let order: Int
        let ancestor: String?
        let layer: PopoverLayer
        #if os(iOS)
        var relay: MountRelay?
        #endif
        init(source: UInt32?, popover: NodeView, order: Int, ancestor: String?, presenter: Presenter) {
            self.source = source; self.popover = popover; self.order = order; self.ancestor = ancestor
            layer = PopoverLayer(presenter: presenter, order: order, popover: popover)
            parent = popover.superview
            index = parent?.subviews.firstIndex(of: popover) ?? 0
            center = popover.center
        }
    }
}
#endif
