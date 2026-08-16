import Testing
import Foundation
@testable import ConditionMate

// DASH-9 regression tests for the AI 큐 "연관성 찾기" content-substance cascade.
// Deterministic ONLY: none of these invoke `claude -p`. They exercise the pure retrieval,
// substance, reference-parsing, prompt-assembly, and post-merge reconciliation logic.
// Uses swift-testing (XCTest is unavailable under the selected CommandLineTools toolchain).
//
// Two regression anchors:
//   A) "…NSS 일일리포트 공유 (240 …루틴)" — a recurring EXECUTION whose work lives in #240,
//      but whose verbatim title echo points at the HOLLOW #291. Must rebind to #240 as a task.
//   B) goal-507-style improvement — a distinct SUB-PROBLEM in the #240 NSS-report family
//      (solving report sharing via external login). Must become a SUB-GOAL under #240 with a
//      managed report-sharing next-step note.
@Suite final class RelatedGoalSearchTests {

    let root: URL
    let t365: URL
    let t462: URL

    // Anchor A routine (the failing case from the investigation).
    let routine = "NSS 주정산 증가분 증명 → 카톡 커뮤니티 공유 → 최대표님께 입금 요청 → 11시 주정산 입금 → 입금 후 NSS 일일리포트 공유 (240 주정산지급 루틴)"
    let existing: Set<Int> = [240, 291, 365, 462]

    init() throws {
        let fm = FileManager.default
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cm-rgs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // goal-240: saturated artifact folder (the goal that actually owns the work).
        let g240 = root.appendingPathComponent("goal-240", isDirectory: true)
        try fm.createDirectory(at: g240, withIntermediateDirectories: true)
        let md = Array(repeating: "nss 주정산 입금 리포트 nss 주정산 입금 공유", count: 40).joined(separator: "\n")
        try md.write(to: g240.appendingPathComponent("goal-detail.md"), atomically: true, encoding: .utf8)

        // goal-291: empty folder, no transcript → HOLLOW (title echo only).
        try fm.createDirectory(at: root.appendingPathComponent("goal-291", isDirectory: true),
                               withIntermediateDirectories: true)

        // Stub transcripts for two UNRELATED but transcript-dense goals (365/462): these must not
        // crowd the artifact owner out of the candidate set on raw count.
        let tdir = root.appendingPathComponent("_transcripts", isDirectory: true)
        try fm.createDirectory(at: tdir, withIntermediateDirectories: true)
        let dense = Array(repeating: "nss 주정산 입금", count: 220).joined(separator: " ")
        t365 = tdir.appendingPathComponent("s365.jsonl"); try dense.write(to: t365, atomically: true, encoding: .utf8)
        t462 = tdir.appendingPathComponent("s462.jsonl"); try dense.write(to: t462, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func goalRefs() -> [RelatedGoalSearch.GoalRef] {
        [ .init(seq: 240, title: "NSS 일일 리포트 온체인 데이터 리포트", transcriptPath: ""),
          .init(seq: 291, title: "주정산지급", transcriptPath: ""),
          .init(seq: 365, title: "무관 세션 A", transcriptPath: t365.path),
          .init(seq: 462, title: "무관 세션 B", transcriptPath: t462.path) ]
    }

    // 1. Keyword mining includes nss/주정산/입금 and is NOT truncated before "일일리포트".
    @Test func keywordMiningKeepsTail() {
        let kws = RelatedGoalSearch.signals(from: routine).keywords
        #expect(kws.contains("nss"), "nss missing: \(kws)")
        #expect(kws.contains("주정산"), "주정산 missing: \(kws)")
        #expect(kws.contains("입금"), "입금 missing: \(kws)")
        #expect(kws.contains("일일리포트"), "tail keyword truncated: \(kws)")
    }

    // Glued mixed-script token splits into recoverable pieces.
    @Test func gluedTokenSplits() {
        let kws = RelatedGoalSearch.signals(from: "NSS일일리포트 자동화").keywords
        #expect(kws.contains("nss"), "\(kws)")
        #expect(kws.contains("일일리포트"), "\(kws)")
    }

    // 2. discover(...) returns #240 in the candidate set (artifact-owner reserved slot).
    @Test func discoverSurfaces240() {
        let hits = RelatedGoalSearch.discover(signals: RelatedGoalSearch.signals(from: routine),
                                              goals: goalRefs(), issueRoot: root)
        #expect(hits.contains { $0.seq == 240 }, "artifact owner #240 not retrieved: \(hits.map { $0.seq })")
    }

    // 3. #291 is flagged hollow; content-substantive goals are not.
    @Test func hollowFlagging() {
        let hollow = RelatedGoalSearch.hollowSeqs(goals: goalRefs(), issueRoot: root)
        #expect(hollow.contains(291), "empty #291 should be hollow")
        #expect(!hollow.contains(240), "#240 has folder content")
        #expect(!hollow.contains(365), "#365 has a transcript")
    }

    // 4. referencedSeqs returns [240]; unit-adjacent numbers (11시 / 7월4일) contribute none.
    @Test func referencedSeqs() {
        #expect(RelatedGoalSearch.referencedSeqs(from: routine, existing: existing) == [240])
        #expect(RelatedGoalSearch.referencedSeqs(from: "11시 회의, 7월4일 마감, 30% 달성",
                                                 existing: [11, 7, 4, 30, 240]) == [])
    }

