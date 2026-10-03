#if os(iOS)
import UIKit
import XCTest
@testable import ExactKit

/// One visual state, one commit: a batch that changes a visible paragraph's
/// text or box paints its new pixels as it ends, with the layout it commits,
/// never leaving the old image in the new box for a frame ("Locking" drawn
/// in the box laid out for "Locked").
final class TextBatchPaintIOSTests: XCTestCase {
    private var window: UIWindow!

    private func fixture() throws -> (ExactSession, NodeView) {
        let session = ExactApp.shared.makeSession(label: "batch-paint")
        let p = session.presenter
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        p.viewport.frame = window.bounds
        window.addSubview(p.viewport)
        window.makeKeyAndVisible()
        p.apply(wireBatch([
            ["op": "create", "id": 1, "kind": "view"],
            ["op": "create", "id": 2, "kind": "text", "props": ["text": "Locking"], "style": ["font_size": 15.0]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 400.0, "h": 400.0],
            ["op": "frame", "id": 2, "x": 100.0, "y": 100.0, "w": 60.0, "h": 20.0],
        ]))
        let node = try XCTUnwrap(p.views[2])
        // Its first pixels, settled.
        p.paintVisibleText()
        RegionTextExecutor.queue.waitUntilAllOperationsAreFinished()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(node.textRasterReady)
        return (session, node)
    }

    func testANewTextAndBoxArePaintedWithTheBatchThatLaidThemOut() throws {
        let (session, node) = try fixture()
        defer { session.destroy(); RegionTextExecutor.queue.isSuspended = false }
        let p = session.presenter
        let before = node.textRaster
        // No worker may run: the pixels must come from the batch itself.
        RegionTextExecutor.queue.isSuspended = true
        p.apply(wireBatch([
            ["op": "props", "id": 2, "set": ["text": "Locked"], "clear": []],
            ["op": "frame", "id": 2, "x": 108.0, "y": 100.0, "w": 52.0, "h": 20.0],
        ]))
        XCTAssertTrue(node.textRasterReady, "painted as the batch ended")
        XCTAssertNotNil(node.textRasterKey)
        XCTAssertFalse(node.textRaster === before, "the new words, not the old image")
        XCTAssertEqual(p.textRasters.inFlight, 0, "no worker job was needed")
    }

    func testAParagraphOutOfViewStillWaitsForTheWorker() throws {
        let (session, node) = try fixture()
        defer { session.destroy(); RegionTextExecutor.queue.isSuspended = false }
        let p = session.presenter
        let before = node.textRaster
        RegionTextExecutor.queue.isSuspended = true
        p.apply(wireBatch([
            ["op": "props", "id": 2, "set": ["text": "Locked"], "clear": []],
            ["op": "frame", "id": 2, "x": 100.0, "y": 900.0, "w": 52.0, "h": 20.0],
        ]))
        XCTAssertNil(node.textRasterKey, "still owed: what does not show is not painted on the main thread")
        XCTAssertTrue(node.textRaster === before)
    }
}
#endif
