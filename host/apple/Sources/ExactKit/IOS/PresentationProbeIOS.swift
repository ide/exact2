#if (os(iOS) || os(tvOS)) && !targetEnvironment(macCatalyst)
import Metal
import QuartzCore
import UIKit

/// A recording's presentation probe: a transparent Metal layer of one
/// point in the session's window that presents a drawable, cleared off the
/// main thread, with the transaction of each UI update one is ready for, so
/// its drawable's `presentedTime` says when the frame holding it reached
/// the screen, whatever made it late: a commit past its deadline or the
/// render server missing its own. A plain layer, not a view, it takes no
/// touches, is no accessibility element and changes no layout or safe
/// area. On the simulator, whose Metal has no `presentedTime` or
/// `addPresentedHandler` (MTLDrawable.h in its SDKs), it presents but hears
/// nothing, and its frames wait until it goes.
final class PresentationProbe {
    private let layer = CAMetalLayer()
    private let commands: MTLCommandQueue
    private let fetching = DispatchQueue(label: "exact.presentation-probe")
    private let lock = NSLock()
    /// The drawable fetched and cleared for the next update, whether a
    /// fetch is under way, and the reports waiting for the main thread: each
    /// drawable's number (`presentations` when it was presented) and when
    /// it was shown (0: never).
    private var ready: CAMetalDrawable?, fetchRunning = false
    private var reports: [(drawable: Int, presented: CFTimeInterval)] = []
    /// The drawables it presented.
    private(set) var presentations = 0

    init?(in window: UIWindow) {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else { return nil }
        self.commands = commands
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.presentsWithTransaction = true
        layer.allowsNextDrawableTimeout = true
        layer.drawableSize = CGSize(width: 1, height: 1)
        layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        // Above the window's content, which could otherwise cover it from the compositor
        layer.zPosition = .greatestFiniteMagnitude
        window.layer.addSublayer(layer)
        fetch()
    }

    var isInstalled: Bool { layer.superlayer != nil }

    func isIn(_ window: UIWindow) -> Bool { layer.superlayer === window.layer }

    /// Take the layer out of its window, which its owner does before it lets
    /// the probe go: a fetch under way can hold the probe until it returns.
    func remove() { layer.removeFromSuperlayer() }

    /// Fetch and clear the next drawable off the main thread, where
    /// `nextDrawable` can wait for frames while every drawable is queued or
    /// on screen (UIKit's advice in UIUpdateActionPhase.h), and the clear
    /// waits until it is scheduled, as a layer that presents with its
    /// transaction needs before `present`.
    private func fetch() {
        guard lock.withLock({ () -> Bool in
            guard !fetchRunning, ready == nil else { return false }
            fetchRunning = true
            return true
        }) else { return }
        fetching.async { [layer, commands, weak self] in
            let drawable = layer.nextDrawable().flatMap { Self.cleared($0, by: commands) }
            guard let self else { return }
            self.lock.withLock { self.ready = drawable; self.fetchRunning = false }
        }
    }

    private static func cleared(_ drawable: CAMetalDrawable, by commands: MTLCommandQueue) -> CAMetalDrawable? {
        guard let buffer = commands.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.commit()
        buffer.waitUntilScheduled()
        return drawable
    }

    /// Present the drawable made ready with the UI update now committing;
    /// the number its report will carry, or nil when no drawable was ready
    /// (the main thread never waits for one).
    func present() -> Int? {
        defer { fetch() }
        guard let drawable = lock.withLock({ () -> CAMetalDrawable? in defer { ready = nil }; return ready }) else { return nil }
        presentations += 1
        let number = presentations
        #if !targetEnvironment(simulator)
        drawable.addPresentedHandler { [weak self] shown in self?.heard(number, at: shown.presentedTime) }
        #endif
        drawable.present()
        return number
    }

    /// Metal's report that drawable `number` was shown at `presented`, or
    /// never (0), from any thread. On the simulator only a test stands in
    /// for it.
    func heard(_ number: Int, at presented: CFTimeInterval) {
        lock.withLock { reports.append((number, presented)) }
    }

    /// The presentations reported since the last call.
    func take() -> [(drawable: Int, presented: CFTimeInterval)] {
        lock.withLock { defer { reports = [] }; return reports }
    }
}
#endif
