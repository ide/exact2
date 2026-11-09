import XCTest
@testable import ExactKit

final class TextRenderMetricsTests: XCTestCase {
    func testOldWorkersCannotContaminateANewCapture() throws {
        let metrics = TextRenderMetrics(capacity: 4, clock: { 10 })
        XCTAssertNil(metrics.begin())
        metrics.start()
        let old = metrics.begin()
        metrics.stop()
        metrics.start()
        metrics.end(old, kind: .preparePixels)
        metrics.end(metrics.begin(), kind: .coveragePaint, node: 7)
        metrics.stop()
        let snapshot = metrics.snapshot(origin: 10)
        XCTAssertEqual(snapshot["written"] as? Int, 1)
        let rows = try XCTUnwrap(snapshot["rows"] as? [[Any]])
        XCTAssertEqual(rows.first?[3] as? UInt32, 7)
    }

    func testOverwritesAreReportedAndNewestSpansStayOrdered() throws {
        let metrics = TextRenderMetrics(capacity: 2, clock: { 10 })
        metrics.start()
        for node in 1...4 { metrics.end(metrics.begin(), kind: .publishPixels, node: UInt32(node), bytes: node * 100) }
        metrics.stop()
        let snapshot = metrics.snapshot(origin: 10)
        XCTAssertEqual(snapshot["written"] as? Int, 4)
        XCTAssertEqual(snapshot["overwritten"] as? Int, 2)
        let rows = try XCTUnwrap(snapshot["rows"] as? [[Any]])
        XCTAssertEqual(rows.compactMap { $0[3] as? UInt32 }, [3, 4])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: snapshot))
    }

    func testFinishingAfterStopDoesNotModifyTheFrozenCapture() {
        let metrics = TextRenderMetrics(capacity: 2, clock: { 10 })
        metrics.start()
        let pending = metrics.begin()
        metrics.stop()
        metrics.end(pending, kind: .preparePixels)
        XCTAssertEqual(metrics.snapshot(origin: 10)["written"] as? Int, 0)
    }

    func testConcurrentWorkersKeepEverySpanWithoutHoldingTheLockDuringWork() throws {
        let metrics = TextRenderMetrics(capacity: 100, clock: { 10 })
        metrics.start()
        DispatchQueue.concurrentPerform(iterations: 100) { node in
            let stamp = metrics.begin()
            metrics.end(stamp, kind: .preparePixels, node: UInt32(node))
        }
        metrics.stop()
        let snapshot = metrics.snapshot(origin: 10)
        let rows = try XCTUnwrap(snapshot["rows"] as? [[Any]])
        XCTAssertEqual(Set(rows.compactMap { $0[3] as? UInt32 }).count, 100)
        XCTAssertEqual(snapshot["overwritten"] as? Int, 0)
    }
}
