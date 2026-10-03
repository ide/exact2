// The native menu arm (exact2 LLP 1021 D3): a popover whose rows are
// buttons presents as the platform's pull-down — a UIMenu off the invoker,
// built from the rows' data (text → title, aria-checked → the system
// checkmark, disabled → dimmed; a row without a press handler separates
// sections) — and a selection dispatches the row's press by view id into
// the runner: the same journal entry a painted tap makes, so the runner
// cannot tell the presentations apart. The popover subtree itself never
// paints here (the kernel-painted top layer is the web's; D2's is owed).
// Items are rebuilt every time the menu opens (UIDeferredMenuElement
// .uncached), after the invoker's own press has gone to the runner — both
// fire, D1 — so a menu that refreshes its rows on that press shows the
// refreshed rows.

#if os(iOS)
import UIKit

final class MenuHost {
    private weak var presenter: Presenter?
    private var overlays: [UInt32: UIButton] = [:]
    private var confirmation: Confirmation?

    /// A confirmation's rows are its actions (buttons that press) and at most
    /// one hide-only cancel ("Cancel" when there is none). A modal `dialog` is UIKit's centred alert, its
    /// first text the title; a popover is an action sheet anchored to its
    /// invoker, titled by its `aria-label`.
    /// Retain this owner until native dismissal completes; ids alone are not
    /// enough because a restart can reuse them for unrelated controls.
    private final class Confirmation: NSObject, UIPopoverPresentationControllerDelegate {
        weak var host: MenuHost?
        weak var source: NodeView?
        weak var popover: NodeView?
        let actions: NSHashTable<NodeView> = .weakObjects()
        let route: String?
        let alert: UIAlertController
        var finishing = false
        /// Shown because the dialog is `open`, not because an invoker
        /// opened it: closed when the state closes it.
        var held = false
        init(host: MenuHost, source: NodeView, popover: NodeView, actions: [NodeView], title: String?, message: String?, style: UIAlertController.Style) {
            self.host = host; self.source = source; self.popover = popover
            for action in actions { self.actions.add(action) }
            route = host.presenter?.navigation.routeKey(containing: source)
            alert = UIAlertController(title: title, message: message, preferredStyle: style)
        }
        func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
        func popoverPresentationControllerDidDismissPopover(_ controller: UIPopoverPresentationController) {
            host?.cancelled(self)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            host?.cancelled(self)
        }
    }

    init(presenter: Presenter) { self.presenter = presenter }

    private func isDialog(_ node: NodeView) -> Bool { node.props["semanticTag"] == "dialog" }
    private func isConfirmation(_ node: NodeView) -> Bool {
        isDialog(node) || node.props["accessibilityRole"] == "alertdialog"
    }
    private func target(of source: NodeView) -> String? {
        // An empty attribute names nothing, as a bound one may.
        if let name = source.props["commandfor"], !name.isEmpty { return name }
        return source.props["popovertarget"].flatMap { $0.isEmpty ? nil : $0 }
    }
    private func closes(_ source: NodeView, _ target: NodeView) -> Bool {
        if isDialog(target) {
            return source.props["commandfor"] == target.props["id"] && source.props["command"] == "close"
        }
        return source.props["popovertarget"] == target.props["id"] && source.props["popovertargetaction"] == "hide"
    }
    private func opens(_ source: NodeView, _ target: NodeView) -> Bool {
        self.target(of: source) == target.props["id"] && (isDialog(target)
            ? source.props["command"] == "show-modal" : source.props["popovertargetaction"] != "hide")
    }

