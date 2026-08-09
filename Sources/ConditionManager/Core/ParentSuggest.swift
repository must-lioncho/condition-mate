import Foundation

// Deterministic "which parent does this orphan goal belong under?" scorer.
//
// WHY: the board's 부모# field only accepts a number the user has to remember, so goals
// pile up unparented. This proposes a parent — shown as a GRAY ghost number the user can
// click to inspect — but never commits it: the user still types the number to confirm.
// That asymmetry is deliberate; a wrong auto-attach is far more expensive to undo than a
// missed suggestion, so the scorer is tuned to stay SILENT when the evidence is thin.
//
// HOW: title keywords, IDF-weighted. A token shared by half the tracker ("리포트") says
// almost nothing; a token that occurs in two goals ("슬랙") says almost everything. Each
// top-level goal gets a profile built from its own title plus — at lower weight — its
// children's titles and its goal-NN folder's file names (the folder is where the work
// actually landed, so its filenames name the work better than the title often does).
//
// No LLM, no network: this runs on every goal-set change, so it must be cheap and stable.
// The AI placement verdict (RelatedGoalSearch + the dedup judge) stays where it is — that
// path judges ONE new candidate at a time and is far too expensive for a whole-board sweep.
enum ParentSuggest {

    // One goal, flattened to just what scoring needs.
    struct GoalIn {
        var seq: Int
        var id: String
        var title: String
        var parentId: String
        var sprint: Int
        var archived: Bool
        var released: Bool
        init(seq: Int, id: String, title: String, parentId: String = "",
             sprint: Int = 0, archived: Bool = false, released: Bool = false) {
            self.seq = seq; self.id = id; self.title = title; self.parentId = parentId
            self.sprint = sprint; self.archived = archived; self.released = released
        }
    }

    // One accepted proposal: goal `seq` probably belongs under goal `parentSeq`.
    struct Suggestion {
        var seq: Int
        var parentSeq: Int
        var score: Double
        var why: String
    }

    // Acceptance gates. ALL must pass, and they are strict on purpose (see the note above).
    //   minScore    - the winner must claim a real share of the contested keyword mass.
    //   minMargin   - and it must clearly beat the runner-up; a near-tie means "I don't know",
    //                 which is reported as NO suggestion rather than a coin flip.
    //   minCoverage - the match must also be a real share of the child's WHOLE title, so one
    //                 incidental word shared with a long title can't score high on its own.
    static let minScore = 0.45
    static let minMargin = 0.08
    static let minCoverage = 0.12

    // Weight of a token depending on where in the parent's profile it was found. The title
    // is the parent's own claim about itself; children titles and folder filenames are
    // corroborating evidence that a title match should not be able to outrank.
    private static let wTitle = 1.0
    private static let wChild = 0.65
    private static let wFolder = 0.55

    // Boosts applied to the raw overlap score. Multiplicative and small — they reorder
    // near-equal candidates, they never manufacture a match out of nothing.
    private static let boostSameSprint = 1.15
    private static let boostRecent = 1.10
    private static let boostHasKids = 1.05

    // Past this many children a goal is a NAMESPACE, not a family — the real tracker has an
    // umbrella goal with ~500 children covering every feature of the app. Absorbing its
    // children's titles would hand it the entire corpus vocabulary and it would then "match"
    // every orphan on one incidental word. Beyond the cap only the goal's own title and
    // folder count, so it still competes — just on its own terms.
    private static let maxProfileKids = 12