    // 5. Constructed judge prompt: contains a #240 evidence line and marks #291 hollow.
    @Test func judgePromptEvidence() {
        let hits = RelatedGoalSearch.discover(signals: RelatedGoalSearch.signals(from: routine),
                                              goals: goalRefs(), issueRoot: root)
        let referenced = RelatedGoalSearch.referencedSeqs(from: routine, existing: existing)
        let hollow = RelatedGoalSearch.hollowSeqs(goals: goalRefs(), issueRoot: root)
        let infos = goalRefs().map { RelatedGoalSearch.GoalInfo(seq: $0.seq, title: $0.title, status: "active") }
        let ev = RelatedGoalSearch.judgeEvidence(goals: infos, hits: hits, referenced: referenced, hollow: hollow)
        #expect(ev.evidenceBlock.contains("#240"), "evidence missing #240:\n\(ev.evidenceBlock)")
        #expect(ev.existingList.contains("#291"), "\(ev.existingList)")
        #expect(ev.existingList.contains("껍데기"), "hollow tag missing:\n\(ev.existingList)")
    }

    // Anchor A: LLM wrongly picked hollow #291 as the recurring parent → rebind to #240 as a task.
    @Test func reconcileRecurringRebindsTo240() {
        let hits = RelatedGoalSearch.discover(signals: RelatedGoalSearch.signals(from: routine),
                                              goals: goalRefs(), issueRoot: root)
        let hollow = RelatedGoalSearch.hollowSeqs(goals: goalRefs(), issueRoot: root)
        let referenced = RelatedGoalSearch.referencedSeqs(from: routine, existing: existing)
        let rec = RelatedGoalSearch.reconcile(
            kind: "recurring", relation: "recurring-execution", llmMatches: [291],
            suggestedParentSeq: 291, placement: "sub", rationale: "", nextStep: "",
            hits: hits, hollow: hollow, referenced: referenced,
            titles: [240: "NSS 일일 리포트", 291: "주정산지급"])
        #expect(rec.suggestedParentSeq == 240, "recommended parent must be substantive #240, not hollow #291")
        #expect(rec.matches.first == 240, "matches[0] (UI action target) must be #240")
        #expect(rec.action == "task")
        #expect(rec.relation == "recurring-execution")
        #expect(rec.rationale.contains("240"), "\(rec.rationale)")
    }

    // Anchor B: goal-507-style sub-problem → sub-goal under #240 + report-sharing next-step note.
    @Test func reconcileSubProblemUnder240() {
        let hits = [RelatedGoalSearch.Hit(seq: 240, snippet: "nss 리포트 공유", source: "file",
                                          artifactHits: 90, transcriptHits: 0, hollow: false)]
        let step = "리포트 공유를 자동화하는 방향으로 관리하는 것을 추천합니다."
        let rec = RelatedGoalSearch.reconcile(
            kind: "recurring", relation: "sub-problem", llmMatches: [240],
            suggestedParentSeq: 240, placement: "sub", rationale: "", nextStep: step,
            hits: hits, hollow: [], referenced: [], titles: [240: "NSS 일일 리포트"])
        #expect(rec.suggestedParentSeq == 240)
        #expect(rec.matches.first == 240)
        #expect(rec.action == "under", "sub-problem must recommend '아래 서브 목표로 추가'")
        #expect(rec.relation == "sub-problem")
        #expect(rec.rationale.contains("240"), "\(rec.rationale)")
        #expect(rec.rationale.contains("자동화"), "managed next-step must be surfaced: \(rec.rationale)")
    }

    // Ordinary new goal (no signals) is unchanged: stays new, no forced parent.
    @Test func reconcileOrdinaryNewUnchanged() {
        let rec = RelatedGoalSearch.reconcile(
            kind: "new", relation: "unrelated", llmMatches: [], suggestedParentSeq: 0,
            placement: "top", rationale: "기존과 겹치지 않는 별개 목표", nextStep: "",
            hits: [], hollow: [], referenced: [], titles: [:])
        #expect(rec.kind == "new")
        #expect(rec.action == "add")
        #expect(rec.suggestedParentSeq == 0)
        #expect(rec.matches.isEmpty)
    }

    // Hollow title match with NO substantive alternative → do NOT file under hollow; fall to new.
    @Test func reconcileHollowNoAlternativeFallsBackToNew() {
        let rec = RelatedGoalSearch.reconcile(
            kind: "recurring", relation: "recurring-execution", llmMatches: [291],
            suggestedParentSeq: 291, placement: "sub", rationale: "", nextStep: "",
            hits: [], hollow: [291], referenced: [], titles: [291: "주정산지급"])
        #expect(rec.kind == "new")
        #expect(rec.action == "add")
        #expect(rec.suggestedParentSeq == 0)
    }
}