    /// After a batch: hide every popover, and lay a transparent button
    /// whose primary action is the system menu over every invoker of one.
    func sync() {
        // Ordinary menus retain LLP 1021 D4's existing agent presentation.
        // Confirmations use the same UIKit owner under either input carrier.
        guard let presenter else { return }
        if let owner = confirmation, !owner.finishing, !valid(owner) { resetConfirmation() }
        if confirmation == nil, let held = presenter.carrying("tag:dialog").first(where: { $0.props["open"] == "true" }) {
            DispatchQueue.main.async { [weak self, weak held] in if let held { self?.presentHeld(held) } }
        }
        var popovers: [String: NodeView] = [:]
        for v in presenter.carrying("popover") + presenter.carrying("tag:dialog").filter({ $0.props["popover"] == nil }) {
            // Agent drives see a menu's rows inline (LLP 1021 D4); a
            // confirmation or content popover is UIKit's under either carrier.
            if ExactEnv.agentMode && !isConfirmation(v) && !isContent(v) { continue }
            if let shown = shownContent, shown.pop === v {
                if let name = v.props["id"] { popovers[name] = v }
                continue
            }
            v.isHidden = true
            if let name = v.props["id"] { popovers[name] = v }
        }
        var live = Set<UInt32>()
        for v in presenter.carrying("popovertarget") + presenter.carrying("commandfor").filter({ $0.props["popovertarget"] == nil }) {
            guard let target = target(of: v), let pop = popovers[target],
                  // A row that only hides its popover (a menu item closing
                  // itself, the spec's way) is not an invoker.
                  opens(v, pop)
            else { continue }
            live.insert(v.id)
            // A confirmation's invoker is pressed as itself (its own touch
            // feedback, its glass), and its press opens the confirmation
            // (`invokeConfirmation`); only a menu needs UIKit's button.
            if isConfirmation(pop) || isContent(pop) { live.remove(v.id); continue }
            let button = overlays[v.id] ?? {
                let b = UIButton(type: .custom)
                b.showsMenuAsPrimaryAction = true
                b.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                // The menu's button covers the invoker: carry its touch to
                // the invoker's own press feedback.
                for (events, down) in [(UIControl.Event([.touchDown, .touchDragEnter]), true),
                                       (UIControl.Event([.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit, .menuActionTriggered]), false)] {
                    b.addAction(UIAction { [weak b] _ in (b?.superview as? NodeView)?.pressed = down }, for: events)
                }
                overlays[v.id] = b
                return b
            }()
            if button.superview !== v { v.addSubview(button) }
            button.frame = v.bounds
            button.accessibilityLabel = v.props["accessibilityLabel"] ?? title(of: v)
            button.accessibilityIdentifier = v.props["testId"] ?? v.props["id"]
            button.isEnabled = !v.disabled
            let invokerId = v.id
            let hasPress = v.handlers.contains("press")
            button.menu = UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self, weak pop] completion in
                    if hasPress { self?.presenter?.press(invokerId) }
                    // The runner applies the press on its own thread; the
                    // items are read after it has (80 ms is invisible under
                    // the menu's own presentation).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        completion(pop.map { self?.items(of: $0) ?? [] } ?? [])
                    }
                }
            ])
        }
        for (id, b) in overlays where !live.contains(id) {
            b.removeFromSuperview()
            overlays[id] = nil
        }
    }

    private func live(_ node: NodeView) -> Bool { presenter?.views[node.id] === node }
    private func eligible(_ node: NodeView, inertBoundary: UIView? = nil) -> Bool {
        guard live(node), !node.disabled, presenter?.navigation.isInactiveRoute(containing: node) == false else { return false }
        var ancestor: UIView? = node
        var checksInert = true
        while let view = ancestor {
            // A modal dialog escapes inertness above itself. Its issued command
            // also survives the invoker subsequently becoming inert.
            if view === inertBoundary { checksInert = false }
            if let n = view as? NodeView, n.disabled || (checksInert && n.props["inert"] == "true") { return false }
            if view.isHidden {
                guard let pop = view as? NodeView, isConfirmation(pop),
                      pop.props["popover"] != nil || isDialog(pop) else { return false }
            }
            ancestor = view.superview
        }
        return true
    }
    private func valid(_ owner: Confirmation, action: NodeView? = nil) -> Bool {
        guard let source = owner.source, let pop = owner.popover else { return false }
        if owner.held {
            return live(pop) && pop.props["open"] == "true"
                && action.map { owner.actions.contains($0) && live($0) && !$0.disabled } ?? true
        }
        let modal = isDialog(pop)
        if let action {
            guard owner.actions.contains(action), eligible(action, inertBoundary: modal ? pop.superview : nil),
                  closes(action, pop), action.isDescendant(of: pop) else { return false }
        }
        return eligible(source, inertBoundary: modal ? source : nil) && live(pop) && source.window != nil
            && opens(source, pop) && isConfirmation(pop)
            && presenter?.navigation.routeKey(containing: source) == owner.route
    }
    private func cancelled(_ owner: Confirmation) {
        // UIKit also delivers this after a selected action's handler. That
        // notification must not cancel the action awaiting the next turn.
        guard confirmation === owner, !owner.finishing else { return }
        owner.finishing = true
        confirmation = nil
    }
    private func finish(_ owner: Confirmation, chosen: NodeView?) {
        guard confirmation === owner, !owner.finishing else { return }
        owner.finishing = true
        // The choice is the app's on the next turn, while the alert is still
        // leaving, as a system menu's is — not after its dismissal has played
        // out. The next turn, not this one: UIKit is inside its selection
        // callback, and the press may destroy the presenting editor or
        // dismiss its parent sheet.
        DispatchQueue.main.async { [weak self, owner] in
            guard let self, self.confirmation === owner else { return }
            let action = chosen.flatMap { self.valid(owner, action: $0) ? $0 : nil }
            if let action { self.presenter?.press(action.id) }
        }
        owner.alert.dismiss(animated: !ExactEnv.agentFreezes) { [weak self, owner] in
            // Keep the owner until UIKit's stack unwinds.
            DispatchQueue.main.async { [weak self, owner] in
                guard let self, self.confirmation === owner else { return }
                self.confirmation = nil
            }
        }
    }
    private func resetConfirmation() {
        guard let owner = confirmation else { return }
        confirmation = nil
        owner.finishing = true
        // Only this session's alert; never dismiss through a containing app's
        // root controller, which might now present something unrelated.
        owner.alert.dismiss(animated: false) { _ = owner }
    }
    func reset() {
        resetConfirmation()
        shownContent?.dismiss(animated: false)
        overlays.values.forEach { $0.removeFromSuperview() }
        overlays.removeAll()
    }
    func unmounted() { resetConfirmation() }
    var inTransition: Bool {
        guard let owner = confirmation else { return false }
        return owner.finishing || owner.alert.isBeingPresented || owner.alert.isBeingDismissed
    }
    func observation() -> [String: Any]? {
        guard let owner = confirmation else { return nil }
        return ["kind": "confirmation", "source": owner.source.map { Int($0.id) as Any } ?? NSNull(),
                "popover": owner.popover.map { Int($0.id) as Any } ?? NSNull(), "phase": inTransition ? "transition" : "open",
                "actionStyle": owner.alert.actions.first?.style == .destructive ? "destructive" : "default"]
    }
    func ownsConfirmationNode(_ node: NodeView) -> Bool {
        var ancestor: UIView? = node
        while let view = ancestor {
            if let n = view as? NodeView, isConfirmation(n), n.props["popover"] != nil || isDialog(n) { return true }
            ancestor = view.superview
        }
        return false
    }
    /// Public UIKit has no UIAlertAction view/rectangle. Activation is named
    /// honestly, and only works while this original action is presented.
    func activate(_ node: NodeView) -> Bool? {
        if ownsConfirmationNode(node) {
            guard let owner = confirmation, !inTransition, valid(owner) else { return false }
            if owner.actions.contains(node) { finish(owner, chosen: node); return true }
            if let pop = owner.popover, node.isDescendant(of: pop), !node.disabled,
               closes(node, pop) {
                finish(owner, chosen: nil); return true
            }
            return false
        }
        if let pop = contentPopover(invokedBy: node) {
            openContent(from: node, popover: pop)
            return true
        }
        guard let pop = confirmation(invokedBy: node) else { return nil }
        return openConfirmation(from: node, popover: pop)
    }
    /// The confirmation `node` opens, when it is a confirmation's invoker.
    func confirmation(invokedBy node: NodeView) -> NodeView? {
        guard let name = target(of: node), let pop = presenter?.views.values.first(where: {
            $0.props["id"] == name && isConfirmation($0) && ($0.props["popover"] != nil || isDialog($0))
        }), opens(node, pop) else { return nil }
        return pop
    }

    /// A touch's press on a confirmation's (or a content popover's) invoker:
    /// open it. True when `node` invokes one, whether or not it could open now.
    func invokeConfirmation(_ node: NodeView) -> Bool {
        if let pop = confirmation(invokedBy: node) {
            _ = openConfirmation(from: node, popover: pop)
            return true
        }
        if let pop = contentPopover(invokedBy: node) {
            openContent(from: node, popover: pop)
            return true
        }
        return false
    }

    // MARK: Content popovers

    /// A popover whose rows are not a menu's (no row presses) and that is not
    /// a confirmation: its own boxes, shown in UIKit's popover from its
    /// invoker (a tooltip, a detail), sized as laid out.
    private func isContent(_ pop: NodeView) -> Bool {
        guard pop.props["popover"] != nil, !isConfirmation(pop) else { return false }
        let rows = pop.container.subviews.compactMap { $0 as? NodeView }
        return !rows.isEmpty && !rows.contains { $0.handlers.contains("press") }
    }

    func contentPopover(invokedBy node: NodeView) -> NodeView? {
        guard let name = target(of: node), let pop = presenter?.views.values.first(where: {
            $0.props["id"] == name && isContent($0)
        }), opens(node, pop) else { return nil }
        return pop
    }

    private var shownContent: ContentPopover?

    private func openContent(from source: NodeView, popover pop: NodeView) {
        if source.handlers.contains("press") { presenter?.press(source.id) }
        guard shownContent == nil, live(pop), source.window != nil else { return }
        var responder: UIResponder? = source
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard var controller = responder as? UIViewController else { return }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed { controller = presented }
        let shown = ContentPopover(pop: pop) { [weak self] in self?.shownContent = nil }
        guard let presentation = shown.popoverPresentationController else { return }
        presentation.sourceView = source
        presentation.sourceRect = source.bounds
        presentation.delegate = shown
        shownContent = shown
        controller.present(shown, animated: !ExactEnv.agentFreezes)
    }

    /// A dialog the state holds `open` (HTML's attribute): presented as
    /// UIKit's alert while it is, its button presses the app's to close it.
    private func presentHeld(_ pop: NodeView) {
        guard confirmation == nil, live(pop), pop.window != nil else { return }
        if let owner = build(source: pop, pop: pop, modal: true) {
            owner.held = true
            present(owner, from: pop)
        }
    }

    private func openConfirmation(from source: NodeView, popover pop: NodeView) -> Bool {
        guard confirmation == nil, eligible(source), live(pop), source.window != nil else { return false }
        if isDialog(pop) && pop.props["closedby"] != "any" {
            presenter?.session?.log("dialog refused: native confirmation currently requires closedby=any")
            return false
        }
        // Session.press applies its batch synchronously. Both invoker actions
        // fire, as on the web; read the updated rows only if these identities
        // survived that action (no elapsed-time guess or successor id).
        if source.handlers.contains("press") { presenter?.press(source.id) }
        guard confirmation == nil, eligible(source), live(pop), source.window != nil,
              let owner = build(source: source, pop: pop, modal: isDialog(pop)) else { return false }
        return present(owner, from: source)
    }

    /// The alert for a dialog or confirmation popover's rows, or nil (and a
    /// log line) when they are not texts, actions and at most one cancel.
    private func build(source: NodeView, pop: NodeView, modal: Bool) -> Confirmation? {
        let children = pop.container.subviews.compactMap { $0 as? NodeView }
        let actions = children.filter { $0.isButton && $0.handlers.contains("press") }
        let cancels = children.filter { $0.isButton && !$0.handlers.contains("press") && closes($0, pop) }
        // An alert may be a notice: no action, its one cancel acknowledging it.
        guard !actions.isEmpty || cancels.count == 1, cancels.count <= 1,
              children.allSatisfy({ $0.kind == "text" || actions.contains($0) || cancels.contains($0) }),
              (actions + cancels).allSatisfy({ closes($0, pop) }),
              actions.allSatisfy({ eligible($0, inertBoundary: modal ? pop.superview : nil) }) else {
            presenter?.session?.log("confirmation refused: its rows are texts, actions that close it, and at most one cancel")
            return nil
        }
        var texts = children.filter { $0.kind == "text" }.map(title(of:)).filter { !$0.isEmpty }
        let heading = pop.props["accessibilityLabel"] ?? (modal && !texts.isEmpty ? texts.removeFirst() : nil)
        let owner = Confirmation(host: self, source: source, popover: pop, actions: actions, title: heading,
                                 message: texts.isEmpty ? nil : texts.joined(separator: "\n"),
                                 style: modal ? .alert : .actionSheet)
        // A native action's tint is its accent (LLP 1069.011.000 D5); a
        // custom row keeps the system's tint, as UIKit's own sheets do.
        if let action = actions.first, action.isNativeButton, let accent = action.channels("accent_color") {
            owner.alert.view.tintColor = TextEngine.color(accent)
        }
        for action in actions {
            let style: UIAlertAction.Style = action.props["destructive"] == "true" ? .destructive : .default
            owner.alert.addAction(UIAlertAction(title: title(of: action), style: style) { [weak self, weak owner, weak action] _ in
                if let owner { self?.finish(owner, chosen: action) }
            })
        }
        // An action sheet always has its cancel; an alert, the one it declares.
        if !cancels.isEmpty || !modal {
            owner.alert.addAction(UIAlertAction(title: cancels.first.map(title(of:)) ?? "Cancel", style: .cancel) { [weak self, weak owner] _ in
                if let owner { self?.finish(owner, chosen: nil) }
            })
        }
        if !modal {
            guard let presentation = owner.alert.popoverPresentationController else { return nil }
            presentation.sourceView = source
            // From the invoker's box, with UIKit's arrow, as a sheet anchored
            // to a control is.
            presentation.sourceRect = source.bounds
            presentation.delegate = owner
        }
        return owner
    }

    @discardableResult
    private func present(_ owner: Confirmation, from source: NodeView) -> Bool {
        var responder: UIResponder? = source
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard var controller = responder as? UIViewController else { return false }
        // Over whatever this session's controller already presents (a sheet).
        while let presented = controller.presentedViewController, !presented.isBeingDismissed { controller = presented }
        guard !controller.isBeingDismissed, !controller.isBeingPresented else { return false }
        // An alert's presentation keeps its own delegate (UIKit asserts);
        // it is dismissed only by its actions.
        confirmation = owner
        controller.present(owner.alert, animated: !ExactEnv.agentFreezes)
        return true
    }

    /// The menu grammar, extracted (LLP 1021 D3): button rows become
    /// actions; any other row is a section boundary.
    func items(of pop: NodeView) -> [UIMenuElement] {
        var sections: [[UIMenuElement]] = [[]]
        for case let row as NodeView in pop.container.subviews {
            if row.handlers.contains("press") {
                let id = row.id
                // A row's symbol is its item's image, custom or native (LLP 1069.011.000 D5).
                let image = row.isButton ? row.face?.symbol.flatMap { UIImage(systemName: $0) } : nil
                let action = UIAction(title: title(of: row), image: image) { [weak self] _ in
                    self?.presenter?.press(id)
                }
                if row.props["accessibilityChecked"] == "true" { action.state = .on }
                if row.props["disabled"] == "true" { action.attributes.insert(.disabled) }
                if row.props["destructive"] == "true" { action.attributes.insert(.destructive) }
                sections[sections.count - 1].append(action)
            } else if !(sections.last?.isEmpty ?? true) {
                sections.append([])
            }
        }
        let filled = sections.filter { !$0.isEmpty }
        if filled.count <= 1 { return filled.first ?? [] }
        return filled.map { UIMenu(options: .displayInline, children: $0) }
    }

    private func title(of v: NodeView) -> String {
        if v.kind == "text" { return v.paragraphSpec().runs.map(\.text).joined() }
        // A native button's children are its face, not views: its title, else its label.
        if v.isNativeButton { return v.face?.shown ?? "" }
        // A custom button whose face fits shows it too: a symbol-only row its
        // label (LLP 1069.011.000 D5); other content keeps its text.
        if v.isButton, let face = v.face, face.fits, let shown = face.shown { return shown }
        return v.container.subviews
            .compactMap { ($0 as? NodeView).map(title(of:)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
/// UIKit's popover holding a content popover's own boxes, borrowed from
/// where they live and given back, hidden, when it closes. The kernel keeps
/// laying the popover out where it stands; the view's bounds follow its
/// frame, so the boxes show from their own origin.
final class ContentPopover: UIViewController, UIPopoverPresentationControllerDelegate {
    weak var pop: NodeView?
    private weak var home: UIView?
    private let closed: () -> Void
    init(pop: NodeView, closed: @escaping () -> Void) {
        self.pop = pop
        self.closed = closed
        home = pop.superview
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        preferredContentSize = pop.bounds.size
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let pop else { return }
        view.addSubview(pop)
        pop.isHidden = false
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard let pop else { return }
        if preferredContentSize != pop.bounds.size { preferredContentSize = pop.bounds.size }
        view.bounds.origin = pop.frame.origin
    }
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { giveBack() }
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: flag) { [weak self] in self?.giveBack(); completion?() }
    }
    private func giveBack() {
        if let pop, let home, pop.superview !== home {
            pop.isHidden = true
            home.addSubview(pop)
        }
        closed()
    }
}
#endif
