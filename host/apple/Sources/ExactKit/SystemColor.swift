// @ref LLP 1081 D3, D5 — a colour row that names a platform colour: a role's
// class colour property (`secondaryLabelColor`), a `platform-color()`'s, an
// asset catalogue colour (`named:Brand`), or the view's inherited tint
// (`@tint`, `@tint/0.2` with an alpha). Resolved by name at runtime, so a
// colour an OS adds works with no Exact change, against the appearance the
// view draws in and the system's Increased Contrast; anything the OS lacks
// or that is not a colour is the fallback pair, logged once.
import ObjectiveC
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum SystemColor {
    /// CSS's `CanvasText`, the initial `color` (LLP 1081
    /// stage 2): the platform's own dynamic text colour, so a row the
    /// presenter has no value for still follows appearance and contrast.
    #if os(iOS)
    static let canvasText: UIColor = .label
    #else
    static let canvasText: NSColor = .textColor
    #endif
    /// `canvasText`'s channels under an appearance, for a painter that takes
    /// channels; the role's pair where the platform has no answer.
    static func canvasTextChannels(dark: Bool) -> [Double] {
        #if os(iOS)
        let name = "labelColor"
        #else
        let name = "textColor"
        #endif
        let pair: [Double] = dark ? [255, 255, 255, 255] : [0, 0, 0, 255]
        return channels(name, dark: dark, fallback: pair) ?? pair
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolved: [String: [Double]] = [:]
    nonisolated(unsafe) private static var refused: Set<String> = []
    /// The app's tint as last read on the main thread, for a read off it.
    nonisolated(unsafe) private static var lastTint: Native?

    /// Whether Increased Contrast is on, as `prefers-contrast` reads it (an
    /// agent's `prefer contrast more` pins it, LLP 1081 D7).
    static var highContrast: Bool { DisplayPreferences.contrast == "more" }

    /// A trait or a system colour changed: every resolution is stale.
    static func invalidate() {
        lock.lock(); resolved.removeAll(); lock.unlock()
    }

    /// The four channels (0–255) `name` shows in `dark`, else `fallback`.
    /// `elevated` is iOS's user-interface level: a sheet's or a popover's
    /// content, whose dark backgrounds are lighter.
    static func channels(_ name: String, dark: Bool, elevated: Bool = false, fallback: [Double]?) -> [Double]? {
        if name.hasPrefix("@tint") {
            let alpha = name.contains("/") ? Double(name.split(separator: "/").last ?? "") ?? 1 : 1
            return tint(alpha: alpha, dark: dark, fallback: fallback)
        }
        let contrast = highContrast
        let key = "\(name)|\(dark ? 1 : 0)|\(contrast ? 1 : 0)|\(elevated ? 1 : 0)"
        lock.lock()
        if let hit = resolved[key] { lock.unlock(); return hit }
        let known = !refused.contains(name)
        lock.unlock()
        guard known, let color = lookup(name), let rgba = rgba(color, dark: dark, contrast: contrast, elevated: elevated) else {
            lock.lock()
            if refused.insert(name).inserted { NSLog("Exact: no platform colour %@; its fallback is shown (LLP 1081 D3)", name) }
            lock.unlock()
            return fallback
        }
        lock.lock(); resolved[key] = rgba; lock.unlock()
        return rgba
    }

    #if os(iOS)
    private typealias Native = UIColor
    #else
    private typealias Native = NSColor
    #endif

    /// The colour a name looks up: an asset, or a zero-argument class method
    /// of `UIColor`/`NSColor` that returns a colour. The name is already
    /// checked (`roles.rs`'s `native_name_ok`), so no private or allocating
    /// selector is reachable.
    private static func lookup(_ name: String) -> Native? {
        if name.hasPrefix("named:") {
            let asset = String(name.dropFirst(6))
            #if os(iOS)
            return UIColor(named: asset)
            #else
            return NSColor(named: asset)
            #endif
        }
        guard name.hasSuffix("Color"), !name.hasPrefix("_") else { return nil }
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(Native.self, selector), method_getNumberOfArguments(method) == 2 else { return nil }
        let value = (Native.self as AnyObject).perform(selector)?.takeUnretainedValue()
        return value as? Native
    }

    /// The colour's sRGB channels under an appearance and contrast.
    private static func rgba(_ color: Native, dark: Bool, contrast: Bool, elevated: Bool = false) -> [Double]? {
        #if os(iOS)
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: contrast ? .high : .normal),
            UITraitCollection(userInterfaceLevel: elevated ? .elevated : .base),
        ])
        let c = color.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return [r, g, b, a].map { Double(min(max($0, 0), 1)) * 255 }
        #else
        let name: NSAppearance.Name = dark
            ? (contrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
            : (contrast ? .accessibilityHighContrastAqua : .aqua)
        var out: [Double]?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            out = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Double(min(max($0, 0), 1)) * 255 }
        }
        return out
        #endif
    }

    /// `AccentColor`: the app's tint (iOS) or the system accent (macOS),
    /// times an alpha (`Highlight` is the tint at 0.2 on iOS, LLP 1081 §6.1).
    private static func tint(alpha: Double, dark: Bool, fallback: [Double]?) -> [Double]? {
        var color: Native?
        if Thread.isMainThread {
            #if os(iOS)
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            color = window?.tintColor ?? .systemBlue
            #else
            color = NSColor.controlAccentColor
            #endif
            lock.lock(); lastTint = color; lock.unlock()
        } else {
            lock.lock(); color = lastTint; lock.unlock()
        }
        // The fallback already carries the alpha (`Highlight`'s is the tint's at 0.2).
        guard let color, var c = rgba(color, dark: dark, contrast: highContrast) else { return fallback }
        c[3] *= alpha
        return c
    }
}
