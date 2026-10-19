// What an embedder or the reader sends into a session: an agent request, a
// journal line, a field's value, an editor's selection, a URL, a followed link
// and a navigation.
import Foundation

extension ExactSession {
    public func agent(_ request: String) -> String { runtime.agent(request) }
    /// A line for the runner's journal (LLP 1012 §3; LLP 1035.001 D6): a
    /// refused intent and its reason, read back through `logs`.
    public func log(_ line: String) { runtime.log(line) }
    /// Deliver an embedder's value through a declared change handler. The
    /// selector must name exactly one live node; file contents stay data.
    @discardableResult public func change(testId: String, value: String) -> Bool {
        changeRefusal = nil
        guard state != .destroyed, booted else { changeRefusal = "it has not started"; return false }
        let matches = presenter.views.values.filter { $0.props["testId"] == testId && $0.handlers.contains("change") }
        guard matches.count == 1, let node = matches.first else {
            changeRefusal = matches.isEmpty ? "it has no `\(testId)` field with a `change` handler" : "it has \(matches.count) `\(testId)` fields"
            return false
        }
        let batch = runtime.change(node.id, documentValue(node.id, value), now: now())
        apply(batch)
        if let error = batch.error { changeRefusal = "its `change` was refused: \(error)" }
        return batch.error == nil
    }
    /// Deliver toolbar facts only when the authored editor has a select handler.
    package func selection(node: UInt32, json: String) {
        guard booted, state != .destroyed,
              presenter.views[node]?.handlers.contains("select") == true,
              let batch = runtime.selection(node, json: json, now: now()) else { return }
        apply(batch)
    }
    /// @ref LLP 1038 D8/D11 — pre-boot URLs are launch facts; the adapter consumes development links first.
    @discardableResult public func openURL(_ url: URL) -> Bool {
        guard state != .destroyed else { return false }
        return openIncoming(incomingLocation(url))
    }
    /// A link the reader followed — a `link href`, a text run's `href`, a
    /// Markdown link. A path naming one of the app's routes is a location
    /// for the navigation root, as the web's same-document link is (LLP 1038
    /// §7); anything else — a page, a file beside a document — is the
    /// containing app's to open (`openURL`).
    @discardableResult public func follow(_ href: String) -> Bool {
        guard state != .destroyed, !href.isEmpty else { return false }
        if href.hasPrefix("/"), !href.hasPrefix("//"), booted, runtime.routeMatches(href) { return navigate(href) }
        delegate?.exactSession(self, command: "openURL", args: [href])
        return true
    }
    @discardableResult public func navigate(_ location: String) -> Bool {
        guard state != .destroyed, booted else { return false }
        guard let node = navigationRoot else { log("navigate refused: no navigation root handler"); return false }
        let batch = runtime.navigate(node.id, location, now: now())
        apply(batch)
        return batch.error == nil
    }
}
