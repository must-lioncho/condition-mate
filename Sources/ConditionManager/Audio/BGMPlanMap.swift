import Foundation

// 전략3 · 플랜 맵 (pre-planned situational BGM).
//
// Instead of deciding "what should play right now" live, an upfront planning pass
// (run once with a high-tier model — the 관리자 AI) writes a PLAN MAP that assigns
// a themed track pool to each situation slot:
//
//   day band  : "mon".."sun" (개별 요일) | "weekday" (월–금) | "weekend" (토·일) | "all"
//               resolution priority: specific day > weekday/weekend band > all
//   time band : "HH:mm"–"HH:mm" local time; from > to wraps past midnight
//
// The app then only EXECUTES the plan: ConditionDirector narrows its candidate
// pool to the slot's theme folders (subfolders of the music root — office/, ship/,
// steel/, ...) and keeps its activity-adaptive BPM steering inside that pool.
// Planning is expensive and rare; execution is free and instant.
//
// The plan lives at ~/.condition-manager/bgm-plan.json (AppPaths.base) so the
// 관리자 AI edits DATA, not code. Safe write path: POST /api/bgm/plan (validated
// replace — same convention as goals: agents never write the file directly).
// A missing or unreadable file re-seeds the built-in default plan below.
final class BGMPlanMap {

    struct Slot: Codable {
        var days: String          // "mon".."sun" | "weekday" | "weekend" | "all"
        var from: String          // "HH:mm" inclusive
        var to: String            // "HH:mm" exclusive; from > to wraps past midnight
        var label: String         // situation name shown in UI/logs (e.g. "마감 스퍼트")
        var themes: [String]      // music-root subfolder names forming the candidate pool
        var opener: String?       // exact filename pinned as the slot's session opener
        var note: String?         // planner's intent, kept for the next planning pass
    }

    struct Plan: Codable {
        var version: Int
        var updatedAt: String
        var plannedBy: String
        var note: String?
        var slots: [Slot]
    }

