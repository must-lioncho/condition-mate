import Foundation

/// Single source of truth for the two live, volatile session flags that every UI surface must
/// agree on — the menu-bar gauge widget, the dropdown menu, the dashboard webview, and the BGM
/// player webview:
///
///   - `isRunning`: the challenge (work session) is live.   재생/시작 — the play button.
///   - `isMuted`:   the user has silenced the sound.        뮤트 — the challenge keeps running,
///                                                           only the audio is off.
///
/// The one-button model: starting the challenge starts the music too; the mute toggle silences
/// the sound while the challenge keeps going. These two flags are what the "start" button and the
/// "mute dot" drive.
///
/// `isRunning` is not persisted — it resets to false on launch. `isMuted` IS persisted
/// (`Settings.muted`): if the sound was muted when the app went down (quit, relaunch, update), it
/// comes back muted, so an update never resurrects audio the user had silenced. Mutating either
/// flag fires `onChange` so native
/// surfaces (menu/gauge) can refresh immediately; the webviews pick the new state up on their next
/// poll via the JSON these flags feed (`/data.json` now.working/now.muted, `/api/bgm/now`,
/// `/api/session/state`).
///
/// This type intentionally holds ONLY the shared state + change notification. The side effects of a
/// state change (starting the ConditionDirector, muting the AudioEngine, pushing to a webview) stay
/// with their owners in AppDelegate, which writes through this object as the single truth.
final class ChallengeSession {
    /// The challenge / work session is live.
    private(set) var isRunning = false
    /// The user has muted the sound (the challenge keeps running). Restored from the last run.
    private(set) var isMuted = Settings.shared.muted

    /// Fired after either flag actually changes value (no-op writes don't fire).
    var onChange: (() -> Void)?

    @discardableResult
    func setRunning(_ value: Bool) -> Bool {
        guard isRunning != value else { return false }
        isRunning = value
        onChange?()
        return true
    }

    @discardableResult
    func setMuted(_ value: Bool) -> Bool {
        guard isMuted != value else { return false }
        isMuted = value
        Settings.shared.muted = value
        onChange?()
        return true
    }

    func toggleMuted() { setMuted(!isMuted) }

    /// Compact JSON for `GET /api/session/state` and for embedding in other feeds. Keep the field
    /// names (`working`, `muted`) identical everywhere they appear so every surface reads one shape.
    var stateJSON: String { "{\"working\":\(isRunning),\"muted\":\(isMuted)}" }
}
