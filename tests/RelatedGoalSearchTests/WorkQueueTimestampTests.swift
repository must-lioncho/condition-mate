import Testing
import Foundation
@testable import ConditionMate

// 2026-09-07: `import XCTest` 에서 `import Testing` 으로 옮겼다. **판정은 한 줄도 안 바꿨다.**
//
// 이 맥에는 Xcode 가 없고 Command Line Tools 만 있다(`xcode-select -p` →
// `/Library/Developer/CommandLineTools`). 그 툴체인의
// `Library/Developer/Frameworks` 에는 `Testing.framework` 만 있고 `XCTest.framework` 가 **없다.**
// 그래서 이 파일 하나가 `no such module 'XCTest'` 로 죽으면서 **시험 타깃 전체가 컴파일되지
// 않았다** — 같은 타깃의 swift-testing 시험 세 벌(BoredomRotation · ParentSuggest ·
// RelatedGoalSearch)까지 통째로 못 돌았다. 시험이 지는 것이 아니라 시험이 **안 도는** 상태였고,
// 그것은 게이트가 꺼져 있는 것과 같다.
@Suite struct WorkQueueTimestampTests {
    @Test func captureFormatsResolveToSameUTCInstant() {
        for raw in ["2026-09-06T23:00:00+05:30", "2026-09-06T23:00:00+0530",
                    "2026-09-06T17:30:00Z", "2026-09-07T02:30:00+09:00",
                    "2026-09-06-2300", "2026-09-06T23:00:00", "2026-09-06 23:00"] {
            #expect(WorkQueueTimestamp.utc(raw) == "2026-09-06T17:30:00Z", "\(raw)")
        }
    }
    @Test func dateOnlyAndInvalidDoNotInventTime() {
        #expect(WorkQueueTimestamp.utc("2026-09-06") == nil)
        #expect(WorkQueueTimestamp.utc("unknown") == nil)
    }
    @Test func orderingAcrossOffsets() throws {
        let later = try #require(WorkQueueTimestamp.date("2026-09-07T01:00:00+09:00"))
        let earlier = try #require(WorkQueueTimestamp.date("2026-09-06T23:00:00+05:30"))
        #expect(later < earlier)
    }
}
