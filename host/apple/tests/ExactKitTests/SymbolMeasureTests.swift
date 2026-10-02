import XCTest
@testable import ExactKit

/// A system symbol's box is measured in layout (LLP 1035.004.000): the
/// kernel's callback answers the glyph's own size, the em square for a name
/// the OS lacks, and nothing at a point size of 0 — what the view reports
/// when it draws, so the first layout is the one that stays.
final class SymbolMeasureTests: XCTestCase {
    private func measure(_ name: String, _ points: Float, _ weight: UInt16) -> CGSize? {
        var out: [Float] = [0, 0]
        let bytes = Array(name.utf8)
        let ok = bytes.withUnsafeBufferPointer { b in
            out.withUnsafeMutableBufferPointer { o in SymbolMeasure.measure(nil, b.baseAddress, b.count, points, weight, o.baseAddress) }
        }
        return ok == 1 ? CGSize(width: CGFloat(out[0]), height: CGFloat(out[1])) : nil
    }

    func testAGlyphIsMeasuredAtItsSizeAndWeight() throws {
        let size = try XCTUnwrap(measure("envelope", 17, 600))
        let glyph = try XCTUnwrap(SymbolMeasure.image("envelope", points: 17, weight: 600))
        XCTAssertEqual(size, glyph.size, "the callback and the view agree")
        XCTAssertGreaterThan(size.width, size.height, "an envelope is wider than tall, not an em square")
        let bigger = try XCTUnwrap(measure("envelope", 34, 600))
        XCTAssertGreaterThan(bigger.width, size.width)
    }

    func testAMissingNameIsAnEmSquareAndZeroPointsIsNothing() {
        XCTAssertEqual(measure("no.such.symbol.exact", 17, 400), CGSize(width: 17, height: 17))
        XCTAssertEqual(measure("", 12, 400), CGSize(width: 12, height: 12))
        XCTAssertNil(measure("envelope", 0, 400))
    }
}
