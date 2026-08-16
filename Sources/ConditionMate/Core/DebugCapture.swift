import Foundation

// 디버그 모드(버그 수집) — 메뉴바 위젯의 한 스위치로 켜고 끄는 "전부 기록" 모드.
//
// WHY: 평소 로그는 의도적으로 성기다. ActionLog는 POST /api/* 만(메모 본문·CLI 타건은
// 제외), ViewTrace는 0.5초 화면 스냅샷만, ActivityMonitor는 키를 '세는' 것뿐 어떤 키였는지는
// 남기지 않는다. 그래서 "아까 그거 눌렀는데 이상했다" 류의 제보는 재현이 불가능했다.
// 디버그 모드가 켜져 있는 동안에만 그 빈칸(어떤 키·어디를 클릭·콘솔·네트워크·GET까지)을
// 전부 한 파일에 모아, 끄는 순간 버그 리포트 goal 하나로 묶어 넘긴다.
//
// 켜져 있지 않으면 비용은 0에 수렴한다: 훅들은 isOn(NSLock 보호 Bool) 하나만 읽고 즉시
// 빠져나온다. 켜져 있을 때만 events/debug-capture/<id>/capture.jsonl 로 한 줄씩 쌓인다.
//
// 수집 범위(의도적 경계):
//   • 앱 웹뷰 안의 키 입력 — 실제 키 이름까지. 단 input[type=password]는 마스킹된다.
//   • 앱 자신의 창으로 들어온 네이티브 키 이벤트(로컬 모니터) — IME 이전 원본 키.
//   • 다른 앱에서 친 키는 절대 기록하지 않는다. ActivityMonitor의 전역 모니터는 지금도
//     '개수'만 세며, 디버그 모드도 그 경계를 넘지 않는다(= 시스템 키로거가 아니다).
//   • 클릭/포커스 대상(선택자·라벨), input은 길이만(내용 아님), 콘솔, fetch/XHR,
//     그리고 서버가 받은 모든 HTTP 요청(GET 포함).
//
// 파일은 40MB에서 멈춘다(truncated 표시). 끌 때는 3초의 유예(drain) 후 번들을 만든다 —
// 웹뷰의 캡처 배치가 2초 주기로 올라오므로, 마지막 배치가 도착할 시간을 주기 위한 것.
final class DebugCapture {

    static let shared = DebugCapture()

    // 끄기 완료 후 AppDelegate가 버그 리포트 goal을 만들 때 쓰는 요약.
    struct Report {
        var id = ""
        var dir = URL(fileURLWithPath: "/")
        var startedAt = Date()
        var endedAt = Date()
        var events = 0
        var bytes = 0
        var truncated = false
        var minutes: Int { max(0, Int(endedAt.timeIntervalSince(startedAt) / 60)) }
        var seconds: Int { max(0, Int(endedAt.timeIntervalSince(startedAt))) }
        // 사람이 실제로 한 조작의 수(키·클릭·입력·네이티브 키). 0이면 이 구간에는 아무 일도
        // 일어나지 않았다는 뜻이라 리포트를 만들 이유가 없다.
        var userActions = 0
        var videoPath = ""          // screen.mp4 (녹화가 남았을 때만)
        var videoNote = ""          // 무엇으로 녹화했는지 / 왜 못 했는지
        var summary = ""            // 결정적 요약(마지막 조작·화면·에러) — 리포트 본문에 그대로 들어간다
    }

    // 앱 창 스냅샷 공급자(AppDelegate가 배선). 끄는 순간의 화면을 번들에 한 장 넣는다.
    var screenshotProvider: (() -> Data?)?
    // 번들 meta에 넣을 앱 상태 한 줄 요약(AppDelegate가 배선).
    var contextProvider: (() -> [String: String])?

    private let lock = NSLock()
    private var _on = false
    private var _draining = false          // stop() 유예 구간: 여전히 append를 받는다
    private var _id = ""
    private var _startedAt: Date?
    private var _events = 0
    private var _bytes = 0
    private var _dropped = 0
    private var _truncated = false

    // 반복 요청 접기: key -> (마지막으로 남긴 시각, 그 뒤로 접힌 횟수).
    private var _httpSeen: [String: (at: Date, skipped: Int)] = [:]