    // `folderTokens` maps a goal seq to the tokens mined from its goal-NN folder filenames
    // (supplied by the caller so this stays pure and testable — no disk access in here).
    // `recentParentSeqs` is the user's MRU parent list; being recently used is a mild hint.
    static func compute(goals: [GoalIn],
                        recentParentSeqs: [Int] = [],
                        folderTokens: [Int: [String]] = [:]) -> [Suggestion] {
        let live = goals.filter { !$0.archived && !$0.released && $0.seq > 0 }
        guard live.count > 1 else { return [] }

        let kidsByParent = Dictionary(grouping: live.filter { !$0.parentId.isEmpty }, by: { $0.parentId })
        let recent = Set(recentParentSeqs)

        // Token sets per goal title, and the document frequency that turns them into IDF.
        var titleTokens: [String: [String]] = [:]
        var df: [String: Int] = [:]
        for g in live {
            let toks = RelatedGoalSearch.extractKeywords(g.title)
            titleTokens[g.id] = toks
            for t in Set(toks) { df[t, default: 0] += 1 }
        }
        let n = Double(live.count)
        func idf(_ t: String) -> Double { log(1.0 + n / Double(max(1, df[t] ?? 1))) }
        // A token is "distinctive" when it does not smear across the whole tracker. At least
        // one matched token must clear this bar, otherwise the match rests on filler alone.
        // Floored at 3 so tiny goal sets — where every shared word looks "common" — aren't
        // silenced outright.
        let commonCut = max(3, live.count / 4)

        // Candidate parents: top-level, still live. A goal that already has children is a
        // proven grouping node, so it is preferred (boost) but never required.
        let parents = live.filter { $0.parentId.isEmpty }

        // Parent profile: token -> best weight found for it.
        var profiles: [String: [String: Double]] = [:]
        for p in parents {
            var prof: [String: Double] = [:]
            for t in titleTokens[p.id] ?? [] { prof[t] = max(prof[t] ?? 0, wTitle) }
            let kids = kidsByParent[p.id] ?? []
            if kids.count <= maxProfileKids {
                for c in kids {
                    for t in titleTokens[c.id] ?? [] { prof[t] = max(prof[t] ?? 0, wChild) }
                }
            }
            for t in folderTokens[p.seq] ?? [] { prof[t] = max(prof[t] ?? 0, wFolder) }
            profiles[p.id] = prof
        }

        var out: [Suggestion] = []
        for child in live {
            // Only orphans that can legally take a parent: no parent yet, and not itself a
            // grouping node (the app keeps a strictly 1-level tree).
            guard child.parentId.isEmpty, (kidsByParent[child.id] ?? []).isEmpty else { continue }
            let ctoks = titleTokens[child.id] ?? []
            guard !ctoks.isEmpty else { continue }

            // Two denominators, because they answer two different questions.
            //
            // `contested` — the mass of the child's terms that ANY candidate parent claims.
            // Terms nobody claims (usually unique to this goal) cannot discriminate between
            // parents, so scoring against them would just punish descriptive titles: a goal
            // named "슬랙 번역 데몬 재시작 처리" would score lower under the 슬랙 번역 parent
            // than a goal named "슬랙 번역", which is backwards. The score therefore asks
            // "of what's actually up for grabs, how much does THIS parent claim?".
            //
            // `total` — the child's whole title mass, used only for the coverage gate below,
            // which is what stops one incidental shared word in a long title from winning.
            // Self is excluded: a childless top-level goal is its own candidate-parent entry,
            // and letting it claim its own tokens would make `contested` == `total` and mute
            // every real match.
            let total = ctoks.reduce(0.0) { $0 + idf($1) }
            let contested = ctoks.filter { t in
                parents.contains { $0.id != child.id && profiles[$0.id]?[t] != nil }
            }.reduce(0.0) { $0 + idf($1) }
            guard contested > 0, total > 0 else { continue }

            var best: (seq: Int, score: Double, coverage: Double, matched: [String])? = nil
            var runnerUp = 0.0
            for p in parents where p.id != child.id {
                guard let prof = profiles[p.id], !prof.isEmpty else { continue }
                var num = 0.0
                var matched: [String] = []
                for t in ctoks {
                    guard let w = prof[t] else { continue }
                    num += idf(t) * w
                    matched.append(t)
                }
                guard !matched.isEmpty else { continue }
                guard matched.contains(where: { (df[$0] ?? 0) <= commonCut }) else { continue }
                // Evidence strength. The tokenizer emits a word AND its particle-stripped stem
                // ("부모와" + "부모"), so a raw token count double-counts one piece of evidence
                // — group them first. Two independent terms, or one genuinely rare term
                // (essentially exclusive to this pair), is the bar. One shared ordinary word
                // is how "이렇게 …" ends up filed under an unrelated goal.
                let units = evidenceUnits(matched)
                guard units.count >= 2
                    || units.first?.contains(where: { (df[$0] ?? 0) <= 2 }) == true else { continue }
                var score = num / contested
                if p.sprint > 0 && p.sprint == child.sprint { score *= boostSameSprint }
                if recent.contains(p.seq) { score *= boostRecent }
                if !(kidsByParent[p.id] ?? []).isEmpty { score *= boostHasKids }
                // NOT clamped here: clamping would flatten a boosted winner back onto a
                // saturated runner-up and erase the very margin the boost exists to create.
                if score > (best?.score ?? 0) {
                    runnerUp = best?.score ?? 0
                    best = (p.seq, score, num / total, matched)
                } else if score > runnerUp {
                    runnerUp = score
                }
            }

            guard let b = best, b.score >= minScore, (b.score - runnerUp) >= minMargin,
                  b.coverage >= minCoverage else { continue }
            out.append(Suggestion(seq: child.seq, parentSeq: b.seq, score: min(1.0, b.score),
                                  why: whyText(b.matched, idf: idf)))
        }
        // Two goals can point at each other (A→B and B→A) when they share nearly all their
        // keywords. Both ghosts at once reads as an invitation to build a cycle, so keep one
        // direction: the NEWER goal becomes the child. Goal numbers are handed out in order,
        // so the older one is the thing the newer work grew out of.
        let picks = Dictionary(out.map { ($0.seq, $0.parentSeq) }, uniquingKeysWith: { a, _ in a })
        return out.filter { picks[$0.parentSeq] != $0.seq || $0.seq > $0.parentSeq }
            .sorted { $0.seq < $1.seq }
    }

