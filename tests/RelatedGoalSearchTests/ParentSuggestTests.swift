import Testing
import Foundation
@testable import ConditionMate

// Unit tests for the deterministic 부모# suggestion scorer.
//
// The behavior under test is asymmetric on purpose: a MISSED suggestion costs the user
// nothing (the field works exactly as before), while a WRONG one shows a misleading gray
// number next to their goal. So roughly half of these assert SILENCE — no suggestion when
// the evidence is thin, ambiguous, or split between two equally plausible parents.
@Suite struct ParentSuggestTests {

    // Compact goal builder so the fixtures read as a tracker, not as struct literals.
    private func g(_ seq: Int, _ title: String, parent: Int = 0, sprint: Int = 0,
                   archived: Bool = false, released: Bool = false) -> ParentSuggest.GoalIn {
        ParentSuggest.GoalIn(seq: seq, id: "g\(seq)", title: title,
                             parentId: parent > 0 ? "g\(parent)" : "",
                             sprint: sprint, archived: archived, released: released)
    }

    private func suggestion(_ items: [ParentSuggest.Suggestion], for seq: Int) -> ParentSuggest.Suggestion? {
        items.first { $0.seq == seq }
    }

    @Test func suggestsParentOnDistinctiveTitleOverlap() {
        let goals = [
            g(1, "슬랙 번역 파이프라인"),
            g(2, "장비 페이지 픽셀아트"),
            g(3, "포모도로 통계 영속화"),
            g(10, "슬랙 번역 데몬 재시작 처리"),
        ]
        let out = ParentSuggest.compute(goals: goals)
        let s = suggestion(out, for: 10)
        #expect(s?.parentSeq == 1)
        #expect(s!.score >= ParentSuggest.minScore)
        #expect(s!.why.contains("슬랙"))
    }

    @Test func staysSilentWhenTwoParentsAreEquallyPlausible() {
        // "리포트" is the only shared term and BOTH parents own it — a coin flip, which the
        // margin gate must reject rather than resolve arbitrarily.
        let goals = [
            g(1, "리포트 자동 수집"),
            g(2, "리포트 품질 게이트"),
            g(10, "리포트 항목 추가"),
        ]
        #expect(suggestion(ParentSuggest.compute(goals: goals), for: 10) == nil)
    }

    @Test func staysSilentWhenNothingOverlaps() {
        let goals = [
            g(1, "슬랙 번역 파이프라인"),
            g(2, "장비 페이지 픽셀아트"),
            g(10, "네트워크 진단 프로브"),
        ]
        #expect(suggestion(ParentSuggest.compute(goals: goals), for: 10) == nil)
    }

    @Test func staysSilentWhenOnlyCommonFillerMatches() {
        // Every goal carries "관리", so matching on it alone says nothing. With enough goals
        // sharing the token, the distinctiveness gate must suppress the suggestion.
        let goals = [
            g(1, "컨디션 관리"), g(2, "장비 관리"), g(3, "스킬 관리"), g(4, "세션 관리"),
            g(5, "플러그인 관리"), g(6, "메모 관리"), g(7, "큐 관리"), g(8, "태그 관리"),
            g(10, "관리"),
        ]
        #expect(suggestion(ParentSuggest.compute(goals: goals), for: 10) == nil)
    }

    @Test func skipsGoalsThatAlreadyHaveAParent() {
        let goals = [
            g(1, "슬랙 번역 파이프라인"),
            g(2, "장비 페이지 픽셀아트"),
            g(10, "슬랙 번역 데몬 재시작 처리", parent: 2),   // wrongly filed, but the user's call
        ]
        #expect(suggestion(ParentSuggest.compute(goals: goals), for: 10) == nil)
    }

    @Test func skipsGoalsThatAreThemselvesParents() {
        // The tree is strictly 1 level: a goal with children can never become a child.
        let goals = [
            g(1, "슬랙 번역 파이프라인"),
            g(2, "장비 페이지 픽셀아트"),
            g(10, "슬랙 번역 데몬 재시작 처리"),
            g(11, "데몬 로그 회전", parent: 10),
        ]
        #expect(suggestion(ParentSuggest.compute(goals: goals), for: 10) == nil)
    }

