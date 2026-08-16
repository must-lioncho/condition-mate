import Foundation

// A per-app BGM strategy = a tempo band. When an app is the frontmost window
// for longer than the dwell threshold, the director switches to that app's
// profile and the music shifts into the new band.
struct BGMProfile {
    let key: String      // stable id stored in settings
    let label: String    // user-facing (Korean)
    let minBPM: Double
    let maxBPM: Double

    static let all: [BGMProfile] = [
        BGMProfile(key: "chill",  label: "칠 (느긋)",   minBPM: 75,  maxBPM: 100),
        BGMProfile(key: "steady", label: "스테디 (안정)", minBPM: 100, maxBPM: 125),
        BGMProfile(key: "focus",  label: "집중 (몰입)",   minBPM: 120, maxBPM: 150),
        BGMProfile(key: "hype",   label: "하이프 (고조)", minBPM: 140, maxBPM: 175),
    ]

    static func by(key: String) -> BGMProfile {
        all.first { $0.key == key } ?? all[1] // default: steady
    }

    // Sensible defaults for well-known apps, used until the user customizes.
    static func defaultKey(forBundleID id: String) -> String {
        switch id {
        case "com.google.Chrome", "com.google.Chrome.canary",
             "com.apple.Safari", "com.brave.Browser", "company.thebrowser.Browser":
            return "chill"   // browsing / casual
        case "com.todesktop.230313mzl4w4u92",            // Cursor
             "com.microsoft.VSCode", "com.apple.dt.Xcode":
            return "focus"   // coding / deep work
        case "notion.id", "md.obsidian", "com.apple.Notes":
            return "steady"  // writing / planning
        default:
            return "steady"
        }
    }
}