    enum PlanError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let why) = self { return why }
            return nil
        }
    }

    private(set) var plan: Plan
    private let fileURL: URL

    init() {
        fileURL = AppPaths.base.appendingPathComponent("bgm-plan.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(Plan.self, from: data),
           (try? Self.validate(loaded)) != nil {
            plan = loaded
        } else {
            plan = Self.defaultPlan
            persist()   // seed the editable file so the planner AI has something to start from
        }
    }

    // Calendar.weekday (1=Sun ... 7=Sat) → plan day key.
    private static let dayKeys = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    static let validDays = Set(dayKeys + ["weekday", "weekend", "all"])

    // The slot governing `date` (default: now). A specific day ("wed") wins over its
    // band ("weekday"), which wins over "all"; within a pass, file order decides —
    // so the planner controls precedence by order.
    func slot(at date: Date = Date()) -> Slot? {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date)          // 1=Sun ... 7=Sat
        let dayKey = Self.dayKeys[weekday - 1]
        let band = (weekday == 1 || weekday == 7) ? "weekend" : "weekday"
        let minute = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        for pass in [dayKey, band, "all"] {
            if let hit = plan.slots.first(where: { $0.days == pass && Self.contains($0, minute: minute) }) {
                return hit
            }
        }
        return nil
    }

    // Validated replace — the POST /api/bgm/plan body lands here. Throws with a
    // human-readable reason so the caller can report exactly what to fix.
    @discardableResult
    func replace(jsonData: Data) throws -> Plan {
        let decoded: Plan
        do {
            decoded = try JSONDecoder().decode(Plan.self, from: jsonData)
        } catch {
            throw PlanError.invalid("plan JSON decode failed: \(error.localizedDescription)")
        }
        try Self.validate(decoded)
        plan = decoded
        persist()
        return decoded
    }

    // Compact JSON of the active plan, for GET /api/bgm/plan.
    func planJSON() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(plan) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Internals

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(plan) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func validate(_ p: Plan) throws {
        guard !p.slots.isEmpty else { throw PlanError.invalid("slots is empty") }
        for (i, s) in p.slots.enumerated() {
            guard validDays.contains(s.days) else {
                throw PlanError.invalid("slot \(i): days must be mon..sun|weekday|weekend|all (got \"\(s.days)\")")
            }
            guard minutes(s.from) != nil else { throw PlanError.invalid("slot \(i): bad from \"\(s.from)\"") }
            guard minutes(s.to) != nil else { throw PlanError.invalid("slot \(i): bad to \"\(s.to)\"") }
            guard !s.label.isEmpty else { throw PlanError.invalid("slot \(i): label is empty") }
            guard !s.themes.isEmpty else { throw PlanError.invalid("slot \(i) (\(s.label)): themes is empty") }
        }
    }

    private static func contains(_ s: Slot, minute m: Int) -> Bool {
        guard let f = minutes(s.from), let t = minutes(s.to) else { return false }
        if f == t { return true }                       // degenerate range = whole day
        return f < t ? (m >= f && m < t) : (m >= f || m < t)
    }

    private static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    // The seed plan (2026-07-08, per-day since v2). EVERY weekday has its own theme
    // arc so each day of the week sounds different — same time bands (아침 시동,
    // calm lunch, the proven office afternoon, an urgent 17–19시 마감 push, then a
    // post-dinner lounge that relieves stress without going slack), different
    // texture per day. Weekends swap to the expedition themes. The 오후 slot stays
    // office everywhere on purpose: it is the BPM-tagged set where the activity-
    // adaptive steering has real tempo range to work with.
    private static let defaultPlan = Plan(
        version: 2,
        updatedAt: "2026-07-08",
        plannedBy: "claude (전략3 사전 계획 · 요일별)",
        note: "요일별(월~금 개별 + 주말)×시간대 BGM 계획 맵. 우선순위: 요일(mon..sun) > 평일/주말 밴드 > all. 관리자 AI는 이 데이터만 갱신하면 된다 — POST /api/bgm/plan (검증 후 반영).",
        slots: [
            // ---- 월 · 출항의 날: 한 주를 항해의 시동으로 ----
            Slot(days: "mon", from: "05:00", to: "11:30", label: "월 아침 · 출항",
                 themes: ["ship"], opener: "The Age of Sail.mp3",
                 note: "한 주의 출항 — 항해를 시작하듯 가볍게 시동"),
            Slot(days: "mon", from: "11:30", to: "13:30", label: "월 점심 · 평온",
                 themes: ["peace"], opener: nil, note: "황금 들판의 느슨한 톤으로 잠시 내려놓기"),
            Slot(days: "mon", from: "13:30", to: "17:00", label: "월 오후 · 오피스",
                 themes: ["office"], opener: nil, note: "BPM 태깅 업무 세트 — 액티비티 적응의 본진"),
            Slot(days: "mon", from: "17:00", to: "19:00", label: "월 마감 · 신시대 스퍼트",
                 themes: ["challenge"], opener: "Rise of the New Era.mp3",
                 note: "긴박한 마감 — 신시대 개막의 추진력으로 몰아친다"),
            Slot(days: "mon", from: "19:00", to: "23:30", label: "월 저녁 · 설원 바람",
                 themes: ["snow", "peace"], opener: "Snowbound Haven.mp3",
                 note: "루즈 방지 — 설원의 상쾌한 바람으로 스트레스를 덜어낸다"),
            // ---- 화 · 초원의 날: 광활한 개방감으로 질주 ----
            Slot(days: "tue", from: "05:00", to: "11:30", label: "화 아침 · 초원 질주",
                 themes: ["mongolia"], opener: "Eternal Blue Sky.mp3",
                 note: "영원한 푸른 하늘 — 광활한 개방감으로 시동"),
            Slot(days: "tue", from: "11:30", to: "13:30", label: "화 점심 · 옥정원",
                 themes: ["china"], opener: nil, note: "옥의 정원에서 따뜻한 한숨 돌리기"),
            Slot(days: "tue", from: "13:30", to: "17:00", label: "화 오후 · 오피스",
                 themes: ["office"], opener: nil, note: "BPM 태깅 업무 세트 — 액티비티 적응의 본진"),
            Slot(days: "tue", from: "17:00", to: "19:00", label: "화 마감 · 제련 스퍼트",
                 themes: ["steel"], opener: "Forged in the Storm.mp3",
                 note: "긴박한 마감 — 폭풍 속 제련의 묵직한 추진력"),
            Slot(days: "tue", from: "19:00", to: "23:30", label: "화 저녁 · 귀로",
                 themes: ["peace", "return"], opener: nil,
                 note: "루즈 방지 — 차분한 귀로의 바람으로 마무리"),
            // ---- 수 · 대항해의 날: 주 중반 환기 ----
            Slot(days: "wed", from: "05:00", to: "11:30", label: "수 아침 · 대항해",
                 themes: ["england"], opener: "Viking Dawn.mp3",
                 note: "주 중반 환기 — 대항해 시대의 새벽으로 시동"),
            Slot(days: "wed", from: "11:30", to: "13:30", label: "수 점심 · 오아시스",
                 themes: ["desert"], opener: nil, note: "나일 바자르의 이국적 휴식"),
            Slot(days: "wed", from: "13:30", to: "17:00", label: "수 오후 · 오피스",
                 themes: ["office"], opener: nil, note: "BPM 태깅 업무 세트 — 액티비티 적응의 본진"),
            Slot(days: "wed", from: "17:00", to: "19:00", label: "수 마감 · 최후의 목표",
                 themes: ["last_goal"], opener: "Alexander the Great.mp3",
                 note: "긴박한 마감 — 대왕의 원정처럼 목표만 보고 돌진"),
            Slot(days: "wed", from: "19:00", to: "20:30", label: "수 저녁 · 귀환",
                 themes: ["return"], opener: nil,
                 note: "저녁 식사 시간 — 개선 행진으로 하루를 정리"),
            Slot(days: "wed", from: "20:30", to: "23:30", label: "수 밤 · 클럽 라운지",
                 themes: ["lounge"], opener: nil,
                 note: "저녁 먹고 온 이후 — 여유롭게 클럽 라운지에 온 느낌으로 이완"),
            // ---- 목 · 동방 집중의 날: 절제된 몰입 ----
            Slot(days: "thu", from: "05:00", to: "11:30", label: "목 아침 · 사무라이 집중",
                 themes: ["samurai"], opener: "Edo Town.mp3",
                 note: "대나무 숲의 절제된 긴장감으로 몰입 시동"),
            Slot(days: "thu", from: "11:30", to: "13:30", label: "목 점심 · 궁궐 산책",
                 themes: ["joseon"], opener: nil, note: "궁궐 담장을 걷는 여유"),
            Slot(days: "thu", from: "13:30", to: "17:00", label: "목 오후 · 오피스",
                 themes: ["office"], opener: nil, note: "BPM 태깅 업무 세트 — 액티비티 적응의 본진"),
            Slot(days: "thu", from: "17:00", to: "19:00", label: "목 마감 · 강철 스퍼트",
                 themes: ["steel", "challenge"], opener: "First Molten Steel.mp3",
                 note: "긴박한 마감 — 용융 강철의 열기로 몰아친다"),
            Slot(days: "thu", from: "19:00", to: "23:30", label: "목 저녁 · 정원",
                 themes: ["china", "peace"], opener: nil,
                 note: "루즈 방지 — 정원의 상쾌한 공기로 스트레스 해소"),
            // ---- 금 · 황금의 날: 마무리와 보상 ----
            Slot(days: "fri", from: "05:00", to: "11:30", label: "금 아침 · 황금길",
                 themes: ["gold"], opener: "The Golden Age.mp3",
                 note: "황금 금요일 — 한 주의 결실을 향해 시동"),
            Slot(days: "fri", from: "11:30", to: "13:30", label: "금 점심 · 설원",
                 themes: ["snow"], opener: nil, note: "시원한 설원 톤으로 오후 전 리프레시"),
            Slot(days: "fri", from: "13:30", to: "17:00", label: "금 오후 · 오피스",
                 themes: ["office"], opener: nil, note: "BPM 태깅 업무 세트 — 액티비티 적응의 본진"),
            Slot(days: "fri", from: "17:00", to: "19:00", label: "금 마감 · 마지막 수도",
                 themes: ["last_goal", "challenge"], opener: "The Last Capital.mp3",
                 note: "긴박한 주간 마감 — 마지막 수도 함락처럼 몰아붙인다"),
            Slot(days: "fri", from: "19:00", to: "23:30", label: "금 밤 · 클럽 라운지",
                 themes: ["lounge"], opener: nil,
                 note: "불금 — 한 주를 마치고 여유롭게 클럽 라운지에서 스트레스 해소"),
            // ---- 주말 ----
            Slot(days: "weekend", from: "05:00", to: "12:00", label: "주말 아침 · 초원",
                 themes: ["mongolia", "snow"], opener: "Eternal Blue Sky.mp3",
                 note: "평일과 다른 공기 — 광활한 초원의 개방감으로 시작"),
            Slot(days: "weekend", from: "12:00", to: "19:00", label: "주말 오후 · 원정",
                 themes: ["england", "fantagy", "magic", "gold", "china", "desert", "samurai", "joseon"],
                 opener: nil,
                 note: "테마 여행 — 주말에만 도는 원정 셋으로 기분 전환"),
            Slot(days: "weekend", from: "19:00", to: "23:30", label: "주말 밤 · 귀환",
                 themes: ["return", "peace"], opener: nil,
                 note: "원정에서 돌아와 차분하게 마무리"),
            // ---- 심야 (23:30~05:00): 요일별로 그날의 성격을 살린 몰입 테마 ----
            // 매일 같은 "고요한 밤"이 심심하다는 피드백 → 요일별로 분리. 화·수·목은
            // 자주 밤을 새므로 시네마틱하게 강조(별빛 초원 / 야간 항해 / 달빛 정원).
            // heavy_rain(폭우)은 스케줄에 없다 — 디렉터가 활동 저하 시 하루 1회 소환.
            Slot(days: "mon", from: "23:30", to: "05:00", label: "월 심야 · 정박한 항구",
                 themes: ["ship", "snow"], opener: nil,
                 note: "조용한 밤 항구 — 정박한 배와 설원의 고요로 마무리"),
            Slot(days: "tue", from: "23:30", to: "05:00", label: "화 심야 · 별빛 초원",
                 themes: ["mongolia", "snow"], opener: nil,
                 note: "밤을 새는 화요일 — 별빛 쏟아지는 광활한 초원의 몰입감"),
            Slot(days: "wed", from: "23:30", to: "05:00", label: "수 심야 · 야간 항해",
                 themes: ["england", "ship"], opener: nil,
                 note: "밤을 새는 수요일 — 밤바다를 가르는 야간 항해, 깊은 밤의 집중"),
            Slot(days: "thu", from: "23:30", to: "05:00", label: "목 심야 · 달빛 정원",
                 themes: ["joseon", "samurai"], opener: nil,
                 note: "밤을 새는 목요일 — 달빛 정원과 대나무 그림자 속 고요한 몰입"),
            Slot(days: "fri", from: "23:30", to: "05:00", label: "금 심야 · 애프터 라운지",
                 themes: ["lounge", "snow"], opener: nil,
                 note: "불금 애프터 — 클럽의 여운을 새벽 라운지로 잔잔하게"),
            Slot(days: "weekend", from: "23:30", to: "05:00", label: "주말 심야 · 밤의 여운",
                 themes: ["return", "peace"], opener: nil,
                 note: "주말 밤 — 개선의 여운과 평온으로 잔잔하게 마무리"),
        ]
    )
}
