import Foundation

// Routine mate (루틴 메이트) — the comrade who keeps a steady, predictable presence by
// your side, holding rhythm by time-of-day / weekday / date. See .doc/condition-mate.md §3.
//
// Stage 1 skeleton: returns the default cue so the plugin builds, connects, and the
// mate-tick worker runs end-to-end. Stage 2 loads mates/routine/schedule.json,
// evaluates the rules against context.date, and maps the first match to a Cue
// (mood band + energy bias), transitioning only when the resolved mood changes.
final class RoutineMate: Mate {
    let id = "routine"
    let name = "루틴 메이트"

    func decide(context: MateContext) -> Cue {
        // TODO (stage 2): load schedule.json, evaluate time/weekday rules → Cue.
        return .default
    }
}
