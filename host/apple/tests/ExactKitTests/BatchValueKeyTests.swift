import XCTest
@testable import ExactKit

/// A cache key's spelling of a style value (`BatchValue.key`): one spelling per
/// value whatever order an object was built in, and different values never
/// share one.
final class BatchValueKeyTests: XCTestCase {
    func testEqualValuesSpellTheSameKey() {
        let a: BatchValue = .object(["sys": .string("label"), "c": .array([.number(0), .number(0), .number(0), .number(255)])])
        var o: [String: BatchValue] = [:]
        o["c"] = .array([.number(0), .number(0), .number(0), .number(255)])
        o["sys"] = .string("label")
        XCTAssertEqual(a.key, BatchValue.object(o).key)
    }

    func testDifferentValuesSpellDifferentKeys() {
        let values: [BatchValue] = [.null, .bool(true), .bool(false), .number(1), .string("1"), .string("true"),
                                    .array([.number(1)]), .array([.string("1")]), .object(["a": .number(1)]), .object(["a": .string("1")])]
        XCTAssertEqual(Set(values.map(\.key)).count, values.count)
    }
}