    private let recorder = WindowRecorder()
    private let queue = DispatchQueue(label: "cm.debugcapture", qos: .utility)
    private static let maxBytes = 40 * 1024 * 1024
    private static let drainSeconds: TimeInterval = 3.0
    private static let collapseSeconds: TimeInterval = 5

    private init() {}

    // MARK: - State

    /// 훅들이 매 이벤트마다 읽는 게이트. 꺼져 있으면 여기서 끝난다.
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return _on || _draining }

    /// 메뉴/엔드포인트에 보여줄 현재 상태.
    func status() -> (on: Bool, id: String, startedAt: Date?, events: Int, bytes: Int, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_on, _id, _startedAt, _events, _bytes, _truncated)
    }

    /// 메뉴 부제목용 짧은 라벨 — "12분 · 1,204건".
    func shortLabel() -> String {
        let s = status()
        guard let started = s.startedAt else { return "" }
        let mins = max(0, Int(Date().timeIntervalSince(started) / 60))
        return "\(mins)분 · \(s.events)건" + (s.truncated ? " · 상한 도달" : "")
    }

    static var root: URL {
        AppPaths.sub("events").appendingPathComponent("debug-capture", isDirectory: true)
    }

    func sessionDir(_ id: String) -> URL {
        Self.root.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Start / stop

    /// 수집 시작. 이미 켜져 있으면 기존 세션 id를 그대로 돌려준다.
    @discardableResult
    func start(reason: String) -> String {
        lock.lock()
        if _on { let id = _id; lock.unlock(); return id }
        let id = Self.stamp(Date())
        _on = true
        _draining = false
        _id = id
        _startedAt = Date()
        _events = 0
        _bytes = 0
        _dropped = 0
        _truncated = false
        _httpSeen.removeAll()
        lock.unlock()

        let dir = sessionDir(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        append(kind: "capture", fields: ["note": "start", "reason": reason])
        // 화면 녹화도 같이 시작한다 — 로그가 말해주지 못하는 "그때 화면이 어땠나"를 담는 유일한 수단.
        recorder.start(to: dir.appendingPathComponent("screen.mp4"), fallbackFrame: screenshotProvider)
        AppLog.log("debug-capture start id=\(id) reason=\(reason)")
        return id
    }

    /// 수집 종료 → 유예(drain) 후 번들을 만들고 요약을 메인 스레드로 돌려준다.
    /// 켜져 있지 않았다면 completion(nil).
    func stop(reason: String, completion: @escaping (Report?) -> Void) {
        lock.lock()
        guard _on else { lock.unlock(); DispatchQueue.main.async { completion(nil) }; return }
        _on = false
        _draining = true       // 웹뷰의 마지막 배치가 도착할 시간을 준다
        let id = _id
        let started = _startedAt ?? Date()
        lock.unlock()

        append(kind: "capture", fields: ["note": "stop", "reason": reason])
        queue.asyncAfter(deadline: .now() + Self.drainSeconds) { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(nil) }; return }
            // 영상 파일을 먼저 닫고(최대 8초) 번들을 만든다 — 리포트가 존재하지 않는 파일을
            // 가리키는 일이 없도록.
            let sema = DispatchSemaphore(value: 0)
            self.recorder.stop { sema.signal() }
            _ = sema.wait(timeout: .now() + 8)

            self.lock.lock()
            self._draining = false
            let events = self._events, bytes = self._bytes, truncated = self._truncated
            self.lock.unlock()

            var report = Report(id: id, dir: self.sessionDir(id), startedAt: started,
                                endedAt: Date(), events: events, bytes: bytes, truncated: truncated)
            report.videoNote = self.recorder.startNote
            self.buildBundle(&report)
            AppLog.log("debug-capture stop id=\(id) events=\(events) actions=\(report.userActions) dir=\(report.dir.path)")
            DispatchQueue.main.async { completion(report) }
        }
    }

    // MARK: - Append paths

    /// 네이티브 쪽 한 건. 꺼져 있으면 즉시 반환.
    func append(kind: String, fields: [String: Any]) {
        guard isOn else { return }
        var line = "{\"t\":\(Int64(Date().timeIntervalSince1970 * 1000)),\"src\":\"native\",\"k\":\(js(kind))"
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            if let s = v as? String { line += ",\(js(k)):\(js(String(s.prefix(400))))" }
            else if let b = v as? Bool { line += ",\(js(k)):\(b)" }
            else if let n = v as? Int { line += ",\(js(k)):\(n)" }
            else if let d = v as? Double { line += ",\(js(k)):\(Int(d))" }
        }
        line += "}\n"
        write(line, count: 1)
    }

    /// 앱 자신의 창으로 들어온 네이티브 키 이벤트(로컬 모니터 전용).
    /// 다른 앱의 키는 여기 오지 않는다 — 전역 모니터는 개수만 센다.
    func nativeKey(keyCode: Int, chars: String, modifiers: String, window: String) {
        guard isOn else { return }
        append(kind: "nkey", fields: [
            "code": keyCode, "chars": String(chars.prefix(12)),
            "mod": modifiers, "win": window
        ])
    }

    /// 서버가 받은 모든 HTTP 요청(GET 포함) — 액션 로그가 보지 못하는 절반.
    ///
    /// 같은 요청이 5초 안에 반복되면 한 줄로 접는다("skipped": 접힌 횟수). 대시보드는
    /// /live.json 을 250ms마다 폴링하므로 접지 않으면 캡처의 9할이 폴링 줄이 되고, 정작
    /// 읽어야 할 키·클릭이 파묻힌다. 접어도 종류별로 최소 5초에 한 줄은 남으므로
    /// "폴링이 멎었다"는 신호는 그대로 보인다.
    func http(method: String, path: String, ms: Int) {
        guard isOn else { return }
        // 수집 자신의 트래픽은 기록하지 않는다(무한 자기참조 방지).
        if path.hasPrefix("/api/debug/capture") || path.hasPrefix("/api/debug/view-trace") { return }
        let key = method + " " + path
        let now = Date()
        lock.lock()
        if let last = _httpSeen[key], now.timeIntervalSince(last.at) < Self.collapseSeconds {
            _httpSeen[key] = (last.at, last.skipped + 1)
            lock.unlock()
            return
        }
        let skipped = _httpSeen[key]?.skipped ?? 0
        _httpSeen[key] = (now, 0)
        if _httpSeen.count > 500 { _httpSeen.removeAll() }   // 경로가 무한히 늘어나는 것 방지
        lock.unlock()

        var fields: [String: Any] = ["m": method, "url": String(path.prefix(300)), "ms": ms]
        if skipped > 0 { fields["skipped"] = skipped }
        append(kind: "http", fields: fields)
    }

    /// POST /api/debug/capture — 주입된 웹뷰 스크립트가 보내는 배치.
    /// ViewTrace.appendBatch와 같은 원칙: 키 화이트리스트 + 길이 클램프로 재인코딩하며,
    /// 웹뷰가 보낸 문자열이 그대로 디스크에 쓰이는 경로는 없다.
    @discardableResult
    func appendBatch(_ body: String) -> Int {
        guard isOn else { return 0 }
        guard let data = body.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let events = obj["events"] as? [[String: Any]] else { return 0 }
        var out = ""
        var n = 0
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for e in events.prefix(400) {
            var t = (e["t"] as? NSNumber)?.int64Value ?? now
            if t < now - 3_600_000 || t > now + 60_000 { t = now }
            let k = (e["k"] as? String).map { String($0.prefix(16)) } ?? "ev"
            var line = "{\"t\":\(t),\"src\":\"js\",\"k\":\(js(k))"
            for key in ["key", "code", "mod", "tgt", "text", "note", "msg", "lvl", "m", "url", "page", "view"] {
                if let v = e[key] as? String, !v.isEmpty {
                    line += ",\(js(key)):\(js(String(v.prefix(300))))"
                }
            }
            for key in ["st", "ms", "len", "x", "y", "skipped"] {
                if let v = (e[key] as? NSNumber)?.intValue { line += ",\(js(key)):\(max(-1, min(v, 10_000_000)))" }
            }
            for key in ["ime", "pw"] {
                if let v = e[key] as? Bool, v { line += ",\(js(key)):true" }
            }
            line += "}\n"
            out += line
            n += 1
        }
        if n > 0 { write(out, count: n) }
        return n
    }

    // MARK: - File

    private func write(_ chunk: String, count: Int) {
        let bytes = chunk.utf8.count
        lock.lock()
        guard _on || _draining else { lock.unlock(); return }
        if _bytes + bytes > Self.maxBytes {
            if !_truncated { _truncated = true }
            _dropped += count
            lock.unlock()
            return
        }
        _bytes += bytes
        _events += count
        let id = _id
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let url = self.sessionDir(id).appendingPathComponent("capture.jsonl")
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let d = chunk.data(using: .utf8) { handle.write(d) }
                try? handle.close()
            }
        }
    }

    // MARK: - Bundle (끌 때 한 번)

    // 캡처 구간에 해당하는 다른 로그들을 같은 폴더로 잘라 담고, 사람이 읽는 report.md와
    // 기계가 읽는 meta.json을 쓴다. 실패해도 조용히 넘어간다(수집 자체는 이미 끝났다).
    private func buildBundle(_ report: inout Report) {
        let dir = report.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fromMs = Int64(report.startedAt.timeIntervalSince1970 * 1000)
        let fromSec = Int64(report.startedAt.timeIntervalSince1970)

        // 캡처 구간의 액션로그 / 화면추적 — 시간(t)으로 걸러 담는다.
        sliceJSONL(AppPaths.sub("events").appendingPathComponent("actions.jsonl"),
                   into: dir.appendingPathComponent("actions.jsonl"), fromT: fromSec, maxLines: 4000)
        sliceJSONL(AppPaths.sub("events").appendingPathComponent("view-trace.jsonl"),
                   into: dir.appendingPathComponent("view-trace.jsonl"), fromT: fromMs, maxLines: 20000)
        // app.log 는 JSONL이 아니라 "2026-08-10 15:23:51.113 KST [pid …] …" 형식이므로 접두
        // 타임스탬프로 자른다. 예전엔 꼬리 3000줄을 그냥 담았는데, 그 대부분이 BGM audio-probe
        // 노이즈라 8초짜리 캡처의 번들이 1.6MB가 됐고 리포트를 읽는 쪽이 거기서 막혔다.
        sliceAppLog(AppPaths.base.appendingPathComponent("app.log"),
                    into: dir.appendingPathComponent("app.log"), from: report.startedAt)

        // 끄는 순간의 화면 한 장 (창이 닫혀 있으면 없음).
        if let png = screenshotProvider?() {
            try? png.write(to: dir.appendingPathComponent("screen.png"))
        }

        // 화면 녹화 결과 + 캡처 내용의 결정적 요약. 요약은 리포트 본문에 그대로 들어가므로
        // AI가 번들을 읽지 않아도 goal 하나만 보면 무슨 일이 있었는지 알 수 있어야 한다.
        let mp4 = dir.appendingPathComponent("screen.mp4")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: mp4.path),
           let size = (attrs[.size] as? NSNumber)?.intValue, size > 1024 {
            report.videoPath = mp4.path
        } else {
            try? FileManager.default.removeItem(at: mp4)   // 0바이트 껍데기는 남기지 않는다
        }
        let digest = summarize(dir.appendingPathComponent("capture.jsonl"))
        report.userActions = digest.actions
        report.summary = digest.text

        var ctx = contextProvider?() ?? [:]
        ctx["dataDir"] = AppPaths.base.path
        ctx["appVersion"] = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        ctx["build"] = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "-"
        ctx["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString

        var meta = "{\n  \"id\": \(js(report.id)),\n"
        meta += "  \"startedAt\": \(Int(report.startedAt.timeIntervalSince1970)),\n"
        meta += "  \"endedAt\": \(Int(report.endedAt.timeIntervalSince1970)),\n"
        meta += "  \"minutes\": \(report.minutes),\n"
        meta += "  \"events\": \(report.events),\n"
        meta += "  \"bytes\": \(report.bytes),\n"
        meta += "  \"truncated\": \(report.truncated),\n"
        meta += "  \"userActions\": \(report.userActions),\n"
        meta += "  \"video\": \(js(report.videoPath)),\n"
        meta += "  \"videoNote\": \(js(report.videoNote)),\n"
        meta += "  \"context\": {" + ctx.sorted(by: { $0.key < $1.key })
            .map { "\n    \(js($0.key)): \(js($0.value))" }.joined(separator: ",") + "\n  }\n}\n"
        try? meta.write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

        let videoLine = report.videoPath.isEmpty
            ? "- 화면 녹화: 없음 — \(report.videoNote.isEmpty ? "녹화하지 못했습니다" : report.videoNote)"
            : "- 화면 녹화: `\(report.videoPath)` (\(report.videoNote))"
        let md = """
        # 디버그 캡처 \(report.id)

        - 구간: \(Self.human(report.startedAt)) ~ \(Self.human(report.endedAt)) (\(report.minutes)분 \(report.seconds % 60)초)
        - 이벤트: \(report.events)건 · 사용자 조작 \(report.userActions)건\(report.truncated ? " (40MB 상한에 걸려 일부 잘림)" : "")
        \(videoLine)
        - 폴더: \(dir.path)

        ## 요약
        \(report.summary.isEmpty ? "(요약 없음)" : report.summary)

        ## 파일
        - `capture.jsonl` — 디버그 모드 구간의 전수 기록: 키 입력(앱 웹뷰/네이티브), 클릭·포커스,
          input 길이, 콘솔, fetch/XHR, 서버가 받은 모든 HTTP 요청(GET 포함).
        - `actions.jsonl` — 같은 구간의 액션 로그(도메인 축이 붙은 유저 액션 + BGM 반응).
        - `view-trace.jsonl` — 같은 구간의 0.5초 화면 추적(무엇을 보고 있었는지 · JS 에러).
        - `app.log` — 네이티브 앱 로그 꼬리.
        - `meta.json` — 앱 버전 · 데이터 디렉터리 · 캡처 당시 앱 상태.
        - `screen.png` — 끄는 순간의 앱 창(창이 열려 있었을 때만).
        - `screen.mp4` — 캡처 구간 내내의 앱 창 화면 녹화. **가장 먼저 이걸 보세요.**

        ## 읽는 순서
        1. `screen.mp4` — 그 구간에 화면에서 실제로 무슨 일이 있었는지.
        2. 위 요약의 마지막 조작 순서 — 그게 곧 재현 절차다.
        3. `capture.jsonl` 을 뒤에서부터 — 요약이 놓친 세부(수식키·대상 선택자·응답 코드).
        4. 같은 시각(t, epoch ms)의 `view-trace.jsonl` / `app.log` — 화면과 네이티브 쪽 사정.
        """
        try? md.write(to: dir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }

    // JSONL을 t >= fromT 인 줄만 복사한다. 파일 끝 4MB 창만 읽어 오래된 로그에서도 빠르다.
    private func sliceJSONL(_ src: URL, into dst: URL, fromT: Int64, maxLines: Int) {
        guard let handle = try? FileHandle(forReadingFrom: src) else { return }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let window: UInt64 = 8 * 1_048_576
        let start = size > window ? size - window : 0
        handle.seek(toFileOffset: start)
        guard var text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return }
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        var kept: [Substring] = []
        for line in text.split(separator: "\n") where line.hasPrefix("{") {
            // "t":<number> 를 앞에서 한 번만 읽는다(전체 JSON 파싱 없이).
            guard let r = line.range(of: "\"t\":") else { continue }
            let digits = line[r.upperBound...].prefix(while: { $0.isNumber })
            guard let t = Int64(digits), t >= fromT else { continue }
            kept.append(line)
        }
        let out = kept.suffix(maxLines).joined(separator: "\n") + "\n"
        try? out.write(to: dst, atomically: true, encoding: .utf8)
    }

    // app.log 를 캡처 시작 시각 이후로만 자른다. 줄 머리가 "yyyy-MM-dd HH:mm:ss.SSS <tz>" 라
    // 문자열 비교만으로 걸러진다(같은 포맷·같은 타임존이므로 사전순 = 시간순). 타임스탬프가
    // 없는 줄(스택 트레이스 등)은 직전 줄의 판정을 따른다.
    private func sliceAppLog(_ src: URL, into dst: URL, from: Date) {
        guard let handle = try? FileHandle(forReadingFrom: src) else { return }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let window: UInt64 = 8 * 1_048_576
        handle.seek(toFileOffset: size > window ? size - window : 0)
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = AppLog.logTimeZone
        let cutoff = f.string(from: from.addingTimeInterval(-1))
        var keep = false
        var out: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.count > 23, line.first?.isNumber == true {
                keep = String(line.prefix(23)) >= cutoff
            }
            if keep { out.append(line) }
        }
        try? (out.suffix(4000).joined(separator: "\n") + "\n")
            .write(to: dst, atomically: true, encoding: .utf8)
    }

    // capture.jsonl 을 읽어 사람이 바로 읽는 요약을 만든다: 실제 조작 수, 마지막 조작 20개,
    // 거쳐간 화면, 그리고 눈에 띄는 실패(콘솔 에러 · 200이 아닌 응답).
    //
    // WHY 결정적으로: 첫 자동 리포트는 빈 템플릿이었고, 그걸 받은 세션은 "복원해보겠다"만
    // 말하고 멈췄다. 요약이 앱에서 이미 완성돼 나오면 리포트는 AI가 살아있든 아니든 읽을 값이 된다.
    private func summarize(_ url: URL) -> (actions: Int, text: String) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return (0, "") }
        var actions: [String] = []
        var screens: [String] = []
        var fails: [String] = []
        var count = 0
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let k = o["k"] as? String else { continue }
            let page = (o["page"] as? String) ?? ""
            if !page.isEmpty, screens.last != page { screens.append(page) }
            let clock = Self.clock((o["t"] as? NSNumber)?.doubleValue ?? 0)
            switch k {
            case "key":
                count += 1
                let mod = (o["mod"] as? String) ?? ""
                actions.append("\(clock) 키 \(mod)\((o["key"] as? String) ?? "") → \((o["tgt"] as? String) ?? "")")
            case "nkey":
                count += 1
                actions.append("\(clock) 키(네이티브) \((o["mod"] as? String) ?? "")\((o["chars"] as? String) ?? "")")
            case "click":
                count += 1
                actions.append("\(clock) 클릭 \((o["tgt"] as? String) ?? "")")
            case "input":
                count += 1
                actions.append("\(clock) 입력 \((o["tgt"] as? String) ?? "") (\((o["len"] as? NSNumber)?.intValue ?? 0)자)")
            case "console":
                if (o["lvl"] as? String) == "error" {
                    fails.append("\(clock) 콘솔 에러 · \((o["msg"] as? String) ?? "")")
                }
            case "net", "http":
                let st = (o["st"] as? NSNumber)?.intValue ?? 200
                if st != 200 && st != 0 && st != 206 {
                    fails.append("\(clock) \((o["m"] as? String) ?? "") \((o["url"] as? String) ?? "") → \(st)")
                }
            default: break
            }
        }
        var out = ""
        if actions.isEmpty {
            out += "이 캡처 구간에는 **사용자 조작이 한 건도 없습니다** — 키·클릭·입력이 기록되지 않았습니다.\n"
            out += "(버그를 재현하기 *전에* 디버그 모드를 켜고, 재현한 *뒤에* 끄면 그 사이의 조작이 여기 남습니다.)\n"
        } else {
            out += "조작 \(count)건. 마지막 조작 순서:\n\n"
            out += actions.suffix(20).map { "1. " + $0 }.joined(separator: "\n") + "\n"
        }
        if !screens.isEmpty {
            out += "\n거쳐간 화면: " + screens.suffix(10).joined(separator: " → ") + "\n"
        }
        if !fails.isEmpty {
            out += "\n눈에 띈 실패:\n" + fails.suffix(10).map { "- " + $0 }.joined(separator: "\n") + "\n"
        }
        return (count, out)
    }

    private static func clock(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = Settings.shared.displayTimeZone
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    private func tail(_ src: URL, into dst: URL, lines: Int) {
        guard let handle = try? FileHandle(forReadingFrom: src) else { return }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let window: UInt64 = 4 * 1_048_576
        handle.seek(toFileOffset: size > window ? size - window : 0)
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return }
        let out = text.split(separator: "\n").suffix(lines).joined(separator: "\n") + "\n"
        try? out.write(to: dst, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = Settings.shared.displayTimeZone
        return f.string(from: d)
    }

    static func human(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        f.timeZone = Settings.shared.displayTimeZone
        return f.string(from: d)
    }

    func statusJSON() -> String {
        let s = status()
        let started = s.startedAt.map { Int($0.timeIntervalSince1970) } ?? 0
        return "{\"on\":\(s.on),\"id\":\(js(s.id)),\"startedAt\":\(started),"
            + "\"events\":\(s.events),\"bytes\":\(s.bytes),\"truncated\":\(s.truncated),"
            + "\"label\":\(js(shortLabel()))}"
    }

    private func js(_ s: String) -> String {
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