    // Ranked candidate parents for ONE free-text title (a 메모장 line, not a board goal).
    // This feeds a dropdown the user opens and reads — nothing auto-attaches — so unlike
    // compute() it does NOT apply the silence gates (minScore/minMargin/minCoverage): a
    // weak-evidence candidate in an opt-in list costs one glance, while the same candidate
    // as an auto-ghost would cost a wrong attach. The only hard bar kept is "at least one
    // matched token must be distinctive" — without it every long title matches everything
    // on filler words and the list becomes noise.
    struct Candidate {
        var parentSeq: Int
        var score: Double
        var why: String
    }

    static func rank(title: String, goals: [GoalIn],
                     recentParentSeqs: [Int] = [],
                     folderTokens: [Int: [String]] = [:],
                     limit: Int = 5) -> [Candidate] {
        let live = goals.filter { !$0.archived && !$0.released && $0.seq > 0 }
        let ctoks = RelatedGoalSearch.extractKeywords(title)
        guard !live.isEmpty, !ctoks.isEmpty else { return [] }

        let kidsByParent = Dictionary(grouping: live.filter { !$0.parentId.isEmpty }, by: { $0.parentId })
        let recent = Set(recentParentSeqs)

        var df: [String: Int] = [:]
        var titleTokens: [String: [String]] = [:]
        for g in live {
            let toks = RelatedGoalSearch.extractKeywords(g.title)
            titleTokens[g.id] = toks
            for t in Set(toks) { df[t, default: 0] += 1 }
        }
        let n = Double(live.count)
        func idf(_ t: String) -> Double { log(1.0 + n / Double(max(1, df[t] ?? 1))) }
        let commonCut = max(3, live.count / 4)

        // Same candidate set and profile recipe as compute() — the dropdown must agree with
        // the board ghost about WHO can be a parent, they just disagree about when to speak.
        let parents = live.filter { $0.parentId.isEmpty }
        var out: [Candidate] = []
        for p in parents {
            var prof: [String: Double] = [:]
            for t in titleTokens[p.id] ?? [] { prof[t] = max(prof[t] ?? 0, wTitle) }
            let kids = kidsByParent[p.id] ?? []
            if kids.count <= maxProfileKids {
                for c in kids {
                    for t in titleTokens[c.id] ?? [] { prof[t] = max(prof[t] ?? 0, wChild) }
                }
            }
            for t in folderTokens[p.seq] ?? [] { prof[t] = max(prof[t] ?? 0, wFolder) }
            guard !prof.isEmpty else { continue }

            var num = 0.0
            var matched: [String] = []
            for t in ctoks {
                guard let w = prof[t] else { continue }
                num += idf(t) * w
                matched.append(t)
            }
            guard !matched.isEmpty else { continue }
            guard matched.contains(where: { (df[$0] ?? 0) <= commonCut }) else { continue }
            let total = ctoks.reduce(0.0) { $0 + idf($1) }
            var score = num / max(total, 0.0001)
            if recent.contains(p.seq) { score *= boostRecent }
            if !kids.isEmpty { score *= boostHasKids }
            out.append(Candidate(parentSeq: p.seq, score: min(1.0, score),
                                 why: whyText(matched, idf: idf)))
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(max(0, limit)))
    }

    // Collapse tokens that are prefix-variants of one another ("부모와"/"부모") into a single
    // unit of evidence, so stem duplication can't masquerade as two independent matches.
    private static func evidenceUnits(_ matched: [String]) -> [[String]] {
        var groups: [[String]] = []
        for t in matched.sorted(by: { $0.count < $1.count }) {
            if let i = groups.firstIndex(where: { g in g.contains { t.hasPrefix($0) || $0.hasPrefix(t) } }) {
                groups[i].append(t)
            } else {
                groups.append([t])
            }
        }
        return groups
    }

    // Short Korean rationale for the hover tooltip: the three most distinctive shared terms.
    private static func whyText(_ matched: [String], idf: (String) -> Double) -> String {
        let top = matched.sorted { idf($0) > idf($1) }.prefix(3)
        return "제목 키워드 일치: " + top.joined(separator: ", ")
    }

    // Tokens mined from one goal folder's entry names (non-recursive). Filenames are what
    // the work was actually called, so they often carry the term the title omits.
    static func folderTokens(names: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for name in names {
            // Skip bookkeeping entries that every goal folder has — they would make every
            // parent profile look identical.
            let lower = name.lowercased()
            if lower.hasPrefix(".") || lower == "tasks" || lower == "attachments" || lower == "chat" { continue }
            if lower.hasPrefix("goal-core") || lower.hasPrefix("goal-detail") || lower == "goal.md" { continue }
            for t in RelatedGoalSearch.extractKeywords(name) where seen.insert(t).inserted {
                out.append(t)
            }
        }
        // Capped for the same reason child titles are: a goal folder with hundreds of
        // artifacts would otherwise buy its goal a vocabulary that matches anything.
        return Array(out.prefix(40))
    }
}
