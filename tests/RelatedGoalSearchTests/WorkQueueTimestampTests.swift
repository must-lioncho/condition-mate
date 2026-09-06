import XCTest
@testable import ConditionMate

final class WorkQueueTimestampTests: XCTestCase {
    func testCaptureFormatsResolveToSameUTCInstant() {
        for raw in ["2026-09-06T23:00:00+05:30", "2026-09-06T23:00:00+0530",
                    "2026-09-06T17:30:00Z", "2026-09-07T02:30:00+09:00",
                    "2026-09-06-2300", "2026-09-06T23:00:00", "2026-09-06 23:00"] {
            XCTAssertEqual(WorkQueueTimestamp.utc(raw), "2026-09-06T17:30:00Z", raw)
        }
    }
    func testDateOnlyAndInvalidDoNotInventTime() {
        XCTAssertNil(WorkQueueTimestamp.utc("2026-09-06"))
        XCTAssertNil(WorkQueueTimestamp.utc("unknown"))
    }
    func testOrderingAcrossOffsets() {
        XCTAssertLessThan(WorkQueueTimestamp.date("2026-09-07T01:00:00+09:00")!,
                          WorkQueueTimestamp.date("2026-09-06T23:00:00+05:30")!)
    }
}
