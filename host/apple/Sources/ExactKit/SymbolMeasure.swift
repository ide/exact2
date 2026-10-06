// @ref LLP 1035.004.000 — a system symbol's box, measured in layout as a
// paragraph is (exact_set_symbol_measure), so the first layout has it; the
// view that draws the glyph reports the same size from the same function,
// so nothing moves when it does.
import CExact
import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

enum SymbolMeasure {
    /// The glyph for `name` at `points` and a CSS weight, nil when the OS has
    /// none by that name.
    static func image(_ name: String, points: CGFloat, weight: CGFloat) -> SymbolImage? {
        guard !name.isEmpty else { return nil }
        let index = min(8, max(0, Int((weight / 100).rounded()) - 1))
        let size = points > 0 ? points : 1
        #if os(iOS) || os(tvOS)
        let weights: [UIImage.SymbolWeight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weights[index]))
        #else
        let weights: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weights[index]))
        #endif
    }

    /// The box a symbol takes: its glyph's size, or an em square when the OS
    /// has no such glyph (LLP 1035.004.000 D2); none at a point size of 0.
    /// Kept across launches for one OS build and locale: making the image
    /// decodes its vector glyph, about 7 ms of Lexy's layout at launch.
    static func size(_ name: String, points: CGFloat, weight: CGFloat) -> CGSize? {
        guard points > 0 else { return nil }
        let key = "\(name) \(points.bitPattern) \(weight.bitPattern)"
        lock.lock()
        if !loaded { load() }
        let kept = sizes[key]
        lock.unlock()
        if let kept { return kept }
        let size = image(name, points: points, weight: weight)?.size ?? CGSize(width: points, height: points)
        lock.lock()
        sizes[key] = size
        if !saveQueued {
            saveQueued = true
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: save)
        }
        lock.unlock()
        return size
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sizes: [String: CGSize] = [:]
    nonisolated(unsafe) private static var loaded = false, saveQueued = false
    /// Symbols differ by OS build and some by locale: either names another file.
    private static let file: URL? = {
        let os = ProcessInfo.processInfo.operatingSystemVersionString, locale = Locale.preferredLanguages.first ?? Locale.current.identifier
        let stamp = "\(os) \(locale)".unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("exact/\(Bundle.main.bundleIdentifier ?? "app")/symbol-sizes-\(stamp).plist")
    }()

    /// Under `lock`. Sizes are stored as their bits, so they read back exactly.
    private static func load() {
        loaded = true
        guard let file, let data = try? Data(contentsOf: file),
              let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [UInt64]] else { return }
        for (key, bits) in stored where bits.count == 2 {
            sizes[key] = CGSize(width: Double(bitPattern: bits[0]), height: Double(bitPattern: bits[1]))
        }
    }

    private static func save() {
        lock.lock()
        saveQueued = false
        let stored = sizes.mapValues { [Double($0.width).bitPattern, Double($0.height).bitPattern] }
        lock.unlock()
        guard let file, let data = try? PropertyListSerialization.data(fromPropertyList: stored, format: .binary, options: 0) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The kernel's symbol measurer, on the runtime's thread.
    static let measure: ExactSymbolFn = { _, name, len, points, weight, out in
        guard let out else { return 0 }
        let text = name != nil && len > 0 ? String(decoding: UnsafeBufferPointer(start: name, count: len), as: UTF8.self) : ""
        guard let size = SymbolMeasure.size(text, points: CGFloat(points), weight: CGFloat(weight)) else { return 0 }
        out[0] = Float(size.width); out[1] = Float(size.height)
        return 1
    }
}
