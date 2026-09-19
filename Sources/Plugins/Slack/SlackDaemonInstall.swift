import Foundation

// 슬랙 데몬의 설치 소유권 — launchd plist를 앱이 직접 쓰고 유지한다.
//
// 왜 이게 필요했나 (2026-08-21 사고):
// 데몬은 앱 밖 launchd 프로세스지만 스크립트는 개발 작업트리를 직접 가리키고 있었다
//   ~/Work/.../projects/lion-condition-mate/Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs
// 즉 "운영 기능이 개발 폴더에서 돌고 있는" 상태였다. 레포를 org-lion/ 아래로 옮긴
// 순간 그 경로가 무효가 됐고 node는 MODULE_NOT_FOUND로 즉사했다. launchd는 job을
// 띄우는 데 성공했으므로 kickstart도 계속 0을 리턴했고, 앱은 "재시작했는데 응답이
// 없다"만 3회 반복하고 포기했다 — 19시간 무수집.
// 폴더 이동은 증상일 뿐이다. 브랜치 전환·stash·git clean·저장 한 번까지, 개발
// 행위 전부가 운영 데몬을 건드릴 수 있는 구조였다는 것이 원인이다.
//
// 해결: 앱과 똑같은 릴리스 경로를 태운다. Scripts/build-app.sh가 데몬을 번들
// Contents/Resources에 복사하고, 설치본(/Applications/ConditionMate.app)이 자기
// 번들 안의 데몬을 가리키도록 plist를 쓴다. 이 경로는 업데이트(apply-update.sh가
// 같은 자리에 번들을 갈아끼운다) 뒤에도 그대로다. 개발 트리를 어디로 옮기든,
// 무슨 브랜치에 있든 운영 데몬은 영향을 받지 않는다.
//
// 소유권 규칙: plist를 쓰는 것은 /Applications 설치본 하나뿐이다. 개발 실행
// (.build/ 바이너리)이나 레포 루트의 번들은 절대 건드리지 않는다 — 그러지 않으면
// 개발 빌드를 한 번 띄우는 것만으로 운영 데몬이 개발 트리로 끌려간다.
public enum SlackDaemonInstall {

    public static let label = "com.condition-mate.slack-eyes"

    // 설치본의 정식 위치. apply-update.sh가 번들을 갈아끼우는 바로 그 경로다.
    static let installedApp = "/Applications/ConditionMate.app"

    public struct Result {
        public var changed: Bool     // plist를 새로 썼는가
        public var ok: Bool          // 재등록까지 성공했는가
        public var detail: String    // 로그·워커 행에 남길 한 줄
    }

