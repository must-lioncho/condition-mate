import Foundation

// Automated "AI filter" v1: detects macro / fake-activity signatures from the
// per-minute input pattern. A real LLM scorer can replace this later; the
// interface (confidence 0-100 + note) stays the same.
//
// Signals of abuse:
//   - input variation is unnaturally flat (robotic constant rate)
//   - the exact same (key,mouse) pair repeats for a long run
// Genuine human work has bursty, variable input.
enum AbuseFilter {

    struct Result { let score: Int; let note: String }

    // samples: parsed today samples (each a [String:Any] with key/mouse/active).
    static func evaluate(_ samples: [[String: Any]]) -> Result {
        let activeMins = samples.filter { (($0["active"] as? Int) ?? 0) > 0 }
        guard activeMins.count >= 10 else {
            return Result(score: 100, note: "표본 부족 — 판정 보류 (정상 처리)")
        }

        let totals: [Double] = activeMins.map {
            Double(($0["key"] as? Int) ?? 0) + Double(($0["mouse"] as? Int) ?? 0)
        }
        let mean = totals.reduce(0, +) / Double(totals.count)
        let variance = totals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(totals.count)
        let sd = variance.squareRoot()
        let cv = mean > 0 ? sd / mean : 0   // coefficient of variation

        // Longest run of identical consecutive (key,mouse) pairs.
        var longestFlat = 1, cur = 1
        for i in 1..<activeMins.count {
            let a = ((activeMins[i]["key"] as? Int) ?? 0, (activeMins[i]["mouse"] as? Int) ?? 0)
            let b = ((activeMins[i-1]["key"] as? Int) ?? 0, (activeMins[i-1]["mouse"] as? Int) ?? 0)
            if a == b { cur += 1; longestFlat = max(longestFlat, cur) } else { cur = 1 }
        }

        // Score: start clean, dock for macro-like signatures.
        var score = 100
        var notes: [String] = []
        if activeMins.count >= 30 && cv < 0.12 {
            score = min(score, 40)
            notes.append("입력 변동이 비정상적으로 일정 (CV \(String(format: "%.2f", cv))) — 매크로 의심")
        } else if cv < 0.25 {
            score = min(score, 70)
            notes.append("입력 변동이 다소 낮음")
        }
        if longestFlat >= 20 {
            score = min(score, 50)
            notes.append("동일 입력값 \(longestFlat)분 연속 반복 — 자동화 의심")
        }
        // All-mouse, zero-keyboard "work" for many minutes is suspicious too.
        let mouseOnly = activeMins.filter {
            (($0["key"] as? Int) ?? 0) == 0 && (($0["mouse"] as? Int) ?? 0) > 0
        }.count
        if activeMins.count >= 30 && Double(mouseOnly) / Double(activeMins.count) > 0.85 {
            score = min(score, 60)
            notes.append("키보드 입력 거의 없음 (마우스 위주) — 검토 필요")
        }

        if notes.isEmpty { notes.append("입력 패턴 정상 범위 (CV \(String(format: "%.2f", cv)))") }
        return Result(score: score, note: notes.joined(separator: " · "))
    }
}
