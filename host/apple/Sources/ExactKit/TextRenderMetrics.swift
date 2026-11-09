import Foundation
import QuartzCore

/// Diagnostic spans use fixed storage; workers hold the lock only to read a token or write one span.
final class TextRenderMetrics {
    static let shared = TextRenderMetrics()
    enum Kind: Int, CaseIterable {
        case coveragePaint, prepareGlyphs, preparePixels, prepareFailed, publishSingleColor, publishPixels, workerWait, prepareCoverage
    }
    struct Stamp { let capture: UInt64; let start: Double }
    struct Event {
        var start = 0.0, end = 0.0
        var kind = Kind.coveragePaint
        var node: UInt32 = 0
        var main = false
        var width = 0, height = 0, bytes = 0, detail = 0
    }
    private let lock = NSLock()
    private let clock: () -> Double
    private var capture: UInt64 = 0, nextCapture: UInt64 = 0
    private let capacity: Int
    private var events: [Event] = []
    private var written = 0

    init(capacity: Int = 16_384, clock: @escaping () -> Double = CACurrentMediaTime) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.clock = clock
    }

    var recording: Bool {
        lock.lock(); defer { lock.unlock() }
        return capture != 0
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        if events.isEmpty { events = Array(repeating: Event(), count: capacity) }
        nextCapture += 1; capture = nextCapture; written = 0
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        capture = 0
    }

    func begin() -> Stamp? {
        lock.lock()
        let token = capture
        lock.unlock()
        return token == 0 ? nil : Stamp(capture: token, start: clock())
    }

    func end(_ stamp: Stamp?, kind: Kind, node: UInt32 = 0, width: Int = 0, height: Int = 0, bytes: Int = 0, detail: Int = 0) {
        guard let stamp else { return }
        let end = clock(), main = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        guard capture == stamp.capture else { return }
        events[written % events.count] = Event(start: stamp.start, end: end, kind: kind, node: node, main: main,
            width: width, height: height, bytes: bytes, detail: detail)
        written += 1
    }

    /// Copy only after recording stops; encoding never runs in a rendering callback.
    func snapshot(origin: Double) -> [String: Any] {
        lock.lock()
        let count = written, capacity = self.capacity
        let kept = (max(0, count - capacity)..<count).map { events[$0 % capacity] }
        lock.unlock()
        return ["capacity": capacity, "written": count, "overwritten": max(0, count - capacity),
            "columns": ["start_us", "end_us", "kind", "node", "main_thread", "width_px", "height_px", "image_bytes", "detail"],
            "kinds": ["coveragePaint", "prepareGlyphs", "preparePixels", "prepareFailed", "publishSingleColor", "publishPixels", "workerWait", "prepareCoverage"],
            "rows": kept.map { e -> [Any] in
                [Int(((e.start - origin) * 1e6).rounded()), Int(((e.end - origin) * 1e6).rounded()), e.kind.rawValue,
                 e.node, e.main, e.width, e.height, e.bytes, e.detail]
            }]
    }
}

#if os(iOS) || os(tvOS)
extension TextRasterJob {
    func renderDiagnosed(node: UInt32) -> TextRasterImage? {
        let stamp = TextRenderMetrics.shared.begin()
        let result = render()
        let kind: TextRenderMetrics.Kind
        switch result?.content {
        case .drawn?: kind = .prepareGlyphs
        case .coverage?: kind = .prepareCoverage
        case .pixels?: kind = .preparePixels
        case nil: kind = .prepareFailed
        }
        let pixels: CGImage?
        switch result?.content {
        case .pixels(let image)?: pixels = image
        case .coverage(let coverage)?: pixels = coverage.mask
        default: pixels = nil
        }
        TextRenderMetrics.shared.end(stamp, kind: kind, node: node,
            width: pixels?.width ?? 0, height: pixels?.height ?? 0,
            bytes: pixels.map { $0.bytesPerRow * $0.height } ?? 0, detail: Int(result?.diagnosticFallback ?? 0))
        return result
    }
}
#endif
