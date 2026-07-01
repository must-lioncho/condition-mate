import Foundation

// The set of available mates and the user's current selection. The selection persists
// in Settings (cm.conditionMate); the dashboard's 컨디션 메이트 plugin card flips it
// (stage 2 UI). Adding a mate is one line in `all` — the card renders options from this
// list, mirroring how PluginStore.builtins drives plugin cards.
final class MateRegistry {
    static let shared = MateRegistry()

    // Registration order = display order. all[0] is the safe fallback.
    let all: [Mate] = [RoutineMate(), RandomMate()]

    private init() {}

    // The active mate, resolved from Settings; falls back to the first if the stored
    // id is unknown (e.g. a mate was removed).
    var current: Mate {
        let id = Settings.shared.conditionMate
        return all.first { $0.id == id } ?? all[0]
    }

    // Switch the active mate (ignored if the id isn't registered).
    func select(_ id: String) {
        guard all.contains(where: { $0.id == id }) else { return }
        Settings.shared.conditionMate = id
    }
}
