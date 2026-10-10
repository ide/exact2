#if os(iOS)
import UIKit

/// The keyboard raised ahead of a push into a route whose field autofocuses. UIKit builds the keyboard's views
/// on the main thread a run-loop turn after a field takes the focus; taken in the push's batch, that work lands
/// in the push's first frames and stalls them. A stand-in field with the route's field's keyboard traits takes
/// the focus first, the push starts as the keyboard shows (its will-show notification), and the route's field
/// takes the focus from the stand-in in the push's batch, over a keyboard already built.
@MainActor final class KeyboardLead {
    private let standIn = KeyboardStandIn(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
    private var observer: NSObjectProtocol?
    private var deadline: DispatchWorkItem?
    private var resume: (() -> Void)?
    /// The route the keyboard was last raised for, which is never led twice, and its field
    private weak var route: RouteController?
    private weak var input: UIResponder?

    var leading: Bool { resume != nil }

    /// Raise the keyboard for `route`'s autofocus field, then `resume` once it shows. A keyboard that never
    /// shows (a hardware keyboard's) resumes after 0.5 s. False when there is nothing to lead.
    func lead(_ route: RouteController, in host: UIView, resume: @escaping () -> Void) -> Bool {
        guard self.route !== route, let input = Self.autofocusInput(in: route.node) else { return false }
        self.route = route
        self.input = input
        copy(input)
        standIn.alpha = 0
        host.addSubview(standIn)
        guard standIn.becomeFirstResponder() else {
            standIn.removeFromSuperview()
            return false
        }
        self.resume = resume
        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        let deadline = DispatchWorkItem { [weak self] in self?.finish() }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: deadline)
        return true
    }

    /// Start the waiting push and give the route's field the focus in its batch, then let the stand-in go.
    /// The field's autofocus was spent while its route was out of the window, so the focus is given here.
    private func finish() {
        guard let resume else { return }
        self.resume = nil
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        deadline?.cancel()
        deadline = nil
        resume()
        if let input, (input as? UIView)?.window != nil { _ = input.becomeFirstResponder() }
        if standIn.isFirstResponder { standIn.resignFirstResponder() }
        standIn.removeFromSuperview()
    }

    /// The first text field or text area under `root` that autofocuses
    private static func autofocusInput(in root: UIView) -> (UIResponder & UITextInputTraits)? {
        if let node = root as? NodeView, node.props["autofocus"] == "true", !node.disabled {
            if let field = node.field { return field }
            if let area = node.textArea { return area }
        }
        for child in root.subviews {
            if let input = autofocusInput(in: child) { return input }
        }
        return nil
    }

    private func copy(_ traits: UITextInputTraits) {
        standIn.autocapitalizationType = traits.autocapitalizationType ?? .sentences
        standIn.autocorrectionType = traits.autocorrectionType ?? .default
        standIn.spellCheckingType = traits.spellCheckingType ?? .default
        standIn.smartQuotesType = traits.smartQuotesType ?? .default
        standIn.smartDashesType = traits.smartDashesType ?? .default
        standIn.smartInsertDeleteType = traits.smartInsertDeleteType ?? .default
        standIn.keyboardType = traits.keyboardType ?? .default
        standIn.keyboardAppearance = traits.keyboardAppearance ?? .default
        standIn.returnKeyType = traits.returnKeyType ?? .default
        standIn.enablesReturnKeyAutomatically = traits.enablesReturnKeyAutomatically ?? false
        standIn.isSecureTextEntry = traits.isSecureTextEntry ?? false
        standIn.textContentType = traits.textContentType ?? nil
    }
}
#endif

#if !os(macOS)
import UIKit

/// The field holding the keyboard for a route's field until it takes it: never a focus of the app's own
final class KeyboardStandIn: UITextField {}
#endif
