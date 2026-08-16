import Foundation

// Slack 👀 번역 파이프라인의 자가 진단·자가 복구.
//
// 문제: 이 기능의 절반은 앱 밖 launchd 데몬(Daemon/slack-eyes-daemon.mjs)이다.
// 데몬이 죽거나, 네트워크가 slack.com API를 막거나, 토큰이 만료되면 페이지는
// 그냥 "조용히 안 늘어난다". 사용자는 밖에서 데몬이 어떤지 알 방법이 없고,
// 왜 안 되는지 모르는 기능은 결국 지워진다.
//
// 해결: 데몬이 30초마다 POST /api/slack/health로 살아있음 + 소켓·인증·네트워크
// 상태를 보고한다. 하트비트가 끊기면(90초) 앱이 스스로 launchctl kickstart로
// 되살리고(최대 3회), 그래도 안 되면 그때만 사용자에게 행동을 요청한다.
//
// 프로세스가 살아 있다고 수집이 되는 것은 아니다: WebSocket이 close 없이 죽으면
// 데몬은 socket:"connected"인 채 하트비트를 계속 보내고 이벤트만 0건이 된다
// (2026-08-16 실측 — 40분 동안 realtimeAt이 멈춰 있었고 kickstart 즉시 2건 회수).
// 그래서 "붙어 있다"는 보고를 믿지 않고 프레임 수신(frameAt)으로 판정한다.
//
// 표시 원칙 (no-user-facing-failure): 앱이 고칠 수 있는 동안에는 경고를 띄우지
// 않는다 — 조용히 재시작하고 상태 칩만 '재연결 중'(대기=보라)으로 둔다.
// 소켓만 죽은 degraded도 마찬가지다: 데몬이 스스로 재개통하는 동안, 그리고 앱이
// 대신 재시작하는 동안에는 칩만 보라색이고, 3회 재시작에도 이벤트가 안 오면 그때
// 안내로 승격된다.
// 사용자 행동이 반드시 필요한 상태에서만 안내를 띄운다:
//   blocked      네트워크·VPN이 슬랙 API를 막음 → 사용자가 망을 바꿔야 함
//   auth         토큰 만료·취소 → 사용자가 키체인에 재등록해야 함
//   stuck        3회 재시작에도 응답 없음 → 앱/기기 차원의 조치가 필요
//   notInstalled launchd에 데몬이 없음 → 설치가 필요
//
// 소유권: <data>/slack-translate/health.json 은 앱 소유(데몬은 HTTP로만 보고).
// 앱이 재시작해도 마지막 하트비트 시각을 잃지 않도록 디스크에 남긴다.
public enum SlackHealth {

    public static let label = "com.condition-manager.slack-eyes"

    // 데몬은 30초마다 보고한다 — 세 번 연속 놓치면 죽은 것으로 본다.
    private static let staleAfter = 90
    // 하트비트가 멀쩡해도 소켓만 조용히 죽을 수 있다 (half-open WebSocket — close가
    // 안 와서 데몬은 socket:'connected'인 채 이벤트만 0건). 데몬은 프레임을 10분
    // 이상 못 받으면 스스로 소켓을 다시 개통하고, 그때 오는 hello로 frameAt이
    // 갱신된다 — 조용한 워크스페이스에서도 마찬가지다. 따라서 frameAt이 데몬의
    // 상한(idleLimit)을 한참 넘겼다는 것은 "데몬의 자가 복구가 안 돌고 있다"는 뜻이고,
    // 그때는 앱이 프로세스를 갈아준다. 30분 catch-up보다 먼저 걸리도록 25분.
    private static let frameStaleAfter = 25 * 60
    // 자동 재시작 상한. 넘으면 멈추고 사용자에게 요청한다 (무한 kickstart 방지 —
    // 예: 하트비트를 모르는 구버전 데몬이 돌고 있으면 영원히 되살아나지 않는다).
    private static let maxKicks = 3

