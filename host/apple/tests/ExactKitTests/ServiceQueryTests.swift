import XCTest
@testable import ExactKit

final class ServiceQueryTests: XCTestCase {
    func testQueriesHandleAnAbsentServiceAndShareADeclaredLoad() {
        let absent = expectation(description: "an undeclared service answers nil")
        absent.assertForOverFulfill = true
        ExactServices.query("no-such-service", [:]) { XCTAssertNil($0); absent.fulfill() }
        wait(for: [absent], timeout: 5)

        let module = "service-query-missing-\(UUID().uuidString)"
        var loads = 0
        let answered = expectation(description: "every query answers after loading")
        answered.expectedFulfillmentCount = 3
        answered.assertForOverFulfill = true
        for _ in 0..<3 {
            ExactServices.query(module, [:]) {
                XCTAssertNil($0)
                XCTAssertEqual(loads, 1, "the load finishes before a query answers")
                answered.fulfill()
            }
        }
        // Queue the reads before declaration can schedule an automatic load
        ExactLaunch.shared.requestService(module: module, when: .afterStartup, config: [:]) {
            loads += 1
            return Data()
        }
        wait(for: [answered], timeout: 5)
        let again = expectation(description: "failure answers without loading again")
        again.assertForOverFulfill = true
        ExactServices.query(module, [:]) { XCTAssertNil($0); again.fulfill() }
        wait(for: [again], timeout: 5)
        XCTAssertEqual(loads, 1)
    }
}
