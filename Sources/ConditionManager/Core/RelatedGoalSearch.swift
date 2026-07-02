import Foundation

// Hint-driven retrieval that surfaces the EXISTING goals most likely related to a NEW
// candidate BEFORE the LLM dedup judge runs.
//
// WHY: the dedup judge only ever saw one-line goal TITLES, so work buried inside a goal
// (scripts, subtasks, the session where it was actually done) whose title never mentions
// it was structurally invisible. Real case: an on-chain/NSS daily-report generator lived
// in goal #173 "Crypto on-chain data report" — its title, and its parent's, say nothing a
// title match could catch, yet its session transcript is saturated with "nss"/"리포트".
//
// HOW: mine the user's raw brain-dump prompt for distinctive keywords, then SCORE every
// existing goal by how DENSELY those keywords occur in its own session transcript and goal
// files, and return the top few. Density is the crucial signal: on a busy tracker almost
// every recent dev session mentions "리포트" once or twice, but the goal that OWNS the work
// mentions it hundreds of times — ranking by count separates the owner from the noise.
// A binary "first keyword hit wins" approach drowns in false positives here; a folder-name
// heuristic (…issue-goal-NN → NN) mis-attributes reused/renamed dirs. Neither is used.
enum RelatedGoalSearch {

    // Signals mined from the user's raw prompt. `windowDays` is nil when no time hint was
    // found; when set it is a soft recency BOOST during scoring, never a hard filter
    // (on a daily-active tracker a time gate prunes almost nothing).
    struct Signals { var keywords: [String]; var windowDays: Int? }

    // One discovered existing goal + the matched evidence, ready to feed the judge.
    struct Hit { var seq: Int; var snippet: String; var source: String }

    // Just enough of an existing goal to map its transcript/artifacts back to it. The
    // transcriptPath is the RELIABLE link (recorded when the goal's session ran); the
    // canonical goal-NN folder under the issue root is the other reliable anchor.
    struct GoalRef { var seq: Int; var title: String; var transcriptPath: String }

    // Tuning: keep the few densest goals, drop the long tail of incidental mentions.
    private static let topN = 5
    private static let relativeCutoff = 0.10   // ignore goals below 10% of the top score
    private static let maxFileBytes = 8_000_000
    private static let recencyBoost = 1.5

    // MARK: Signal extraction

    static func signals(from raw: String) -> Signals {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Signals(keywords: extractKeywords(text), windowDays: extractWindowDays(text))
    }

