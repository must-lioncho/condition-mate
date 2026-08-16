import Foundation

// 컨디션 메이트 (Condition Mate) — the relationship layer above BGM control
// (see .doc/condition-mate.md). It is NOT a coach (on-site but holding the
// initiative, leading you) and NOT a road manager (no initiative, support only).
// It is a *mate*: it endures the extreme stress and physical pressure WITH you and
// you can entrust your back to it — the strong comradeship (전우애) of a hard fight.
//
// Mechanically the mate sits ABOVE the ConditionDirector: it reads the whole
// situation and hands down a Cue (an intent), never touching the audio engine
// directly. The director is the executor that turns a Cue into a tempo band / scene
// track. When no mate plugin is connected the director runs autonomously exactly as
// before — the mate is an optional comrade layered on the existing adaptive control.

// A Cue is the mate's output: an intent, not concrete BPM numbers. The director
// translates it via its existing primitives (applyProfile, scene tracks, release).
// Stage 1 carries the minimal vocabulary; later stages extend it (forced events,
// scene pinning) without changing the seam.
struct Cue {
    // Energy direction the mate is pulling toward within the chosen mood band.
    // Reserved for stage 2+ where the director biases warmup/release; stage 1
    // records it for logging only.
    enum EnergyBias: String {
        case lift    = "가속"   // push through with you
        case neutral = "중립"   // leave the director's adaptive control alone
        case calm    = "감속"   // ease off and recover together
    }

    var profileKey: String?     // chill/steady/focus/hype to switch mood band (nil = leave)
    var energyBias: EnergyBias  // direction hint (stage 2+)
    var narration: String?      // one-line message to the user (Discord, stage 4)

    // The do-nothing cue: leave the director on its autonomous behavior.
    static let `default` = Cue(profileKey: nil, energyBias: .neutral, narration: nil)

    // Short human-readable summary for the worker log.
    var summary: String {
        var parts: [String] = []
        if let p = profileKey { parts.append("무드=\(p)") }
        if energyBias != .neutral { parts.append("편향=\(energyBias.rawValue)") }
        if let n = narration, !n.isEmpty { parts.append("멘트=\(n)") }
        return parts.isEmpty ? "유지 (기본 연출)" : parts.joined(separator: " · ")
    }
}

// The observation bundle a mate reads to make its decision. Assembled by the
// heartbeat each mate tick. Foundation-only (no AppKit) so the plugin stays portable.
struct MateContext {
    let date: Date            // now — for routine schedule evaluation (time/weekday)
    let activityRate: Double  // smoothed keyboard+mouse rate (APM-ish)
    let isIdle: Bool          // user away (no input past the idle threshold)
    let frontAppLabel: String // current frontmost app display name ("" if unknown)
    let phase: String         // director phase: WARMUP/SUSTAIN/RELEASE/IDLE/-
    let targetBPM: Double     // director's current target BPM
    let profileLabel: String  // active mood profile label
    let libMinBPM: Double?    // available track BPM range (for gap detection / Suno)
    let libMaxBPM: Double?
    // External signals (Discord-sourced subjective condition/requests) join here in
    // stage 4. Stage 1 leaves the struct activity-only.
}

// A mate is a swappable comrade with its own way of sharing the grind. Stateless from
// the caller's view: given a context, return the next Cue. Implementations may keep
// their own internal state (last event time, schedule, RNG seed) across calls. The two
// stage-1 styles are RoutineMate (steady, predictable presence) and RandomMate
// (spontaneous, reads the moment).
protocol Mate {
    var id: String { get }    // stable key stored in Settings (cm.conditionMate)
    var name: String { get }  // user-facing Korean label
    func decide(context: MateContext) -> Cue
}