    @Test func neverSuggestsItself() {
        let goals = [g(1, "슬랙 번역 파이프라인"), g(2, "슬랙 번역 파이프라인 정리")]
        for s in ParentSuggest.compute(goals: goals) { #expect(s.parentSeq != s.seq) }
    }

    @Test func ignoresArchivedAndReleasedGoals() {
        let goals = [
            g(1, "슬랙 번역 파이프라인", archived: true),
            g(2, "슬랙 번역 도구", released: true),
            g(3, "장비 페이지 픽셀아트"),
            g(10, "슬랙 번역 데몬 재시작 처리"),
        ]
        // The only matching parents are out of play, so there is nothing to propose.
        #expect(suggestion(ParentSuggest.compute(goals: goals), for: 10) == nil)
        // …and an archived orphan is not itself worth a suggestion.
        let archivedOrphan = [
            g(1, "슬랙 번역 파이프라인"),
            g(10, "슬랙 번역 데몬 재시작 처리", archived: true),
        ]
        #expect(suggestion(ParentSuggest.compute(goals: archivedOrphan), for: 10) == nil)
    }

    @Test func sameSprintBreaksAnOtherwiseTie() {
        // Identical evidence on both sides; only the sprint differs. The boost is exactly the
        // kind of nudge that SHOULD decide a tie the keywords cannot.
        let goals = [
            g(1, "슬랙 번역 알림", sprint: 3),
            g(2, "슬랙 번역 알림", sprint: 9),
            g(10, "슬랙 번역 알림 재시도", sprint: 3),
        ]
        #expect(suggestion(ParentSuggest.compute(goals: goals), for: 10)?.parentSeq == 1)
    }

    @Test func childTitlesFeedTheParentProfile() {
        // #1's own title never says "번역"; its child does. The scorer must still connect the
        // orphan to the family — this is the whole point of profiling parents by their kids.
        let goals = [
            g(1, "커뮤니케이션 개선"),
            g(2, "슬랙 메시지 번역 뷰어", parent: 1),
            g(3, "장비 페이지 픽셀아트"),
            g(10, "슬랙 번역 데몬 재시작 처리"),
        ]
        #expect(suggestion(ParentSuggest.compute(goals: goals), for: 10)?.parentSeq == 1)
    }

    @Test func folderFilenamesFeedTheParentProfile() {
        let goals = [
            g(1, "커뮤니케이션 개선"),
            g(2, "장비 페이지 픽셀아트"),
            g(10, "슬랙 번역 데몬 재시작 처리"),
        ]
        let bare = ParentSuggest.compute(goals: goals)
        #expect(suggestion(bare, for: 10) == nil)

        let tokens = ParentSuggest.folderTokens(names: ["슬랙-번역-데몬-설계.md", "goal-core.md", ".DS_Store"])
        #expect(tokens.contains("슬랙"))
        #expect(!tokens.contains("goal"))   // bookkeeping filenames are filtered out
        let withFolder = ParentSuggest.compute(goals: goals, folderTokens: [1: tokens])
        #expect(suggestion(withFolder, for: 10)?.parentSeq == 1)
    }

    @Test func outputIsDeterministic() {
        let goals = [
            g(1, "슬랙 번역 파이프라인"), g(2, "장비 페이지 픽셀아트"),
            g(10, "슬랙 번역 데몬 재시작 처리"), g(11, "장비 픽셀아트 늑대 추가"),
        ]
        let a = ParentSuggest.compute(goals: goals)
        let b = ParentSuggest.compute(goals: goals.reversed())
        #expect(a.map { "\($0.seq)>\($0.parentSeq)" } == b.map { "\($0.seq)>\($0.parentSeq)" })
    }

    @Test func handlesEmptyAndSingletonInput() {
        #expect(ParentSuggest.compute(goals: []).isEmpty)
        #expect(ParentSuggest.compute(goals: [g(1, "혼자 있는 목표")]).isEmpty)
    }

    // Not an assertion — a tuning aid. Run with CM_PSUG_DUMP=1 to print what the scorer would
    // propose for the REAL tracker, which is how the threshold/margin were calibrated
    // (over-suggesting is worse than staying quiet).
    //   CM_PSUG_DUMP=1 Scripts/run-unit-tests.sh --filter dumpRealTracker
    @Test func dumpRealTracker() throws {
        guard ProcessInfo.processInfo.environment["CM_PSUG_DUMP"] == "1" else { return }
        let path = NSString(string: "~/.condition-mate/review/goals.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else {
            print("[psug] no goals.json at \(path)")
            return
        }
        let root = try JSONSerialization.jsonObject(with: data)
        // The store writes a bare array; tolerate a {"goals":[...]} wrapper too.
        let arr = (root as? [[String: Any]]) ?? ((root as? [String: Any])?["goals"] as? [[String: Any]]) ?? []
        guard !arr.isEmpty else { print("[psug] goals.json shape unrecognized"); return }
        let goals: [ParentSuggest.GoalIn] = arr.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            let seq = (d["seq"] as? NSNumber)?.intValue ?? 0
            let text = (d["text"] as? String) ?? ""
            return ParentSuggest.GoalIn(
                seq: seq, id: id, title: text, parentId: (d["parent"] as? String) ?? "",
                sprint: (d["sprint"] as? NSNumber)?.intValue ?? 0,
                archived: (d["archived"] as? NSNumber)?.boolValue ?? false,
                released: (d["released"] as? NSNumber)?.boolValue ?? false)
        }
        let orphans = goals.filter { $0.parentId.isEmpty && !$0.archived && !$0.released }.count
        let out = ParentSuggest.compute(goals: goals)
        print("[psug] goals=\(goals.count) orphans=\(orphans) suggestions=\(out.count)")
        let titles = Dictionary(uniqueKeysWithValues: goals.map { ($0.seq, $0.title) })
        for s in out.sorted(by: { $0.score > $1.score }) {
            let child = (titles[s.seq] ?? "").prefix(38)
            let parent = (titles[s.parentSeq] ?? "").prefix(38)
            print(String(format: "  %.2f  #%d %@  →  #%d %@   (%@)",
                         s.score, s.seq, String(child), s.parentSeq, String(parent), s.why))
        }
    }
}