    // 재시작·복구 이벤트를 호스트 앱에 알리는 훅 (워커 상태 행·로그 연결).
    // 이 타깃은 앱 타입을 모른다 — 배선은 AppDelegate가 한다.
    public static var onEvent: ((_ why: String, _ effect: String, _ ok: Bool) -> Void)?

    static var file: URL { SlackTranslateStore.dir.appendingPathComponent("health.json") }
    // 수집 OFF 토글 (워커 상태 행의 꺼짐) — 데몬도 같은 파일을 폴링한다.
    static var disabledFlag: URL {
        SlackTranslateStore.dir.deletingLastPathComponent()
            .appendingPathComponent("slack-translate-disabled")
    }
    static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist").path
    }

    // 하트비트 + 워치독 상태는 서버 스레드(피드 폴링)와 타이머 스레드가 함께 만진다.
    private static let lock = NSLock()
    private static var beat: [String: Any] = [:]
    private static var loadedFromDisk = false
    private static var kicks = 0
    private static var lastKickAt: Date?
    private static var lastKickError = ""
    private static var launchdLoaded = true      // 워치독이 갱신 (기본 낙관 — 최초 판정 전 미설치로 보이지 않게)
    private static var launchdChecked = false
    private static var lastState = ""            // 상태 전환 감지 (로그 도배 방지)
    // 소켓 무응답(degraded) 전용 재시작 카운터. 하트비트는 계속 오므로 record()가
    // 리셋하는 kicks를 쓸 수 없다 — 그러면 60초마다 영원히 되살리게 된다.
    private static var frameKicks = 0
    private static var lastFrameSeen = 0
    private static var lastFrameKickAt: Date?

    // ----- 하트비트 수신 -----

    // POST /api/slack/health. 데몬이 보내는 부분 상태를 병합한다.
    // at은 데몬 시계가 아니라 앱 시계로 찍는다 — 시계가 어긋나도 나이 계산이 안전.
    @discardableResult
    public static func record(_ patch: [String: Any]) -> String {
        lock.lock()
        ensureLoaded()
        for (k, v) in patch { beat[k] = v }
        beat["at"] = Int(Date().timeIntervalSince1970)
        let snapshot = beat
        let hadKicked = kicks > 0
        kicks = 0                 // 살아 돌아왔다 → 자동 재시작 카운터 리셋
        lastKickError = ""
        lock.unlock()
        if hadKicked { onEvent?("자동 복구 성공", "데몬이 다시 응답합니다", true) }
        if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
            try? data.write(to: file, options: .atomic)
        }
        return "{\"ok\":true}"
    }

    private static func ensureLoaded() {
        if loadedFromDisk { return }
        loadedFromDisk = true
        if let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            beat = obj
        }
    }

    // ----- 상태 판정 -----

    public struct Status {
        public var state: String     // ok | connecting | restarting | degraded | blocked | auth | stuck | notInstalled | off
        public var title: String     // 상태 칩 문구
        public var detail: String    // 한 줄 설명
        public var advice: String    // 사용자가 할 일 (needsUser일 때만 의미 있음)
        public var command: String   // 손으로 복구할 때 쓸 명령 (없으면 "")
        public var needsUser: Bool   // true일 때만 페이지가 안내를 띄운다
        public var ageSec: Int       // 마지막 하트비트 경과 (-1 = 한 번도 못 받음)
    }

    public static func status(now: Date = Date()) -> Status {
        lock.lock()
        ensureLoaded()
        let b = beat
        let kickCount = kicks
        let frameKickCount = frameKicks
        let kickErr = lastKickError
        let installed = !launchdChecked || launchdLoaded
        lock.unlock()

        if FileManager.default.fileExists(atPath: disabledFlag.path) {
            return Status(state: "off", title: "수집 꺼짐",
                          detail: "이 기능을 꺼 둔 상태입니다 — 슬랙에서 리액션을 달아도 수집하지 않습니다.",
                          advice: "", command: "", needsUser: false, ageSec: -1)
        }

        let at = b["at"] as? Int ?? 0
        let age = at == 0 ? -1 : max(0, Int(now.timeIntervalSince1970) - at)
        let alive = age >= 0 && age <= staleAfter
        let socket = b["socket"] as? String ?? ""
        let authErr = (b["authError"] as? String) ?? ""
        let netErr = (b["netError"] as? String) ?? ""
        let fails = (b["failures"] as? Int) ?? 0

        // 토큰 문제는 하트비트가 끊긴 뒤에도 유효한 진단이다 — 데몬은 토큰이 없거나
        // 거부당하면 그 사실을 남기고 죽는다(exit 78). 재시작으로는 절대 낫지 않으므로
        // 신선도와 무관하게 사용자에게 토큰 갱신을 요청한다.
        if !authErr.isEmpty && socket != "connected" {
            return Status(state: "auth", title: "슬랙 토큰 문제",
                          detail: "슬랙이 토큰을 거부했습니다 (\(authErr)).",
                          advice: "슬랙 앱에서 토큰을 다시 발급한 뒤 키체인 항목 "
                                + "cm-slack-user-token(xoxp-) / cm-slack-app-token(xapp-)을 "
                                + "갱신해 주세요. 갱신 후 다시 연결을 누르면 바로 붙습니다.",
                          command: "security add-generic-password -U -s cm-slack-user-token -a slack -w",
                          needsUser: true, ageSec: age)
        }

        if alive {
            // 데몬이 조용히 죽은 소켓을 감지하고 다시 개통하는 중 — 자가 복구다.
            if socket == "stale" { return degraded(age: age, frameAge: frameAge(b, now), kicked: 0) }
            if socket == "connected" {
                // 붙어 있다는 보고만으로는 부족하다 — 프레임이 실제로 오고 있어야 한다.
                // 정상 데몬은 조용해도 10분마다 소켓을 다시 개통해 hello를 받으므로
                // frameAt이 25분을 넘겼다면 데몬의 자가 복구 자체가 안 돌고 있는 것이다.
                let fAge = frameAge(b, now)
                if fAge > frameStaleAfter {
                    return degraded(age: age, frameAge: fAge, kicked: frameKickCount)
                }
                return Status(state: "ok", title: "연결됨",
                              detail: "슬랙 실시간 수신 중입니다.",
                              advice: "", command: "", needsUser: false, ageSec: age)
            }
            // 연결이 안 붙는 중 — 두 번 이상 연속 실패해야 '차단'으로 단정한다
            // (한두 번은 흔한 일시적 끊김이라 조용히 재시도에 맡긴다).
            if fails >= 2 && !netErr.isEmpty {
                return Status(state: "blocked", title: "슬랙 접속 차단됨",
                              detail: "데몬은 살아 있지만 slack.com API에 닿지 못합니다 (\(netErr)).",
                              advice: "회사 네트워크·VPN·방화벽이 슬랙 API를 막고 있을 수 있습니다. "
                                    + "VPN을 켜거나(또는 끄고) 다른 네트워크로 바꾼 뒤 다시 연결을 눌러 주세요.",
                              command: "curl -sS -o /dev/null -w '%{http_code}\\n' https://slack.com/api/api.test",
                              needsUser: true, ageSec: age)
            }
            return Status(state: "connecting", title: "연결 중",
                          detail: "슬랙 소켓을 다시 붙이는 중입니다.",
                          advice: "", command: "", needsUser: false, ageSec: age)
        }

        // 하트비트가 끊겼다 (또는 한 번도 없었다).
        if !installed {
            let script = (b["script"] as? String) ?? ""
            return Status(state: "notInstalled", title: "데몬 미설치",
                          detail: "슬랙 수집 데몬이 launchd에 등록돼 있지 않습니다 — 아무것도 수집되지 않습니다.",
                          advice: "아래 명령으로 데몬을 등록해 주세요. 등록하면 앱이 이후 자동으로 관리합니다."
                                + (script.isEmpty ? "" : "\n데몬 스크립트: \(script)"),
                          command: "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/\(label).plist",
                          needsUser: true, ageSec: age)
        }
        if kickCount >= maxKicks {
            let why = kickErr.isEmpty ? "" : " (\(kickErr))"
            return Status(state: "stuck", title: "자동 복구 실패",
                          detail: "데몬을 \(maxKicks)회 다시 시작했지만 응답이 없습니다\(why).",
                          advice: "데몬 프로세스가 뜨지 못하는 상태입니다. 아래 명령을 실행하거나, "
                                + "앱을 완전히 종료했다가 다시 실행해 주세요. 그래도 안 되면 "
                                + "/tmp/cm-slack-eyes.err.log 를 확인해 주세요.",
                          command: "launchctl kickstart -k gui/$(id -u)/\(label)",
                          needsUser: true, ageSec: age)
        }
        return Status(state: "restarting", title: "재연결 중",
                      detail: age < 0 ? "데몬 응답을 기다리는 중입니다."
                                      : "데몬이 \(age)초째 응답하지 않아 자동으로 다시 시작하는 중입니다.",
                      advice: "", command: "", needsUser: false, ageSec: age)
    }

    // 마지막 프레임 수신 경과. -1 = 이 데몬은 프레임을 보고하지 않는다(구버전) —
    // 판정 근거가 없으므로 절대 degraded로 몰지 않는다.
    private static func frameAge(_ b: [String: Any], _ now: Date) -> Int {
        let frameAt = b["frameAt"] as? Int ?? 0
        return frameAt == 0 ? -1 : max(0, Int(now.timeIntervalSince1970) - frameAt)
    }

    // 소켓이 조용히 죽은 상태. 앱·데몬이 아직 스스로 고치는 중이면 안내를 띄우지
    // 않는다 (no-user-facing-failure) — 재시작 상한까지 갔을 때만 사용자를 부른다.
    private static func degraded(age: Int, frameAge: Int, kicked: Int) -> Status {
        let howLong = frameAge < 0 ? "" : " (\(frameAge / 60)분째)"
        if kicked >= maxKicks {
            return Status(state: "degraded", title: "슬랙 실시간 수신 끊김",
                          detail: "데몬은 응답하지만 슬랙에서 아무 이벤트도 오지 않습니다\(howLong). "
                                + "\(maxKicks)회 다시 시작해도 회복되지 않았습니다.",
                          advice: "슬랙 연결이 앱 밖에서 막혀 있을 수 있습니다. 네트워크·VPN을 바꿔 보시고, "
                                + "그래도 같으면 api.slack.com 앱 설정에서 Socket Mode와 Event Subscriptions가 "
                                + "켜져 있는지 확인해 주세요. 그동안에도 폴링으로 몇 분 늦게 수집은 됩니다.",
                          command: "launchctl kickstart -k gui/$(id -u)/\(label)",
                          needsUser: true, ageSec: age)
        }
        return Status(state: "degraded", title: "재연결 중",
                      detail: "슬랙 실시간 수신이 조용히 끊겨\(howLong) 연결을 다시 여는 중입니다 "
                            + "— 그동안 놓친 항목은 자동으로 메웁니다.",
                      advice: "", command: "", needsUser: false, ageSec: age)
    }

    // 피드(GET /api/slack/items)에 실리는 상태 블록. 5초마다 호출되므로
    // 여기서는 프로세스를 절대 띄우지 않는다 — launchctl은 워치독만 부른다.
    public static func statusJSON() -> String {
        let s = status()
        lock.lock()
        let socket = (beat["socket"] as? String) ?? ""
        let since = (beat["startedAt"] as? Int) ?? 0
        let kickCount = kicks
        // 알림 수집 경로 — 데몬이 하트비트에 실어 보내는 값 그대로. realtimeAt이 0이면
        // message 이벤트를 한 번도 못 받았다는 뜻 = 슬랙 앱에 Event Subscriptions가
        // 없어 폴링만으로 돌고 있는 상태. 페이지가 이 둘을 구분해 안내한다.
        let realtimeAt = (beat["realtimeAt"] as? Int) ?? 0
        // frameAt = 소켓에서 마지막으로 프레임을 받은 시각. 페이지는 이것으로
        // "실시간 수신 중"과 "붙어 있다고만 보고되는 중"을 구분한다.
        let frameAt = (beat["frameAt"] as? Int) ?? 0
        let rotations = (beat["rotations"] as? Int) ?? 0
        let pollAt = (beat["pollAt"] as? Int) ?? 0
        let pollConvs = (beat["pollConvs"] as? Int) ?? 0
        let pollLimited = (beat["pollLimited"] as? Bool) ?? false
        let pollError = (beat["pollError"] as? String) ?? ""
        lock.unlock()
        var out = "{\"state\":\(j(s.state)),\"title\":\(j(s.title))"
        out += ",\"detail\":\(j(s.detail)),\"advice\":\(j(s.advice))"
        out += ",\"command\":\(j(s.command)),\"needsUser\":\(s.needsUser)"
        out += ",\"ageSec\":\(s.ageSec),\"socket\":\(j(socket))"
        out += ",\"startedAt\":\(since),\"kicks\":\(kickCount)"
        out += ",\"realtimeAt\":\(realtimeAt),\"frameAt\":\(frameAt)"
        out += ",\"rotations\":\(rotations),\"pollAt\":\(pollAt)"
        out += ",\"pollConvs\":\(pollConvs),\"pollLimited\":\(pollLimited)"
        out += ",\"pollError\":\(j(pollError))}"
        return out
    }

    // ----- 자가 복구 -----

    // 30초마다 앱 타이머가 부른다. 하트비트가 신선한 평상시에는 파일 조회 한 번으로
    // 끝나고, 끊겼을 때만 launchctl을 부른다.
    public static func watchdogTick() {
        if FileManager.default.fileExists(atPath: disabledFlag.path) {
            lock.lock(); kicks = 0; lastKickAt = nil; lastState = "off"; lock.unlock()
            return
        }
        reportStateChange()
        lock.lock()
        ensureLoaded()
        let at = beat["at"] as? Int ?? 0
        let authErr = (beat["authError"] as? String) ?? ""
        let kickCount = kicks
        let last = lastKickAt
        // 프레임이 실제로 갱신됐으면 소켓은 살아 돌아온 것 — 재시작 카운터를 푼다.
        let frameAt = beat["frameAt"] as? Int ?? 0
        if frameAt > lastFrameSeen {
            lastFrameSeen = frameAt
            frameKicks = 0
        }
        lock.unlock()
        let age = at == 0 ? Int.max : Int(Date().timeIntervalSince1970) - at
        // 하트비트는 멀쩡한데 소켓만 죽은 경우 — 데몬 스스로 못 고쳤다는 뜻이므로
        // (정상 데몬은 10분마다 소켓을 다시 열어 frameAt을 갱신한다) 프로세스를 갈아준다.
        if age <= staleAfter {
            if authErr.isEmpty, status().state == "degraded" { kickForFrames() }
            return
        }
        // 토큰 문제로 죽은 데몬은 되살려도 같은 이유로 즉시 죽는다 — 사용자에게 맡긴다.
        if !authErr.isEmpty { return }

        refreshLaunchd()
        lock.lock(); let installed = launchdLoaded; lock.unlock()
        if !installed {
            // 언로드됐을 뿐 plist는 남아 있는 흔한 경우 — 조용히 다시 올린다.
            guard FileManager.default.fileExists(atPath: plistPath) else { return }
            let r = launchctl(["bootstrap", "gui/\(getuid())", plistPath])
            onEvent?("데몬 미등록 감지", r.code == 0 ? "launchd에 다시 등록했습니다" : "재등록 실패: \(r.out)",
                     r.code == 0)
            return
        }
        if kickCount >= maxKicks { return }                       // 사용자에게 넘어간 상태
        if let last = last, Date().timeIntervalSince(last) < 60 { return }  // 올라올 시간을 준다
        kick(reason: "하트비트 \(age)초 끊김")
    }

    // 소켓 무응답 전용 재시작. 하트비트 끊김(kick)과 카운터를 나눠 쓴다 — 하트비트는
    // 계속 오고 있어 record()가 kicks를 매번 0으로 되돌리기 때문이다. 상한에 닿으면
    // 멈추고 status()가 그때부터 사용자를 부른다.
    private static func kickForFrames() {
        lock.lock()
        let n = frameKicks
        let last = lastFrameKickAt
        lock.unlock()
        if n >= maxKicks { return }
        // 데몬이 다시 붙어 프레임이 올라올 시간을 준다 (데몬 자체 재개통 주기와 무관하게).
        if let last = last, Date().timeIntervalSince(last) < 120 { return }
        lock.lock(); frameKicks += 1; lastFrameKickAt = Date(); lock.unlock()
        kick(reason: "슬랙 실시간 수신 끊김")
        // 하트비트는 끊긴 적이 없다 — kick()이 올린 카운터를 되돌려, 다음 하트비트가
        // '자동 복구 성공'으로 오해되지 않게 한다 (그건 소켓이 아니라 프로세스 얘기다).
        lock.lock(); kicks = 0; lock.unlock()
    }

    // 상태가 실제로 바뀔 때만 워커 상태 행·로그에 남긴다 (30초 주기로 같은 줄을
    // 반복하면 로그가 도배되고, 정작 전환 순간이 묻힌다).
    private static func reportStateChange() {
        let s = status()
        lock.lock()
        let prev = lastState
        lastState = s.state
        lock.unlock()
        guard prev != s.state, !prev.isEmpty || s.needsUser else { return }
        if s.needsUser {
            onEvent?(s.title, s.detail, false)
        } else if s.state == "ok" {
            onEvent?("연결 정상", "슬랙 실시간 수신 중", true)
        } else if s.state == "degraded" {
            // 조용한 자가 복구지만 흔적은 남긴다 — "그때 왜 안 떴나"를 나중에 볼 수 있게.
            onEvent?("슬랙 실시간 수신 끊김", "소켓을 다시 여는 중입니다", true)
        }
    }

    // 사용자가 '다시 연결'을 눌렀을 때. 자동 시도 카운터를 초기화하고 한 번 더 간다.
    public static func restartNow() -> String {
        lock.lock()
        kicks = 0; lastKickAt = nil; lastKickError = ""
        frameKicks = 0; lastFrameKickAt = nil
        lock.unlock()
        let ok = kick(reason: "사용자 요청")
        return "{\"ok\":\(ok)}"
    }

    @discardableResult
    private static func kick(reason: String) -> Bool {
        lock.lock(); kicks += 1; lastKickAt = Date(); let n = kicks; lock.unlock()
        let t0 = DispatchTime.now()
        var r = launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
        // 서비스가 아예 없으면(언로드) 등록부터 한 번 시도한다.
        if r.code != 0, FileManager.default.fileExists(atPath: plistPath) {
            r = launchctl(["bootstrap", "gui/\(getuid())", plistPath])
        }
        let ok = r.code == 0
        let err = ok ? "" : r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); lastKickError = err; lock.unlock()
        SlackActionLog.log("daemon.restart", ok: ok, ms: SlackTranslateStore.ms(since: t0),
                           error: err, detail: "\(reason) · \(n)/\(maxKicks)회")
        onEvent?("데몬 무응답 — \(reason)",
                 ok ? "자동으로 다시 시작했습니다 (\(n)/\(maxKicks))" : "재시작 실패: \(err)", ok)
        return ok
    }

    // launchd 등록 여부. 프로세스를 띄우므로 워치독에서만 부른다.
    private static func refreshLaunchd() {
        let r = launchctl(["print", "gui/\(getuid())/\(label)"])
        lock.lock()
        launchdLoaded = (r.code == 0)
        launchdChecked = true
        lock.unlock()
    }

    private static func launchctl(_ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "launchctl을 실행할 수 없습니다") }
        // waitUntilExit 전에 읽어야 파이프가 가득 차 교착되지 않는다.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // print 출력은 수 KB — 오류 메시지로 쓸 앞부분만 남긴다.
        let out = String(decoding: data.prefix(400), as: UTF8.self)
        return (p.terminationStatus, out)
    }

    private static func j(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += " " } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
        return out
    }
}
