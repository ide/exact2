// Single-color text keeps shape and profiled color separate on UIKit.
#if os(iOS) || os(tvOS)
import UIKit

final class TextCoverage {
    let mask: CGImage
    let color: CGColor
    let drawing: TextDrawing?
    var bytes: Int { mask.bytesPerRow * mask.height }

    convenience init(_ mask: CGImage, color: CGColor) {
        self.init(mask, color: color, drawing: nil)
    }

    fileprivate convenience init(_ mask: CGImage, drawing: TextDrawing) {
        self.init(mask, color: drawing.color, drawing: drawing)
    }

    private init(_ mask: CGImage, color: CGColor, drawing: TextDrawing?) {
        self.mask = mask
        self.drawing = drawing
        // Keep each paint operation's opacity in coverage, including overlapping glyphs
        self.color = color.copy(alpha: 1) ?? color
    }

    /// Rebind a mask only after proving that its paint operations and opacity match the new glyph plan.
    func reusing(for drawing: TextDrawing) -> TextCoverage? {
        guard let previous = self.drawing, drawing.sharesCoverage(with: previous) else { return nil }
        return previous === drawing ? self : TextCoverage(mask, drawing: drawing)
    }

    /// Capture copies need public pixels because CALayer values do not describe UIKit's template tint.
    func painted() -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard let context = CGContext(data: nil, width: mask.width, height: mask.height, bitsPerComponent: 16,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        context.clip(to: bounds, mask: mask)
        context.setFillColor(color)
        context.fill(bounds)
        return context.makeImage()
    }
}

extension TextDrawing {
    /// Profile-only changes keep coverage when glyph paint, placement and opacity are unchanged.
    func sharesCoverage(with other: TextDrawing) -> Bool {
        guard frame == other.frame, scale == other.scale, pixelWidth == other.pixelWidth, pixelHeight == other.pixelHeight,
              smooths == other.smooths, color.alpha == other.color.alpha, positions == other.positions,
              lines.count == other.lines.count else { return false }
        return zip(lines, other.lines).allSatisfy { left, right in
            left.runs.count == right.runs.count && zip(left.runs, right.runs).allSatisfy { a, b in
                CFEqual(a.font, b.font) && a.glyphs == b.glyphs && a.positions == b.positions
            }
        }
    }

    /// Generate the displayed mask without retaining its pixels in the glyph-value cache.
    func coverage() -> TextCoverage? {
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth < Int.max - 63 else { return nil }
        let width = pixelWidth, height = pixelHeight, row = (pixelWidth + 63) & ~63
        let (bytes, overflow) = row.multipliedReportingOverflow(by: height)
        guard !overflow else { return nil }
        return withScratch(bytes) { data in
            guard let context = CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: row, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            paint(context)
            guard let image = context.makeImage() else { return nil }
            return TextCoverage(image, drawing: self)
        }
    }
}

extension TextRasterJob {
    /// Workers finish the mask before closing their mailbox; urgent publication can still reuse a live mask first.
    func renderPrepared(node: UInt32) -> TextRasterImage? {
        let rendered = renderDiagnosed(node: node)
        guard let result = rendered, case .drawn(let drawing) = result.content else { return rendered }
        let paint = TextRenderMetrics.shared.begin()
        let coverage = drawing.coverage()
        TextRenderMetrics.shared.end(paint, kind: .coveragePaint, node: node,
            width: drawing.pixelWidth, height: drawing.pixelHeight, bytes: coverage?.bytes ?? 0)
        return coverage.map { result.replacingInk(with: .coverage($0)) } ?? result
    }
}

/// UIKit owns the template image's layer and its colorization state.
final class CoverageImageView: UIImageView {
    private(set) var coverage: TextCoverage?
    var drawing: TextDrawing? { coverage?.drawing }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        tintAdjustmentMode = .normal
        contentMode = .scaleToFill
    }

    required init?(coder: NSCoder) { nil }

    func show(_ coverage: TextCoverage, scale: CGFloat) {
        if self.coverage.map({ !CFEqual($0.color, coverage.color) }) ?? true {
            tintColor = UIColor(cgColor: coverage.color)
        }
        self.coverage = coverage
        if image?.cgImage !== coverage.mask || image?.scale != scale {
            image = UIImage(cgImage: coverage.mask, scale: scale, orientation: .up).withRenderingMode(.alwaysTemplate)
        }
    }

    func clear() {
        image = nil
        coverage = nil
    }
}

/// Preserve the text box's resize and the lines' fade clock in a matching UIView hierarchy.
final class TextBoxView: UIView {
    private final class LinesView: UIView {
        override class var layerClass: AnyClass { InkLayer.self }
    }
    override class var layerClass: AnyClass { TextBoxLayer.self }
    let lines: UIView = LinesView(frame: .zero)
    var box: TextBoxLayer { layer as! TextBoxLayer }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        lines.isUserInteractionEnabled = false
        addSubview(lines)
        box.lines = lines.layer
        box.anchorPoint = .zero
        lines.layer.anchorPoint = .zero
    }

    required init?(coder: NSCoder) { nil }
}
#endif
