#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// The shape UIKit lifts a context menu's node in (`ContextMenuHost.targeted`)
/// when the node paints no ground of its own: the grounds the nodes inside it
/// paint, where their boxes and clips let them paint, as a chat balloon's
/// body and tail, so long as every box of text and every flat box lies on
/// them whole; a line that runs past them, a flat box beside them, or
/// grounds with no area, lift the whole box.
final class ContextLiftShapeIOSTests: XCTestCase {
    private var window: UIWindow!
    private var session: ExactSession?

    override func tearDown() { session?.destroy(); session = nil; window?.isHidden = true; super.tearDown() }

    /// A balloon at (100, 100), 120 by 40: a body clipped to a rectangle and
    /// a tail clipped to a triangle 8 points below it, both blue, and its
    /// text. `textAt` moves the text's frame.
    private func balloon(textAt text: CGRect = CGRect(x: 14, y: 8, width: 92, height: 24), grounds: CGSize = CGSize(width: 120, height: 48)) throws -> Presenter {
        let session = ExactApp.shared.makeSession(label: "lift-shape")
        self.session = session
        let p = session.presenter
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        let blue: [Double] = [0, 136, 255, 255]
        let body: [String: Any] = ["commands": [["M", [0, 0]], ["L", [120, 0]], ["L", [120, 40]], ["L", [0, 40]], ["Z", []]]]
        let tail: [String: Any] = ["commands": [["M", [104, 40]], ["L", [120, 40]], ["L", [120, 48]], ["Z", []]]]
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view"],
            ["op": "create", "id": 2, "kind": "view", "props": ["contextPopover": "message-menu"], "handlers": ["contextmenu"]],
            ["op": "create", "id": 3, "kind": "view", "style": ["background_color": blue, "clip_path": tail]],
            ["op": "create", "id": 4, "kind": "view", "style": ["background_color": blue, "clip_path": body]],
            ["op": "create", "id": 5, "kind": "text", "style": ["font_size": 17.0]],
            ["op": "create", "id": 6, "kind": "view", "props": ["popover": "auto", "id": "message-menu"]],
            ["op": "create", "id": 7, "kind": "button", "handlers": ["press"]],
            ["op": "children", "id": 6, "ids": [7]],
            ["op": "children", "id": 2, "ids": [3, 4, 5]],
            ["op": "children", "id": 1, "ids": [2, 6]], ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0, "y": 0, "w": 400, "h": 800],
            ["op": "frame", "id": 2, "x": 100, "y": 100, "w": 120, "h": 40],
            ["op": "frame", "id": 3, "x": 0, "y": 0, "w": grounds.width, "h": grounds.height],
            ["op": "frame", "id": 4, "x": 0, "y": 0, "w": grounds.width, "h": grounds.height],
            ["op": "frame", "id": 5, "x": text.minX, "y": text.minY, "w": text.width, "h": text.height],
        ]))
        p.buttonFace = { _ in var face = ButtonFace(); face.title = "Copy"; return face }
        p.menus.context.sync()
        return p
    }

    /// Box 8, a flat leaf in the balloon's own layer (`FlatLeaves`), as a
    /// badge or a strip drawn beside or on a balloon.
    private func flatBox(_ p: Presenter, at frame: CGRect, style extra: [String: Any] = [:]) throws {
        p.apply(wireBatch([
            ["op": "create", "id": 8, "kind": "view", "style": extra.merging(["background_color": [255, 0, 0, 255]]) { a, _ in a }],
            ["op": "frame", "id": 8, "x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height],
            ["op": "children", "id": 2, "ids": [3, 4, 5, 8]],
        ]))
        XCTAssertNil(p.views[8], "box 8 is drawn flat, not as a view")
        XCTAssertEqual(p.flats.frameInHost(8), frame)
        XCTAssertTrue(p.flats.inspectionLayers(under: 2).contains { $0.leaves.contains(8) && $0.layer.superlayer != nil }, "in a layer of the balloon's")
    }

    /// The path's bounds, edge by edge, to a thousandth of a point: Core
    /// Graphics' boolean operations (`CGPath.union`, `intersection`) give
    /// their points back about 1e-7 pt from the exact ones (a 48 pt edge at
    /// 47.999999909711306), and a thousandth of a point is under a hundredth
    /// of a pixel at 3x, so no shape a person could tell apart passes.
    private func assertBounds(_ path: UIBezierPath, _ expected: CGRect, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let b = path.bounds
        for (got, want, edge) in [(b.minX, expected.minX, "left"), (b.minY, expected.minY, "top"), (b.maxX, expected.maxX, "right"), (b.maxY, expected.maxY, "bottom")] {
            XCTAssertEqual(got, want, accuracy: 0.001, "\(message): its \(edge)", file: file, line: line)
        }
    }

    private func lifted(_ p: Presenter) throws -> UITargetedPreview {
        let node = try XCTUnwrap(p.views[2])
        let interaction = try XCTUnwrap(node.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
        let host = p.menus.context
        let config = try XCTUnwrap(host.contextMenuInteraction(interaction, configurationForMenuAtLocation: CGPoint(x: 60, y: 20)))
        return try XCTUnwrap(host.contextMenuInteraction(interaction, configuration: config, highlightPreviewForItemWithIdentifier: config.identifier))
    }

    func testABalloonLiftsInItsBodyAndItsTail() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        let path = try XCTUnwrap(try lifted(p).parameters.visiblePath)
        assertBounds(path, CGRect(x: 0, y: 0, width: 120, height: 48), "the body and the tail below it")
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 20)), "the body")
        XCTAssertTrue(path.contains(CGPoint(x: 118, y: 44)), "the tail")
        XCTAssertFalse(path.contains(CGPoint(x: 4, y: 44)), "beside the tail, under the body")
    }

    func testANodeWhoseTextLiesOffItsGroundsLiftsWhole() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        // The text beside the shapes, as a name beside an avatar
        let p = try balloon(textAt: CGRect(x: 14, y: 60, width: 92, height: 24))
        defer { p.menus.reset() }
        XCTAssertNil(try lifted(p).parameters.visiblePath)
    }

    /// A line whose middle is on the body but whose box runs past it: its ink
    /// would be cut by the balloon's shape, so the whole box lifts, as before.
    func testANodeWhoseTextRunsPastItsGroundsLiftsWholeThoughItsCentreIsOnThem() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon(textAt: CGRect(x: 60, y: 8, width: 92, height: 24))
        defer { p.menus.reset() }
        let text = try XCTUnwrap(p.views[5]), balloon = try XCTUnwrap(p.views[2])
        let centre = balloon.convert(CGPoint(x: text.bounds.midX, y: text.bounds.midY), from: text)
        XCTAssertTrue(balloon.bounds.contains(centre) && centre.x < 120, "its centre is over the body")
        XCTAssertGreaterThan(balloon.convert(text.bounds, from: text).maxX, 120, "and its box runs past it")
        XCTAssertNil(try lifted(p).parameters.visiblePath, "no ink is cut: the whole box lifts")
    }

    /// Grounds declared with no area (a body and a tail laid out to nothing)
    /// are no grounds: the box lifts whole, as before, with no path.
    func testANodeWhoseDeclaredGroundsHaveNoAreaLiftsWhole() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon(textAt: .zero, grounds: .zero)
        defer { p.menus.reset() }
        for id: UInt32 in [3, 4] { XCTAssertTrue(try XCTUnwrap(p.views[id]).bounds.isEmpty, "ground \(id) has no area") }
        XCTAssertNil(try lifted(p).parameters.visiblePath)
    }

    /// A clip path paints only within its box: a tail laid out no taller
    /// than the body, its triangle below that box, paints nothing there.
    func testAGroundPaintsOnlyWithinItsBoxThoughItsClipRunsPast() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon(grounds: CGSize(width: 120, height: 40))
        defer { p.menus.reset() }
        let path = try XCTUnwrap(try lifted(p).parameters.visiblePath)
        assertBounds(path, CGRect(x: 0, y: 0, width: 120, height: 40), "the body alone")
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 20)), "the body")
        XCTAssertFalse(path.contains(CGPoint(x: 118, y: 44)), "the tail's clip, past its box")
    }

    /// A balloon that clips its overflow shows no tail below its box, and
    /// lifts without one.
    func testABalloonThatClipsLiftsOnlyTheGroundsItShows() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        p.apply(wireBatch([["op": "style", "id": 2, "style": ["overflow_x": "hidden", "overflow_y": "hidden"]]]))
        XCTAssertTrue(try XCTUnwrap(p.views[2]).clipsToBounds, "the balloon clips")
        let path = try XCTUnwrap(try lifted(p).parameters.visiblePath)
        assertBounds(path, CGRect(x: 0, y: 0, width: 120, height: 40), "the body, to the balloon's box")
        XCTAssertFalse(path.contains(CGPoint(x: 118, y: 44)), "the tail, clipped away")
    }

    /// A balloon that both clips its overflow and has a clip path clips what
    /// it holds to both (`BoxMaskIOS.clipMask`): its clip path reaches the
    /// tail, its box does not, so the tail does not show and does not lift.
    func testABalloonClippedByItsBoxAndItsClipPathLiftsInBoth() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        let whole: [String: Any] = ["commands": [["M", [0, 0]], ["L", [120, 0]], ["L", [120, 48]], ["L", [0, 48]], ["Z", []]]]
        p.apply(wireBatch([["op": "style", "id": 2, "style": ["overflow_x": "hidden", "overflow_y": "hidden", "clip_path": whole]]]))
        let root = try XCTUnwrap(p.views[2])
        XCTAssertTrue(root.clipsToBounds && root.clipPath != nil, "the balloon has both clips")
        let path = try XCTUnwrap(try lifted(p).parameters.visiblePath)
        assertBounds(path, CGRect(x: 0, y: 0, width: 120, height: 40), "the body, to the balloon's box")
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 20)), "the body")
        XCTAssertFalse(path.contains(CGPoint(x: 118, y: 44)), "the tail, inside the clip path but outside the box")
    }

    /// A gradient mask over a clip path is no region: the grounds under it
    /// fade where it fades, so the whole box lifts.
    func testABalloonMaskedByAGradientOverItsClipPathLiftsWhole() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        let whole: [String: Any] = ["commands": [["M", [0, 0]], ["L", [120, 0]], ["L", [120, 48]], ["L", [0, 48]], ["Z", []]]]
        let fade: [String: Any] = ["linear": 180, "stops": [0, 0, 0, 0, 255, 1, 0, 0, 0, 0]]
        p.apply(wireBatch([["op": "style", "id": 2, "style": ["clip_path": whole, "mask_image": fade]]]))
        let root = try XCTUnwrap(p.views[2])
        XCTAssertTrue(root.clipPath != nil && root.style["mask_image"] != nil, "a clip path and a mask image")
        XCTAssertNil(try lifted(p).parameters.visiblePath)
    }

    /// A flat box beside the grounds, in the balloon's box, is ink a shape
    /// of the grounds would cut: the whole box lifts.
    func testAFlatBoxBesideTheGroundsLiftsWhole() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        p.apply(wireBatch([["op": "frame", "id": 2, "x": 100, "y": 100, "w": 120, "h": 80]]))
        try flatBox(p, at: CGRect(x: 20, y: 60, width: 20, height: 12))
        XCTAssertNil(try lifted(p).parameters.visiblePath, "no flat box's ink is cut")
    }

    /// A flat box on the grounds is ink they hold: their shape lifts.
    func testAFlatBoxOnTheGroundsKeepsTheirShape() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        try flatBox(p, at: CGRect(x: 20, y: 10, width: 20, height: 12))
        let path = try XCTUnwrap(try lifted(p).parameters.visiblePath)
        assertBounds(path, CGRect(x: 0, y: 0, width: 120, height: 48), "the body and the tail")
        XCTAssertTrue(path.contains(CGPoint(x: 118, y: 44)), "the tail")
        XCTAssertFalse(path.contains(CGPoint(x: 4, y: 44)), "beside the tail")
    }

    /// A flat box on the grounds that casts a shadow, whose ink reaches
    /// past its box, lifts the whole box.
    func testAFlatBoxCastingAShadowLiftsWhole() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        try flatBox(p, at: CGRect(x: 20, y: 10, width: 20, height: 12), style: ["box_shadow": [["o": [0.0, 2.0], "b": 4.0, "s": 0.0, "c": [0, 0, 0, 255]]]])
        XCTAssertNil(try lifted(p).parameters.visiblePath, "its shadow is not cut")
    }

    /// A box inside the balloon whose outer shadow reaches past the grounds,
    /// as a line of text with a shadow below it, in a balloon whose box holds
    /// that shadow: the whole box lifts, so no ink of the shadow is cut.
    func testANodeCastingAShadowPastTheGroundsLiftsWhole() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        p.apply(wireBatch([
            ["op": "frame", "id": 2, "x": 100, "y": 100, "w": 120, "h": 80],
            ["op": "style", "id": 5, "style": ["font_size": 17.0, "box_shadow": [["o": [0.0, 14.0], "b": 4.0, "s": 0.0, "c": [0, 0, 0, 255]]]]],
        ]))
        let text = try XCTUnwrap(p.views[5]), balloon = try XCTUnwrap(p.views[2])
        // The caster is put on at the layer's display (`NodeLayer.display`,
        // `applyBoxLayer`, `applyShadow`), which a style op only asks for
        text.layer.displayIfNeeded()
        let caster = try XCTUnwrap(text.shadowCaster, "the text casts an outer shadow")
        XCTAssertTrue(caster.superlayer === text.layer, "cast from its own layer")
        let box = balloon.convert(text.bounds, from: text), shadow = text.shadowGeometry
        let cast = box.offsetBy(dx: shadow.x, dy: shadow.y).insetBy(dx: -shadow.blur, dy: -shadow.blur)
        XCTAssertLessThanOrEqual(box.maxY, 40, "the text itself lies on the body")
        XCTAssertGreaterThan(cast.maxY, 48, "its shadow falls below the grounds")
        XCTAssertTrue(balloon.bounds.contains(cast), "and inside the balloon's box")
        XCTAssertNil(try lifted(p).parameters.visiblePath, "its shadow is not cut")
    }

    /// A tail crossing the body's rounded corner, as the native balloon
    /// fixture draws it: the lift's edge is the authored edge, so a point on
    /// the body's curve is in the lift exactly when it is in the body's clip.
    /// (4.5, 59.5) is on the lower-left corner, at its middle; the union's
    /// boolean cut moved that corner's point 1e-8 pt and lost it.
    func testALiftKeepsTheAuthoredEdgeWhereATailCrossesTheBody() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        // The body's clip as the compiled fixture carries it: each corner's `Q` raised to its exact cubic
        let body: [String: Any] = ["commands": [["M", [18, 0]], ["L", [202, 0]], ["C", [214, 0, 220, 6, 220, 18]], ["L", [220, 46]], ["C", [220, 58, 214, 64, 202, 64]],
                                                ["L", [18, 64]], ["C", [6, 64, 0, 58, 0, 46]], ["L", [0, 18]], ["C", [0, 6, 6, 0, 18, 0]], ["Z", []]]]
        let tail: [String: Any] = ["commands": [["M", [196, 60]], ["L", [220, 58]], ["L", [220, 80]], ["Z", []]]]
        let blue: [Double] = [0, 136, 255, 255]
        p.apply(wireBatch([
            ["op": "style", "id": 4, "style": ["background_color": blue, "clip_path": body]],
            ["op": "style", "id": 3, "style": ["background_color": blue, "clip_path": tail]],
            ["op": "frame", "id": 2, "x": 40, "y": 100, "w": 300, "h": 84],
            ["op": "frame", "id": 4, "x": 0, "y": 0, "w": 220, "h": 64],
            ["op": "frame", "id": 3, "x": 0, "y": 0, "w": 220, "h": 80],
            ["op": "frame", "id": 5, "x": 14, "y": 18, "w": 185, "h": 30],
        ]))
        let edge = CGPoint(x: 4.5, y: 59.5)
        XCTAssertTrue(try XCTUnwrap(try XCTUnwrap(p.views[4]).clipPath).contains(edge), "the point is the body's, by its own clip")
        let path = try XCTUnwrap(try lifted(p).parameters.visiblePath)
        XCTAssertTrue(path.contains(edge), "and the lift's")
        XCTAssertTrue(path.contains(CGPoint(x: 219, y: 79)), "the tail's tip")
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 63)), "outside the corner's curve")
        assertBounds(path, CGRect(x: 0, y: 0, width: 220, height: 80), "the body and the tail")
    }

    /// A tail traced the other way round fills the same: each outline is
    /// normalized before it joins the others.
    func testATailTracedTheOtherWayStillLifts() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        let tail: [String: Any] = ["commands": [["M", [120, 48]], ["L", [120, 40]], ["L", [104, 40]], ["Z", []]]]
        p.apply(wireBatch([["op": "style", "id": 3, "style": ["background_color": [0, 136, 255, 255], "clip_path": tail]]]))
        let path = try XCTUnwrap(try lifted(p).parameters.visiblePath)
        assertBounds(path, CGRect(x: 0, y: 0, width: 120, height: 48), "the body and the tail")
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 20)), "the body")
        XCTAssertTrue(path.contains(CGPoint(x: 118, y: 44)), "the tail")
        XCTAssertFalse(path.contains(CGPoint(x: 4, y: 44)), "beside the tail")
    }

    /// A mirrored tail (its view's transform, as the host sets it) lifts
    /// where it shows.
    func testAMirroredTailLiftsWhereItShows() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        try XCTUnwrap(p.views[3]).transform = CGAffineTransform(scaleX: -1, y: 1)
        let path = try XCTUnwrap(try lifted(p).parameters.visiblePath)
        XCTAssertTrue(path.contains(CGPoint(x: 2, y: 44)), "the tail, mirrored to the left")
        XCTAssertFalse(path.contains(CGPoint(x: 118, y: 44)), "not where it was")
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 20)), "the body")
    }

    /// An even-odd clip with a hole lifts without the hole.
    func testABodyWithAnEvenOddHoleLiftsWithoutIt() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon(textAt: CGRect(x: 2, y: 12, width: 30, height: 16))
        defer { p.menus.reset() }
        let ring: [String: Any] = ["commands": [["M", [0, 0]], ["L", [120, 0]], ["L", [120, 40]], ["L", [0, 40]], ["Z", []],
                                                ["M", [40, 10]], ["L", [80, 10]], ["L", [80, 30]], ["L", [40, 30]], ["Z", []]], "rule": "evenodd"]
        p.apply(wireBatch([["op": "style", "id": 4, "style": ["background_color": [0, 136, 255, 255], "clip_path": ring]]]))
        XCTAssertEqual(try XCTUnwrap(p.views[4]).clipRule, .evenOdd)
        let path = try XCTUnwrap(try lifted(p).parameters.visiblePath)
        XCTAssertTrue(path.contains(CGPoint(x: 20, y: 20)), "the ring")
        XCTAssertFalse(path.contains(CGPoint(x: 60, y: 20)), "not its hole")
        XCTAssertTrue(path.contains(CGPoint(x: 118, y: 44)), "the tail")
    }

    /// A tail whose clip crosses itself (a bow tie, its lobes wound opposite
    /// ways, both filled under the nonzero rule) lifts in both lobes.
    func testATailWhoseClipCrossesItselfLiftsInBothLobes() throws {
        if ExactEnv.agentPaints { throw XCTSkip("the agent paints the popover (D4)") }
        let p = try balloon()
        defer { p.menus.reset() }
        let bow: [String: Any] = ["commands": [["M", [104, 40]], ["L", [120, 48]], ["L", [120, 40]], ["L", [104, 48]], ["Z", []]]]
        p.apply(wireBatch([["op": "style", "id": 3, "style": ["background_color": [0, 136, 255, 255], "clip_path": bow]]]))
        let path = try XCTUnwrap(try lifted(p).parameters.visiblePath)
        XCTAssertTrue(path.contains(CGPoint(x: 106, y: 44)), "the left lobe")
        XCTAssertTrue(path.contains(CGPoint(x: 118, y: 44)), "the right lobe")
        XCTAssertFalse(path.contains(CGPoint(x: 112, y: 41)), "between them, above the crossing")
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 20)), "the body")
    }
}
#endif
