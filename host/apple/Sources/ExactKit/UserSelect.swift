// @ref CSS UI 4 §6.1 — `user-select`'s used value, on both Apple hosts: an
// editable element's is `contain`; `auto`'s is `all` under `all`, `none`
// under `none`, else `text`. The root's parent is each host's UA sheet's
// (LLP 1001): `none` on iOS, as UIKit selects no label; CSS's on macOS, where
// a paragraph is selectable, so `auto` is `text` there.
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension NodeView {
    /// A field or editor: CSS's editable element, which keeps its own selection.
    var editsText: Bool { field != nil || textArea != nil }
    /// The nearest node above this one.
    var parentNode: NodeView? {
        var view = superview
        while let current = view {
            if let node = current as? NodeView { return node }
            view = current.superview
        }
        return nil
    }
    /// The root's parent's used value (the host's UA sheet).
    static var rootUserSelect: String {
        #if os(iOS)
        "none"
        #else
        "text"
        #endif
    }
    /// `user-select`'s used value, given its parent's.
    func userSelect(parentUsed: String) -> String {
        if editsText { return "contain" }
        return NodeView.usedUserSelect(style["user_select"]?.string, parentUsed: parentUsed)
    }
    static func usedUserSelect(_ computed: String?, parentUsed: String) -> String {
        if let computed, computed != "auto" { return computed }
        return parentUsed == "all" || parentUsed == "none" ? parentUsed : "text"
    }
    /// `user-select`'s used value.
    var userSelect: String { userSelect(parentUsed: parentNode?.userSelect ?? NodeView.rootUserSelect) }

    /// The paragraph's shaped UTF-16 ranges a selection leaves out: all of it
    /// when its own used value is `none`, else its inline runs whose used
    /// value is.
    func unselectableRanges(used: String) -> [NSRange] {
        let spec = paragraphSpec()
        if used == "none" {
            return [NSRange(location: 0, length: spec.runs.reduce(0) { $0 + ($1.text as NSString).length })]
        }
        guard inlineText.contains(where: { $0.userSelect != nil }) else { return [] }
        let byId = Dictionary(inlineText.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func usedOf(_ run: InlineText) -> String {
            NodeView.usedUserSelect(run.userSelect, parentUsed: byId[run.parent].map(usedOf) ?? used)
        }
        return inlineText.filter { $0.paints && usedOf($0) == "none" }.map { run in
            let lo = spec.source.collapsed(run.range.location), hi = spec.source.collapsed(NSMaxRange(run.range))
            return NSRange(location: lo, length: max(0, hi - lo))
        }
    }
    /// The parts of `range` (shaped) a selection keeps.
    func selectableRanges(_ range: NSRange, used: String) -> [NSRange] {
        var kept: [NSRange] = []
        var at = range.location
        for cut in unselectableRanges(used: used).sorted(by: { $0.location < $1.location }) {
            let end = min(cut.location, NSMaxRange(range))
            if end > at { kept.append(NSRange(location: at, length: end - at)) }
            at = max(at, NSMaxRange(cut))
        }
        if NSMaxRange(range) > at { kept.append(NSRange(location: at, length: NSMaxRange(range) - at)) }
        return kept
    }
    /// `text` (shaped) within `range`, without what a selection leaves out.
    func selectableText(_ text: NSString, in range: NSRange, used: String) -> String {
        selectableRanges(range, used: used).map { text.substring(with: $0) }.joined()
    }
}
