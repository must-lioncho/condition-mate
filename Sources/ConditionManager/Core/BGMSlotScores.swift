import Foundation

// 전략4 · 상태 인지형 (Phase 1, observe-only): derive per-plan-slot hit/miss scores by
// replaying the actions.jsonl event stream (the same ~1MB window ActionLog serves).
// Pure read/derive — nothing is written, selection and the plan file are untouched.
//
// Scoring rules (docs/specs/strategy4-state-aware-bgm.md §5):
//   - Slot identity: trackChange.pool == "플랜 · <slot.label>"; non-plan pools (mode
//     fallback, 폭우 리셋) are excluded from scoring.
//   - Session attribution: a sessionStart..sessionStop window is attributed to EVERY
//     slot whose plan pool produced a trackChange inside it (crossing a slot boundary
//     credits each involved slot with one session).
//   - hit (+1): a session the slot was involved in ends with no negative signal.
//     pomodoro needs elapsed >= pomodoroTargetSeconds (a completed 25min run);
//     sprint/unlimited have no target — ending clean counts as a (weak) hit.
//   - miss (+1): an explicit dislike while the slot governs selection, or a mute
//     during a session. trackChange's "강제 전환" detail is NEUTRAL (it bundles slot
//     boundaries/profile changes/idle flips — never counted as a miss), and
//     bgmOn/bgmOff are unrelated to slot quality (excluded).
//
// This type is deliberately standalone (Foundation only, injected inputs) so the
// derivation can be exercised at unit level outside the app process.
enum BGMSlotScores {

    // Plan-slot metadata joined onto the scores by label (the join key that already
    // exists in the log). Kept as a local mirror of BGMPlanMap.Slot so this file has
    // no dependency on the audio layer.
    struct SlotMeta {
        var label: String
        var days: String
        var from: String
        var to: String
        var themes: [String]
    }

    // A pomodoro is complete at 25 wall-clock minutes — signalled by a pomodoro.complete
    // event inside the session window. Legacy logs (pre-완주-이벤트) fall back to the
    // sessionStop detail's elapsed seconds ("세션 중지 · N초 경과") vs this target.
    static let pomodoroTargetSeconds = 1500

    private static let planPoolPrefix = "플랜 · "

    private struct Acc {
        var sessions = 0
        var hits = 0
        var misses = 0
        var lastHitAt = 0
        var lastMissAt = 0
        var sampleTracks: [String] = []   // tracks heard during the most recent hit session
    }

