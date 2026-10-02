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
        if let owner = confirmation, !valid(owner) { resetConfirmation() }
        var popovers: [String: NodeView] = [:]
        for v in presenter.carrying("popover") + presenter.carrying("tag:dialog").filter({ $0.props["popover"] == nil }) {
            if ExactEnv.agentMode && !isConfirmation(v) { continue }
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
            if isConfirmation(pop) { live.remove(v.id); continue }
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
        owner.alert.dismiss(animated: !ExactEnv.agentFreezes) { [weak self, owner] in
            // A native action arrives after the alert leaves its window;
            // dismiss can therefore complete synchronously inside UIKit's
            // selection callback, before its dismissal delegate is called.
            // Keep the owner until that stack unwinds before app code can
            // destroy the presenting editor or dismiss its parent sheet.
            DispatchQueue.main.async { [weak self, owner] in
                guard let self, self.confirmation === owner else { return }
                let action = chosen.flatMap { self.valid(owner, action: $0) ? $0 : nil }
                self.confirmation = nil
                if let action { self.presenter?.press(action.id) }
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

    /// A touch's press on a confirmation's invoker: open it. True when `node`
    /// invokes one, whether or not it could open now.
    func invokeConfirmation(_ node: NodeView) -> Bool {
        guard let pop = confirmation(invokedBy: node) else { return false }
        _ = openConfirmation(from: node, popover: pop)
        return true
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
        guard confirmation == nil, eligible(source), live(pop), source.window != nil else { return false }
        let modal = isDialog(pop)
        let children = pop.container.subviews.compactMap { $0 as? NodeView }
        let actions = children.filter { $0.kind == "button" && $0.handlers.contains("press") }
        let cancels = children.filter { $0.kind == "button" && !$0.handlers.contains("press") && closes($0, pop) }
        // An alert may be a notice: no action, its one cancel acknowledging it.
        guard !actions.isEmpty || cancels.count == 1, cancels.count <= 1,
              children.allSatisfy({ $0.kind == "text" || actions.contains($0) || cancels.contains($0) }),
              (actions + cancels).allSatisfy({ closes($0, pop) }),
              actions.allSatisfy({ eligible($0, inertBoundary: modal ? pop.superview : nil) }) else {
            presenter?.session?.log("confirmation refused: its rows are texts, actions that close it, and at most one cancel")
            return false
        }
        var responder: UIResponder? = source
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let controller = responder as? UIViewController, controller.presentedViewController == nil,
              !controller.isBeingDismissed, !controller.isBeingPresented else { return false }
        var texts = children.filter { $0.kind == "text" }.map(title(of:)).filter { !$0.isEmpty }
        let heading = pop.props["accessibilityLabel"] ?? (modal && !texts.isEmpty ? texts.removeFirst() : nil)
        let owner = Confirmation(host: self, source: source, popover: pop, actions: actions, title: heading,
                                 message: texts.isEmpty ? nil : texts.joined(separator: "\n"),
                                 style: modal ? .alert : .actionSheet)
        for action in actions {
            let style: UIAlertAction.Style = action.props["destructive"] == "true" ? .destructive : .default
            owner.alert.addAction(UIAlertAction(title: title(of: action), style: style) { [weak self, weak owner, weak action] _ in
                if let owner { self?.finish(owner, chosen: action) }
            })
        }
        owner.alert.addAction(UIAlertAction(title: cancels.first.map(title(of:)) ?? "Cancel", style: .cancel) { [weak self, weak owner] _ in
            if let owner { self?.finish(owner, chosen: nil) }
        })
        if !modal {
            guard let presentation = owner.alert.popoverPresentationController else { return false }
            presentation.sourceView = source
            presentation.sourceRect = source.bounds
            presentation.delegate = owner
        }
        // An alert's presentation keeps its own delegate (UIKit asserts);
        // it is dismissed only by its actions.
        confirmation = owner
        controller.present(owner.alert, animated: !ExactEnv.agentFreezes)
        return true
    }

    /// The menu grammar, extracted (LLP 1021 D3): button rows become
    /// actions; any other row is a section boundary.
    private func items(of pop: NodeView) -> [UIMenuElement] {
        var sections: [[UIMenuElement]] = [[]]
        for case let row as NodeView in pop.container.subviews {
            if row.handlers.contains("press") {
                let id = row.id
                let action = UIAction(title: title(of: row)) { [weak self] _ in
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
        return v.container.subviews
            .compactMap { ($0 as? NodeView).map(title(of:)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
#endif
