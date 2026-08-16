import Testing
import Foundation
@testable import ConditionMate

// 전략8 · 보링 로테이션 deterministic unit tests: epoch math, cohort classification,
// bench selection, and the roster lifecycle (weekly reshuffle, sticky fresh set,
// mid-week newcomer fold-in, restart persistence). No audio, no filesystem scans —
// providers are injected and event logging is disabled.
@Suite struct BoredomRotationTests {

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Settings.shared.displayTimeZone
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal().date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boring-test-\(UUID().uuidString).json")
    }

    @Test func epochIndexes() {
        let c = cal()
        // Anchor Monday 2026-08-03 is day 0 / week 0 / biweek 0.
        #expect(BoredomRotation.daysSinceAnchor(now: date(2026, 8, 3), cal: c) == 0)
        #expect(BoredomRotation.daysSinceAnchor(now: date(2026, 8, 10), cal: c) == 7)
        #expect(BoredomRotation.weekIndex(days: 0) == 0)
        #expect(BoredomRotation.weekIndex(days: 6) == 0)
        #expect(BoredomRotation.weekIndex(days: 7) == 1)      // rotation flips on Mondays
        #expect(BoredomRotation.biweekIndex(days: 13) == 0)
        #expect(BoredomRotation.biweekIndex(days: 14) == 1)   // fresh re-eval every other Monday
        #expect(BoredomRotation.weekIndex(days: -1) == -1)    // negative-safe floor
    }

    @Test func freshness() {
        let now = date(2026, 8, 9)
        // Recently added stays fresh no matter how much it was heard.
        #expect(BoredomRotation.isFresh(addedAt: date(2026, 8, 1), heardSeconds: 99_999, now: now))
        // An old file barely heard is still fresh (under 20 min total).
        #expect(BoredomRotation.isFresh(addedAt: date(2026, 1, 1), heardSeconds: 60, now: now))
        // Old and well-heard → familiar; unknown date falls to the heard rule.
        #expect(!BoredomRotation.isFresh(addedAt: date(2026, 1, 1), heardSeconds: 3 * 3600, now: now))
        #expect(!BoredomRotation.isFresh(addedAt: nil, heardSeconds: 3 * 3600, now: now))
    }

    @Test func benchTopHalf() {
        let fam = [("a", 100.0), ("b", 400.0), ("c", 300.0), ("d", 200.0), ("e", 50.0)]
            .map { (key: $0.0, heard: $0.1) }
        // floor(5 * 0.5) = 2 most-heard benched.
        #expect(BoredomRotation.benchSet(familiar: fam) == ["b", "c"])
        // A cohort of one is never benched (nothing to rotate to).
        #expect(BoredomRotation.benchSet(familiar: [(key: "solo", heard: 999)]).isEmpty)
        // Deterministic tie-break by key.
        let tied = [("x", 100.0), ("y", 100.0)].map { (key: $0.0, heard: $0.1) }
        #expect(BoredomRotation.benchSet(familiar: tied) == ["x"])
    }

    @Test func rosterLifecycle() {
        let url = tempURL()
        let rot = BoredomRotation(fileURL: url)
        rot.logEvents = false
        let old = date(2026, 1, 1)
        var heard: [String: Double] = ["vet-hi.mp3": 10_000, "vet-lo.mp3": 2_000, "new.mp3": 0]
        var tracks = [
            BoredomRotation.TrackInfo(key: "vet-hi.mp3", addedAt: old),
            BoredomRotation.TrackInfo(key: "vet-lo.mp3", addedAt: old),
            BoredomRotation.TrackInfo(key: "new.mp3", addedAt: date(2026, 8, 1)),
        ]
        rot.tracksProvider = { tracks }
        rot.heardSecondsProvider = { heard }

        // Week 0: the most-heard veteran is benched, the fresh track is protected.
        rot.refreshIfNeeded(now: date(2026, 8, 4))
        #expect(rot.isFresh(key: "new.mp3"))
        #expect(rot.isBenched(key: "vet-hi.mp3"))
        #expect(!rot.isBenched(key: "vet-lo.mp3"))
        #expect(rot.penalty(key: "new.mp3") == 0)
        #expect(rot.penalty(key: "vet-lo.mp3") == BoredomRotation.familiarBias)
        #expect(rot.penalty(key: "vet-hi.mp3") == BoredomRotation.benchedPenalty)

        // Same week: a newcomer folds in as fresh without reshuffling the bench.
        tracks.append(BoredomRotation.TrackInfo(key: "drop.mp3", addedAt: date(2026, 8, 4)))
        rot.refreshIfNeeded(now: date(2026, 8, 5))
        #expect(rot.isFresh(key: "drop.mp3"))
        #expect(rot.isBenched(key: "vet-hi.mp3"))

        // Week 1: the active veteran accrued time meanwhile, so the bench swaps —
        // the self-balancing rotation. Fresh membership stays sticky (same biweek).
        heard["vet-lo.mp3"] = 20_000
        rot.refreshIfNeeded(now: date(2026, 8, 11))
        #expect(rot.isBenched(key: "vet-lo.mp3"))
        #expect(!rot.isBenched(key: "vet-hi.mp3"))
        #expect(rot.isFresh(key: "new.mp3"))

        // Restart mid-week: the persisted roster is restored, no reshuffle.
        let rot2 = BoredomRotation(fileURL: url)
        rot2.logEvents = false
        #expect(rot2.isBenched(key: "vet-lo.mp3"))
        #expect(rot2.isFresh(key: "new.mp3"))
        try? FileManager.default.removeItem(at: url)
    }
}