    private static func extractWindowDays(_ text: String) -> Int? {
        if let re = try? NSRegularExpression(pattern: "([0-9]+)\\s*일\\s*전"),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text), let n = Int(text[r]), n > 0 {
            return n
        }
        if text.contains("그끄제") || text.contains("그끄저께") { return 3 }
        if text.contains("그제") || text.contains("그저께") { return 2 }
        if text.contains("어제") { return 1 }
        return nil
    }

    // Distinctive content tokens. Splits on non-alphanumerics (keeps Hangul and English
    // words whole), drops function words and generic verbs, and — because Korean glues
    // particles onto nouns ("스크립트도", "작성을") — also emits a particle-stripped stem.
    private static func extractKeywords(_ text: String) -> [String] {
        let stop: Set<String> = [
            // function words
            "할거야", "거야", "있거든", "있었고", "있어", "만든게", "만든것", "그것을", "이것을", "저것을",
            "그리고", "하지만", "이제", "지금", "다시", "오늘", "내일", "우리", "저는", "제가",
            "위해", "위한", "대해", "대한", "관련", "일전", "이거", "그거", "저거", "여기", "거기", "그때",
            "그것", "이것", "저것", "부터", "까지",
            // generic verbs/actions — too common to be a retrieval signal
            "사용해서", "사용해", "사용", "만들거야", "만들어", "만들었는데", "만들었었고", "만들기", "만들",
            "하려고해", "하려고", "했던것", "했던", "동일하게", "동일한", "동일", "작성해", "작성을", "작성",
            "하기", "해야", "해서", "하는", "진행", "확인", "정리", "준비", "일일"
        ]
        let particle1: Set<Character> = ["를", "을", "이", "가", "은", "는", "에", "의", "도", "로", "와", "과", "만", "랑", "께"]
        let particle2 = ["으로", "에서", "까지", "부터", "에게", "한테", "이나", "라도"]

        let tokens = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        var out: [String] = []
        var seen = Set<String>()
        func add(_ c: String) {
            // ASCII tokens need >=3 chars: 2-char latin words (e.g. "pt") substring-match
            // base64/ids everywhere. Hangul tokens are safe at 2 (they don't occur in blobs).
            let minLen = c.allSatisfy { $0.isASCII } ? 3 : 2
            guard c.count >= minLen, !c.allSatisfy({ $0.isNumber }), !stop.contains(c) else { return }
            if c.range(of: "^[0-9]+일", options: .regularExpression) != nil { return }   // time cue, not content
            guard seen.insert(c).inserted else { return }
            out.append(c)
        }
        for t in tokens where !t.isEmpty {
            add(t)
            if t.count >= 4, let p = particle2.first(where: { t.hasSuffix($0) }) {
                add(String(t.dropLast(p.count)))
            } else if t.count >= 3, let last = t.last, particle1.contains(last) {
                add(String(t.dropLast()))
            }
        }
        return Array(out.prefix(12))
    }

    // MARK: Discovery

    static func discover(signals: Signals, goals: [GoalRef], issueRoot: URL, now: Date = Date()) -> [Hit] {
        guard !signals.keywords.isEmpty else { return [] }
        let corpus = buildCorpus(goals: goals, issueRoot: issueRoot)
        let cutoffDate = signals.windowDays.map { now.addingTimeInterval(-Double($0 + 2) * 86_400) }

        // Exact pass: score every goal by keyword density across its own files.
        var ranked = rank(score(corpus, keywords: signals.keywords, cutoffDate: cutoffDate, fuzzy: false),
                          keywordCount: signals.keywords.count)
        // Typo-tolerant fallback only when nothing exact turned up (honors "오타 고려").
        if ranked.isEmpty {
            ranked = rank(score(corpus, keywords: signals.keywords, cutoffDate: cutoffDate, fuzzy: true),
                          keywordCount: signals.keywords.count)
        }
        return ranked
    }

    private struct Entry { var url: URL; var seq: Int; var source: String }

    // Reliable corpus only: each goal's OWN transcript file (transcriptPath) + its canonical
    // goal-NN folder under the issue root. No transcript-dir name guessing.
    private static func buildCorpus(goals: [GoalRef], issueRoot: URL) -> [Entry] {
        var out: [Entry] = []
        // Artifacts first so a readable md/txt snippet is preferred over messy jsonl.
        out.append(contentsOf: artifactEntries(issueRoot: issueRoot))
        var seen = Set<String>()
        for g in goals where !g.transcriptPath.isEmpty {
            if seen.insert(g.transcriptPath).inserted {
                out.append(Entry(url: URL(fileURLWithPath: g.transcriptPath), seq: g.seq, source: "session"))
            }
        }
        return out
    }

    private static func artifactEntries(issueRoot: URL) -> [Entry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: issueRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [Entry] = []
        let exts: Set<String> = ["md", "txt", "py", "json", "html", "csv"]
        for e in entries {
            guard let seq = seqFromGoalEntry(e.lastPathComponent) else { continue }
            if (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let en = fm.enumerator(at: e, includingPropertiesForKeys: nil) {
                    for case let f as URL in en where exts.contains(f.pathExtension.lowercased()) {
                        out.append(Entry(url: f, seq: seq, source: "file"))
                    }
                }
            } else {
                out.append(Entry(url: e, seq: seq, source: "file"))
            }
        }
        return out
    }

    private struct Acc { var hits: [String: Double] = [:]; var snippet: String?; var source = "" }
    private static let countCap = 300   // enough to rank; avoids counting thousands of hits

    // Per-goal, per-keyword occurrence counts across the goal's own files, with a gentle
    // recency multiplier for files inside the time window. Per-keyword (not a lump total)
    // so ranking can weight each keyword by rarity (IDF) afterwards.
    private static func score(_ corpus: [Entry], keywords: [String], cutoffDate: Date?, fuzzy: Bool) -> [Int: Acc] {
        var acc: [Int: Acc] = [:]
        for e in corpus {
            let vals = try? e.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let size = vals?.fileSize, size > maxFileBytes { continue }
            guard let content = try? String(contentsOf: e.url, encoding: .utf8) else { continue }
            let (counts, snip) = countHits(content, keywords, fuzzy: fuzzy)
            guard !counts.isEmpty else { continue }
            var boost = 1.0
            if let cut = cutoffDate, let m = vals?.contentModificationDate, m >= cut { boost = recencyBoost }
            var a = acc[e.seq] ?? Acc()
            for (kw, n) in counts { a.hits[kw, default: 0] += Double(n) * boost }
            if a.snippet == nil, let snip = snip { a.snippet = snip; a.source = e.source }
            acc[e.seq] = a
        }
        return acc
    }

    // Rank by an IDF-weighted density so a rare, distinctive keyword ("nss", present in a
    // handful of goals) dominates a common one ("리포트", sprinkled across dev chatter) —
    // this suppresses generic-word noise without hand-maintained stopword lists. Require
    // enough distinct keywords to co-occur, clear a fraction of the top score, cap at topN.
    private static func rank(_ acc: [Int: Acc], keywordCount: Int) -> [Hit] {
        guard !acc.isEmpty else { return [] }
        let docs = Double(acc.count)
        var idf: [String: Double] = [:]
        for kw in Set(acc.values.flatMap { $0.hits.keys }) {
            let df = Double(acc.values.filter { ($0.hits[kw] ?? 0) > 0 }.count)
            idf[kw] = log(1 + docs / max(1, df))
        }
        func weighted(_ a: Acc) -> Double { a.hits.reduce(0) { $0 + $1.value * (idf[$1.key] ?? 0) } }
        let floorDistinct = min(2, keywordCount)
        let sorted = acc.filter { $0.value.hits.count >= floorDistinct }
            .map { (seq: $0.key, acc: $0.value, w: weighted($0.value)) }
            .sorted { $0.w > $1.w }
        guard let top = sorted.first?.w, top > 0 else { return [] }
        let cutoff = top * relativeCutoff
        return sorted.filter { $0.w >= cutoff }.prefix(topN).map {
            Hit(seq: $0.seq, snippet: $0.acc.snippet ?? "", source: $0.acc.source)
        }
    }

    // Count keyword occurrences in one file via NSRegularExpression over the raw string
    // (UTF-16/NSString — fast, and no full-file lowercasing). ASCII keywords match on a
    // WORD BOUNDARY (so "nss" counts real "NSS" text, not a stray "nss" inside a base64
    // blob); Hangul matches as a substring (so a stemmed noun "리포트" still counts its
    // particle-glued "리포트를"). Counting stops at countCap per keyword.
    private static func countHits(_ content: String, _ keywords: [String], fuzzy: Bool) -> ([String: Int], String?) {
        let ns = content as NSString
        let full = NSRange(location: 0, length: ns.length)
        var counts: [String: Int] = [:]
        var cand: [NSRange] = []   // candidate match ranges to pick a readable snippet from
        for kw in keywords {
            let esc = NSRegularExpression.escapedPattern(for: kw)
            let pattern = kw.allSatisfy({ $0.isASCII }) ? "\\b\(esc)\\b" : esc
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            var c = 0
            re.enumerateMatches(in: content, range: full) { m, _, stop in
                guard let m = m else { return }
                if c < 4 { cand.append(m.range) }   // keep a few per keyword to choose from
                c += 1
                if c >= countCap { stop.pointee = true }
            }
            if c > 0 { counts[kw] = c }
        }
        // Prefer a snippet from PROSE, not a base64/hex blob: a transcript's first keyword
        // hit is often inside an embedded image blob, which tells the judge nothing.
        var snip = counts.isEmpty ? nil : bestSnippet(ns, cand)
        // Fuzzy fallback: count word-level edit-distance-≤1 matches for distinctive keywords.
        if fuzzy, counts.isEmpty {
            let words = Set(content.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            for kw in keywords where kw.count >= 3 {
                var c = 0
                for w in words where abs(w.count - kw.count) <= 1 {
                    if levenshtein(w, kw) <= 1 { c += 1 }
                }
                if c > 0 { counts[kw] = c; if snip == nil { snip = "≈\(kw)" } }
            }
        }
        return (counts, snip)
    }

    // Pick the most readable window among candidate match ranges: prose (spaces + Hangul)
    // scores high, a base64/hex blob (long unbroken runs, no spaces) scores ~0.
    private static func bestSnippet(_ ns: NSString, _ ranges: [NSRange]) -> String? {
        var best: String? = nil
        var bestScore = -1
        for r in ranges.prefix(12) {
            let s = snippet(ns, around: r)
            let score = readability(s)
            if score > bestScore { bestScore = score; best = s }
        }
        return best
    }

    private static func readability(_ s: String) -> Int {
        var spaces = 0, hangul = 0, longestRun = 0, run = 0
        for ch in s.unicodeScalars {
            if ch == " " { spaces += 1; run = 0 }
            else {
                run += 1; longestRun = max(longestRun, run)
                if (0xAC00...0xD7A3).contains(ch.value) { hangul += 1 }
            }
        }
        // Reward prose signals; penalize an unbroken 40+ char run (blob signature).
        return spaces + hangul - (longestRun >= 40 ? 30 : 0)
    }

    private static func snippet(_ ns: NSString, around r: NSRange) -> String {
        let lo = max(0, r.location - 60)
        let len = min(ns.length - lo, r.length + 120)
        let raw = ns.substring(with: NSRange(location: lo, length: len)).replacingOccurrences(of: "\\n", with: " ")
        let collapsed = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(collapsed.prefix(140))
    }

    // MARK: seq mapping

    // "goal-130" or "goal-102.md" → seq. nil otherwise.
    static func seqFromGoalEntry(_ name: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: "^goal-0*([0-9]+)(\\.[A-Za-z0-9]+)?$"),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let r = Range(m.range(at: 1), in: name) else { return nil }
        return Int(name[r])
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