    // 이 프로세스가 plist를 소유하는가 = /Applications 설치본으로 실행 중인가.
    static var ownsPlist: Bool {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return false }
        return exe.hasPrefix(installedApp + "/")
    }

    // 설치본 번들 안의 데몬. 실행 중인 번들이 아니라 설치 경로를 기준으로 잡는다 —
    // 스테이징 번들에서 이 코드가 돌더라도 plist에는 언제나 최종 설치 경로가 박혀야
    // 한다 (스테이징 폴더는 적용 직후 삭제된다).
    static var installedScript: String {
        installedApp + "/Contents/Resources/slack-eyes-daemon.mjs"
    }

    static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist").path
    }

    // node 실행 파일. 여기도 절대 경로 하나를 박아두면 node를 옮기거나 버전 매니저를
    // 바꾸는 순간 같은 사고가 난다 — 후보를 훑어 실제로 존재하는 것을 고른다.
    // 현재 plist에 적힌 값이 아직 살아 있으면 그것을 우선한다 (사용자가 고른 런타임을
    // 앱이 마음대로 바꾸지 않는다).
    static func nodePath() -> String {
        let fm = FileManager.default
        if let cur = plistProgramArguments()?.first, fm.isExecutableFile(atPath: cur) { return cur }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/node",
            "\(home)/.hermes/node/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    // ----- plist 읽기 -----

    static func plistProgramArguments() -> [String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any],
              let args = dict["ProgramArguments"] as? [String], args.count >= 2
        else { return nil }
        return args
    }

    // plist가 가리키는 데몬 스크립트 경로 ("" = 읽을 수 없음).
    public static func currentScriptPath() -> String {
        plistProgramArguments().map { $0[1] } ?? ""
    }

    // 데몬이 실행될 수 없는 상태인가 = plist가 가리키는 파일이 실제로 없다.
    // kickstart로는 절대 낫지 않는 유일한 부류라, 워치독이 헛돌지 않도록 먼저 본다.
    public static func scriptMissing() -> Bool {
        let p = currentScriptPath()
        return !p.isEmpty && !FileManager.default.fileExists(atPath: p)
    }

    // ----- 설치·수리 -----

    // 앱 시작 때, 그리고 워치독이 경로 파손을 감지했을 때 부른다.
    // plist가 이미 올바르면 아무것도 하지 않는다 (파일 비교 한 번으로 끝).
    @discardableResult
    public static func ensureInstalled() -> Result {
        let fm = FileManager.default
        guard ownsPlist else {
            return Result(changed: false, ok: true, detail: "설치본이 아니라 plist를 건드리지 않습니다")
        }
        let script = installedScript
        guard fm.fileExists(atPath: script) else {
            // 데몬이 번들에 없다 = 이 수정 이전에 빌드된 앱. 기존 plist를 그대로 두는
            // 것이 안전하다 — 여기서 덮어쓰면 멀쩡히 돌던 개발트리 경로까지 날린다.
            return Result(changed: false, ok: true,
                          detail: "번들에 데몬이 없습니다 (구버전 빌드) — 기존 설정 유지")
        }
        let node = nodePath()
        let want = [node, script]
        if let cur = plistProgramArguments(), cur == want, fm.fileExists(atPath: plistPath) {
            // 경로는 맞다. 그런데 경로가 맞다는 것과 그 경로의 코드가 돌고 있다는 것은
            // 다르다 — 2026-08-31 에 정확히 여기서 갈렸다. 첫 설치 이후로는 언제나 이
            // 분기로 들어와 "이미 올바른 경로입니다" 로 끝났고, 번들의 데몬 파일을 새로
            // 갈아 끼워도 launchd 는 21시간 전 프로세스를 그대로 두었다. 슬랙에 나가는
            // 답은 계속 옛 코드의 것이었는데 화면에는 새 코드가 보였다.
            // 그래서 파일이 바뀌었으면 여기서 재시작한다.
            return kickstartIfCodeChanged(script: script)
        }
        let had = currentScriptPath()
        guard writePlist(node: node, script: script) else {
            return Result(changed: false, ok: false, detail: "plist를 쓸 수 없습니다: \(plistPath)")
        }
        // 경로가 바뀌었으면 등록을 갈아야 launchd가 새 경로로 띄운다 (bootout 실패는
        // 정상 — 애초에 안 올라와 있던 경우다).
        //
        // 여기서 실패하면 데몬이 내려간 채로 남는다 = 이 수정이 고치려던 바로 그 사고를
        // 우리 손으로 다시 만드는 것이다. bootout 직후에는 launchd가 아직 서비스를
        // 정리하는 중이라 bootstrap이 EBUSY로 튕기는 일이 흔하므로 몇 번 다시 시도하고,
        // 그래도 안 되면 kickstart로라도 띄운다.
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        var r = launchctl(["bootstrap", "gui/\(getuid())", plistPath])
        var tries = 0
        while r.code != 0 && tries < 4 {
            tries += 1
            Thread.sleep(forTimeInterval: 0.5)
            r = launchctl(["bootstrap", "gui/\(getuid())", plistPath])
        }
        if r.code != 0 {
            // 마지막 수단: 이미 등록돼 있는데 bootstrap이 중복이라 거절한 경우일 수 있다.
            let k = launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
            if k.code == 0 { r = k }
        }
        let ok = r.code == 0
        if ok { writeCodeStamp(script: script) }
        let from = had.isEmpty ? "(없음)" : had
        return Result(changed: true, ok: ok,
                      detail: ok ? "데몬 경로를 앱 번들로 고정했습니다: \(from) → \(script)"
                                 : "재등록 실패: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    // 마지막으로 재시작을 태운 데몬 코드의 mtime. 데몬 자신도 codeWatchdog 으로 같은
    // 드리프트를 보지만, 그쪽은 데몬이 살아 있을 때만 돈다 — 데몬이 죽어 있는 동안
    // 코드가 바뀌면 아무도 못 본다. 그래서 설치 쪽에도 같은 판정을 둔다.
    static var codeStampPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".condition-mate/slack-translate/daemon-code.stamp").path
    }

    static func scriptMtime(_ script: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: script)
        guard let d = attrs?[.modificationDate] as? Date else { return "" }
        return String(Int(d.timeIntervalSince1970))
    }

    @discardableResult
    static func writeCodeStamp(script: String) -> Bool {
        let stamp = scriptMtime(script)
        guard !stamp.isEmpty else { return false }
        let url = URL(fileURLWithPath: codeStampPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? stamp.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    static func kickstartIfCodeChanged(script: String) -> Result {
        let now = scriptMtime(script)
        let seen = (try? String(contentsOfFile: codeStampPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !now.isEmpty, now != seen else {
            return Result(changed: false, ok: true, detail: "이미 올바른 경로이고 코드도 최신입니다")
        }
        let k = launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
        let ok = k.code == 0
        if ok { writeCodeStamp(script: script) }
        return Result(changed: true, ok: ok,
                      detail: ok ? "데몬 코드가 바뀌어 재시작했습니다 (\(seem(seen)) → \(now))"
                                 : "코드가 바뀌었으나 재시작 실패: \(k.out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private static func seem(_ s: String) -> String { s.isEmpty ? "(기록없음)" : s }

    // plist 전문을 앱이 쓴다. 손으로 관리하던 파일을 앱 소유로 넘기는 것이므로
    // 주석 대신 코드가 유일한 출처가 된다 — 필드는 레포의 템플릿과 같은 뜻이다.
    private static func writePlist(node: String, script: String) -> Bool {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [node, script],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "EnvironmentVariables": [
                "PATH": "\((script as NSString).deletingLastPathComponent):"
                      + "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:"
                      + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            ],
            "StandardOutPath": "/tmp/cm-slack-eyes.out.log",
            "StandardErrorPath": "/tmp/cm-slack-eyes.err.log",
            "ProcessType": "Background",
        ]
        let url = URL(fileURLWithPath: plistPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                             format: .xml, options: 0)
        else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    private static func launchctl(_ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "launchctl을 실행할 수 없습니다") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data.prefix(400), as: UTF8.self))
    }
}
