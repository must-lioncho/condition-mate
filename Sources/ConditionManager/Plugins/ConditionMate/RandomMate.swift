import Foundation

// Random mate (랜덤 메이트) — the comrade who reads the moment and acts spontaneously,
// breaking monotony with unpredictable swings (sprint together, ease off, a surprise
// track) to keep you in the fight. See .doc/condition-mate.md §4.
//
// Stage 1 skeleton: returns the default cue. Stage 3 loads mates/random/events.json,
// paces a "time until next event" gap, draws a context-weighted event past that gap
// (respecting per-event cooldowns and a global idle/meeting gate), and emits it as a Cue.
final class RandomMate: Mate {
    let id = "random"
    let name = "랜덤 메이트"

    func decide(context: MateContext) -> Cue {
        // TODO (stage 3): pace + weighted draw from the event pool → Cue.
        return .default
    }
}