    // Derive the §5.4 response envelope from the raw events feed (ActionLog.recentJSON
    // output: {"events":[...oldest first...]}) plus the current plan's slot metadata.
    static func deriveJSON(eventsJSON: String, slots: [SlotMeta], activeStrategy: Int,
                           now: Int = Int(Date().timeIntervalSince1970)) -> String {
        var events: [[String: Any]] = []
        if let data = eventsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = obj["events"] as? [[String: Any]] {
            events = list
        }

        var acc: [String: Acc] = [:]
        // Insertion order of first appearance, so unscored-but-seen slots list stably.
        var order: [String] = []
        func bucket(_ label: String) -> Acc {
            if acc[label] == nil { acc[label] = Acc(); order.append(label) }
            return acc[label]!
        }

        // Replay state. currentSlot is the plan slot governing selection at this point
        // of the log (nil while a non-plan pool — mode fallback / rain reset — governs).
        var currentSlot: String? = nil
        var inSession = false
        var sessionMode = "-"
        var sessionNegative = false
        var sessionCompleted = false                     // pomodoro.complete seen in this window
        var sessionSlots: [String] = []                  // involved slots, in order
        var sessionTracks: [String: [String]] = [:]      // slot label -> track titles heard

        for e in events {
            let action = e["action"] as? String ?? ""
            let t = intValue(e["t"])
            switch action {
            case "trackChange":
                let pool = e["pool"] as? String ?? ""
                if pool.hasPrefix(planPoolPrefix) {
                    let label = String(pool.dropFirst(planPoolPrefix.count))
                    currentSlot = label
                    if inSession {
                        if !sessionSlots.contains(label) { sessionSlots.append(label) }
                        let title = e["track"] as? String ?? ""
                        if !title.isEmpty { sessionTracks[label, default: []].append(title) }
                    }
                } else {
                    currentSlot = nil
                }
                // "강제 전환" detail is neutral by construction: no miss is ever
                // counted from a trackChange event.
            case "sessionStart":
                inSession = true
                sessionMode = e["mode"] as? String ?? "-"
                sessionNegative = false
                sessionCompleted = false
                sessionSlots = []
                sessionTracks = [:]
            case "pomodoro.complete":
                // Server-judged wall-clock completion (logged just before its sessionStop).
                // Authoritative for pomodoro hits: the stop's elapsed is ACTIVITY seconds,
                // which can sit below the target even on a completed wall-clock run.
                if inSession { sessionCompleted = true }
            case "sessionStop":
                guard inSession else { break }           // head clipped by the window
                inSession = false
                let elapsed = firstInt(in: e["detail"] as? String ?? "") ?? 0
                let clean = !sessionNegative
                // elapsed>=target kept as fallback for pre-완주-이벤트 logs.
                let completed = (sessionMode == "pomodoro")
                    ? (sessionCompleted || elapsed >= pomodoroTargetSeconds) : true
                for label in sessionSlots {
                    var a = bucket(label)
                    a.sessions += 1
                    if clean && completed {
                        a.hits += 1
                        a.lastHitAt = max(a.lastHitAt, t)
                        // Evidence for the score: the tracks heard in the latest hit
                        // session (most recent first, deduped, capped at 3).
                        var seen = Set<String>()
                        a.sampleTracks = (sessionTracks[label] ?? []).reversed()
                            .filter { seen.insert($0).inserted }
                        if a.sampleTracks.count > 3 { a.sampleTracks = Array(a.sampleTracks.prefix(3)) }
                    }
                    acc[label] = a
                }
            case "dislike":
                // Explicit negative for whatever slot governs selection right now,
                // inside or outside a session.
                if inSession { sessionNegative = true }
                if let label = currentSlot {
                    var a = bucket(label)
                    a.misses += 1
                    a.lastMissAt = max(a.lastMissAt, t)
                    acc[label] = a
                }
            case "mute":
                // Muting mid-session says "this slot's pick had to be silenced" even
                // if unmuted soon after; mute outside a session is not slot feedback.
                guard inSession else { break }
                sessionNegative = true
                if let label = currentSlot {
                    var a = bucket(label)
                    a.misses += 1
                    a.lastMissAt = max(a.lastMissAt, t)
                    acc[label] = a
                }
            default:
                break   // unmute/bgmOn/bgmOff/chime/... — not slot-quality signals
            }
        }
        // A session still open at the window's end is in progress — not scored.

        let metaByLabel = Dictionary(slots.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        struct Row {
            var label: String; var meta: SlotMeta?; var a: Acc
            var score: Int { a.hits - a.misses }
            var hitRate: Double { Double(a.hits) / Double(max(1, a.hits + a.misses)) }
        }
        var rows = order.map { Row(label: $0, meta: metaByLabel[$0], a: acc[$0] ?? Acc()) }
        rows.sort { l, r in
            l.score != r.score ? l.score > r.score : l.a.sessions > r.a.sessions
        }

        let slotItems = rows.map { row -> String in
            let m = row.meta
            let themes = (m?.themes ?? []).map(jsonEsc).joined(separator: ",")
            let samples = row.a.sampleTracks.map(jsonEsc).joined(separator: ",")
            let rePlan = row.a.sessions >= 3 && row.hitRate < 0.5
            let rate = String(format: "%.3f", row.hitRate)
            return "{\"label\":\(jsonEsc(row.label)),\"days\":\(jsonEsc(m?.days ?? "")),"
                + "\"from\":\(jsonEsc(m?.from ?? "")),\"to\":\(jsonEsc(m?.to ?? "")),"
                + "\"themes\":[\(themes)],\"sessions\":\(row.a.sessions),"
                + "\"hits\":\(row.a.hits),\"misses\":\(row.a.misses),\"score\":\(row.score),"
                + "\"hitRate\":\(rate),\"rePlanCandidate\":\(rePlan),"
                + "\"lastHitAt\":\(row.a.lastHitAt),\"lastMissAt\":\(row.a.lastMissAt),"
                + "\"sampleTracks\":[\(samples)]}"
        }
        return "{\"generatedAt\":\(now),\"window\":\(jsonEsc("actions.jsonl 최근 ~1MB")),"
            + "\"activeStrategy\":\(activeStrategy),"
            + "\"slots\":[\(slotItems.joined(separator: ","))]}"
    }

    // MARK: - Helpers

    private static func intValue(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let n = v as? Double { return Int(n) }
        if let n = v as? NSNumber { return n.intValue }
        return 0
    }

    // First run of digits in a string — parses the elapsed seconds out of
    // "세션 중지 · 1500초 경과" without depending on the exact wording around it.
    private static func firstInt(in s: String) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func jsonEsc(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
        return out
    }
}
