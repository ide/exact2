// PROTO (UIKit-first measurement; not landing code). The live path's geometry-only batch
// (`design/safe-area-design.md` §6 in the notes): a batch of frames alone, which the layout at a
// moving edge makes, applies its frames and the routes' reach and nothing else. What else a batch
// syncs (controls, accessibility, menus, swipe actions, row cells, popovers' anchors) waits for the
// first frame that brings no such batch, when the edge has stopped.
#if os(iOS) || os(tvOS)
import UIKit

extension Presenter {
    /// Whether `batch` is a moving edge's under `ExactSession.protoMode` `geometry`: frames and
    /// scroll content sizes alone.
    func geometryOnly(_ batch: Batch) -> Bool {
        ExactSession.protoMode == .geometry && !batch.controls && !batch.ops.isEmpty
            && batch.ops.allSatisfy { Self.geometric($0) }
    }

    /// A box's frame, a scroller's content size, a field's text box, or an owner's block rect.
    static func geometric(_ op: BatchOp) -> Bool {
        switch op.op {
        case .frame, .content, .fieldContent: true
        case .unknown: op.payload["op"] as? String == "block"
        default: false
        }
    }

    /// Under the default `ExactProtoVerify`: the full reach walk after a geometry-only batch's own, and how many
    /// native frames it changed and by how much at most, which is 0 when the moving edge's reach was right.
    func verifyMovingTops() {
        guard Self.protoVerify else { return }
        let before = views.mapValues { $0.frame }
        reachSafeEdges()
        var changed = 0, most: CGFloat = 0
        for (id, frame) in before {
            guard let now = views[id]?.frame, now != frame else { continue }
            changed += 1
            most = max(most, abs(now.minX - frame.minX), abs(now.minY - frame.minY), abs(now.width - frame.width), abs(now.height - frame.height))
            if most > 1 { NSLog("PROTO verify view %u %@ %@ → %@", id, views[id]?.props["testId"] ?? views[id]?.kind ?? "?", NSCoder.string(for: frame), NSCoder.string(for: now)) }
        }
        NSLog("PROTO verify changed %d frames, at most %.2f", changed, most)
    }
    static let protoVerify = UserDefaults.standard.bool(forKey: "ExactProtoVerify")

    /// The boxes a geometry-only batch moved, synced once a frame passes with no such batch.
    func deferGeometry(_ ids: [UInt32]) {
        deferredGeometry.formUnion(ids)
        if let quiet = geometryQuiet { quiet.moved = true } else { geometryQuiet = GeometryQuiet(self) }
    }

    /// What the batches of frames left, once the edge has stopped: what `apply` syncs after its
    /// ops, for every box they moved.
    func finishDeferredGeometry() {
        geometryQuiet = nil
        guard !deferredGeometry.isEmpty else { return }
        let changed = touchedAndAbove(Array(deferredGeometry))
        deferredGeometry = []
        swipeActions.sync(changed: changed, reshaped: []); rowCells.sync(changed: changed)
        groupedLists?.sync(changed: changed); reachPageEdges(); reachSafeEdges()
        segments.sync()
        controls.sync(contents: false, changed: changed)
        menus.sync()
        glassGroups.reconcile()
        positionContexts()
        navigation.followAuthoredTablist()
        syncAccessibility(changed: changed)
    }

    /// The root's words for the prototype (Duo Lab's Edges screen): `data-safe-area-mode` picks the
    /// mode, and the routes' covers are reported again under it, which lays them out at their live or
    /// resting top; a new `data-safe-area-run` moves the shown route's top edge as a bar would (`EdgeRun`).
    func applyProtoMode(_ root: NodeView?) {
        let dataset = root?.props["dataset"] ?? ""
        guard dataset != protoDataset else { return }
        protoDataset = dataset
        guard let words = try? JSONSerialization.jsonObject(with: Data(dataset.utf8)) as? [String: Any] else { return }
        if let word = words["safe-area-mode"] as? String, let mode = ExactSession.ProtoMode(rawValue: word), mode != ExactSession.protoMode {
            ExactSession.protoMode = mode
            // Frames kept for placing between rest and the far edge are stale once the live layout moves the boxes
            if mode != .resting { edgeFrames = [:]; for c in navigation.controllers.values { c.placedEdge = nil } }
            NSLog("PROTO mode %@", mode.rawValue)
            afterBatch { [weak self] in self?.navigation.reportCovers() }
        }
        let run = words["safe-area-run"] as? String ?? ""
        if run != protoRun {
            let first = protoRun.isEmpty
            protoRun = run
            guard !first, let route = navigation.controllers.values.first(where: {
                $0.viewIfLoaded?.window != nil && $0.navigationController?.topViewController === $0
            }) else { return }
            edgeRun = EdgeRun(route) { [weak self] in self?.edgeRun = nil }
        }
    }
}

/// Moves a route's top edge as a collapsing and minimizing bar does, frame by frame, through the
/// route's `additionalSafeAreaInsets.top`: from 106 points to 0 and back over a second each, twice.
/// UIKit changes the safe area and calls `viewSafeAreaInsetsDidChange` on every frame, as for a bar;
/// a programmatic scroll does not collapse a large title, and a drag cannot keep a schedule on a
/// loaded machine. The run holds the edge 106 points low for half a second first, and in the resting
/// mode that held inset is the resting top's (`heldTop`), so the sweep moves the edge up from its
/// resting place as a collapsing title does. Its start and end are logged for cutting the log.
final class EdgeRun: NSObject {
    /// The inset the resting top counts while a run in the resting mode holds the edge low.
    nonisolated(unsafe) static var heldTop: CGFloat = 0
    private weak var route: UIViewController?
    private let done: () -> Void
    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private static let hold: CFTimeInterval = 0.5, leg: CFTimeInterval = 1, travel: CGFloat = 106
    private static let legs: [CGFloat] = [0, travel, 0, travel]

    init(_ route: UIViewController, done: @escaping () -> Void) {
        self.route = route
        self.done = done
        super.init()
        NSLog("PROTO run start %@", ExactSession.protoMode.rawValue)
        if ExactSession.protoMode == .resting { Self.heldTop = Self.travel }
        route.additionalSafeAreaInsets.top = Self.travel
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let route else { return finish() }
        if started == 0 { started = link.timestamp }
        let t = link.timestamp - started - Self.hold
        guard t >= 0 else { return }
        let index = Int(t / Self.leg)
        guard index < Self.legs.count else { return finish() }
        let from = index == 0 ? Self.travel : Self.legs[index - 1], to = Self.legs[index]
        let f = CGFloat((t - Double(index) * Self.leg) / Self.leg), eased = f * f * (3 - 2 * f)
        route.additionalSafeAreaInsets.top = from + (to - from) * eased
    }

    private func finish() {
        link?.invalidate()
        link = nil
        Self.heldTop = 0
        route?.additionalSafeAreaInsets.top = 0
        NSLog("PROTO run end %@", ExactSession.protoMode.rawValue)
        done()
    }
}

/// Ticks each frame until one passes with no geometry-only batch (`Presenter.deferGeometry`).
final class GeometryQuiet: NSObject {
    weak var presenter: Presenter?
    /// A geometry-only batch arrived since the last tick.
    var moved = false
    private var link: CADisplayLink?

    init(_ presenter: Presenter) {
        self.presenter = presenter
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        if moved { moved = false; return }
        link?.invalidate()
        link = nil
        presenter?.finishDeferredGeometry()
    }
}
#endif
