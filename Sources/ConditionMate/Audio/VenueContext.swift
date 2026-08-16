import Foundation

// 전략7 · 장소·컨디션 컨텍스트. The app can infer the clock and the work-block, but it
// cannot know the ROOM the user is actually sitting in (a small cafe vs an open office)
// or how their body feels (sleepless dawn, post-lunch dip). 전략7 lets the user say it
// in one tap: a fixed catalog of ~10 place/condition presets, each of which re-pools
// selection (theme folders) and re-tunes the tempo envelope (band fraction + warmup
// ramp) — the condition-adaptive core (WARMUP/SUSTAIN/RELEASE, dislikes, recency,
// plan slots on the default preset) keeps running unchanged inside that envelope.
//
// The chosen preset persists in settings.json (cm.bgmVenue) so it survives app
// restarts AND updates; the default is the ordinary "2명이 있는 사무실", which is a
// pure passthrough (auto pool = plan map / start context / mode lists as before).
struct VenueContext {
    let key: String        // stable id stored in settings
    let label: String      // user-facing (Korean)
    let emoji: String
    let desc: String       // one-line tooltip: what this preset does to the sound
    let themes: [String]   // theme-folder pool override; [] = passthrough (auto pool)
    let lo: Double         // band = profile band's [lo, hi] fraction of its span
    let hi: Double
    let ramp: Double       // warmup climb multiplier (1.0 = neutral)

    // The default preset changes nothing — selection behaves exactly as before 전략7.
    var isPassthrough: Bool { themes.isEmpty && lo == 0 && hi == 1 && ramp == 1 }

    static let defaultKey = "twoOffice"

    // Fixed catalog (order = UI order). Theme names are folders under the music root;
    // a preset naming only missing folders degrades to the auto pool (BPMLibrary's
    // blocked-pool fallback), never to silence.
    static let all: [VenueContext] = [
        VenueContext(key: "smallCafe", label: "작은 카페", emoji: "☕️",
                     desc: "소곤소곤한 공간 — 라운지 톤으로 낮게",
                     themes: ["lounge", "england"], lo: 0.10, hi: 0.55, ramp: 0.8),
        VenueContext(key: "bigCafe", label: "큰 카페", emoji: "🏬",
                     desc: "웅성이는 활기 — 리듬 있게 묻어가기",
                     themes: ["house", "lounge", "gold"], lo: 0.30, hi: 0.80, ramp: 1.0),
        VenueContext(key: "soloOffice", label: "독립방 사무실", emoji: "🚪",
                     desc: "혼자만의 방 — 마음껏 몰입, 고속 점화",
                     themes: ["challenge", "steel", "office"], lo: 0.35, hi: 1.00, ramp: 1.3),
        VenueContext(key: "twoOffice", label: "2명 사무실", emoji: "👥",
                     desc: "기본 — 플랜·컨디션 자동 선곡 그대로",
                     themes: [], lo: 0.00, hi: 1.00, ramp: 1.0),
        VenueContext(key: "openOffice", label: "여러 명 사무실", emoji: "🏢",
                     desc: "사람 많은 공간 — 튀지 않는 꾸준한 중속",
                     themes: ["office", "ship", "england"], lo: 0.25, hi: 0.70, ramp: 0.9),
        VenueContext(key: "nightOffice", label: "밤 10시 나 혼자", emoji: "🌙",
                     desc: "심야 사무실 독차지 — 차분하게 깊이",
                     themes: ["magic", "snow", "lounge"], lo: 0.15, hi: 0.60, ramp: 0.7),
        VenueContext(key: "dawnAlone", label: "새벽 4시 뜬눈 출근", emoji: "🌘",
                     desc: "잠 못 잔 새벽 — 몸을 흔들지 않는 저속",
                     themes: ["peace", "snow"], lo: 0.00, hi: 0.35, ramp: 0.4),
        VenueContext(key: "burnout", label: "컨디션 바닥", emoji: "🩹",
                     desc: "스트레스·불면·속·눈 — 빗소리로 회복 우선",
                     themes: ["heavy_rain", "peace"], lo: 0.00, hi: 0.25, ramp: 0.3),
        VenueContext(key: "deskNap", label: "12시 책상 낮잠", emoji: "😴",
                     desc: "밥 대신 쪽잠 — 재우는 최저속 앰비언트",
                     themes: ["heavy_rain", "peace", "snow"], lo: 0.00, hi: 0.20, ramp: 0.2),
        VenueContext(key: "postLunch", label: "12:30 식후 노곤", emoji: "🥱",
                     desc: "간단히 먹고 옴 — 쉬면서 천천히 시동",
                     themes: ["lounge", "return", "gold"], lo: 0.10, hi: 0.50, ramp: 0.6),
    ]

    static func by(key: String) -> VenueContext {
        all.first { $0.key == key } ?? all.first { $0.key == defaultKey } ?? all[0]
    }
}
