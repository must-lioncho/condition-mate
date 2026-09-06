import AppKit
import Foundation

// 받아쓰기 감시 (superwhisper). "지금 마이크에 대고 말하는 중인가"를 알아내서 그동안 BGM 을
// 잠깐 눌러 두려고 만들었다. superwhisper 는 그 상태를 밖으로 내보내지 않으므로, 밖에서
// 관찰 가능한 두 신호를 겹쳐 쓴다.
//
//   1) 파일 신호 — 판정의 기준.
//      녹음이 시작되면 ~/Documents/superwhisper/recordings/<epoch>/ 폴더가 빈 채로 만들어지고,
//      전사가 끝나면 그 안에 output.wav + meta.json 이 채워진다. 취소하면 폴더가 통째로 지워진다.
//      즉 시작·성공·취소가 전부 이 폴더 하나의 생애로 드러난다. (누적 기록 2668건 중 빈 폴더가
//      단 하나도 남아있지 않은 것이 "취소면 지워진다"의 근거다 — 빈 채로 방치되는 경우가 없다.)
//      폴링이 아니라 커널이 알려주는 DispatchSource 라 평소 비용이 0 이다.
//
//   2) 키 신호 — 속도 보정.
//      오른쪽 ⌘ 는 superwhisper 의 toggleRecording 단축키다(carbonKeyCode 54). 폴더가 만들어질
//      때까지의 수백 ms 동안 음악이 그대로 흐르면 첫 한두 단어에 겹치므로, 키를 누른 즉시 먼저
//      눌러 둔다. 다만 이건 어디까지나 추측이라 confirmWindow 안에 폴더가 나타나지 않으면 스스로
//      풀린다 — superwhisper 와 무관하게 오른쪽 ⌘ 를 눌렀을 뿐인 경우가 그렇다.
//      전역 키 모니터라 접근성 권한이 있어야 동작한다. 없으면 조용히 안 오고, 그때는 1)만으로
//      돌아간다(수백 ms 늦을 뿐 기능은 그대로).
//
// 마이크 점유 여부(CoreAudio 의 DeviceIsRunningSomewhere)를 보는 방법은 여기선 쓸 수 없다.
// 카메라 지킴이가 카메라에 쓰는 바로 그 방식인데, 화상회의 앱(개더 등)이 마이크를 상시 잡고
// 있으면 입력 장치는 항상 "켜짐"이라 받아쓰기를 구분해 내지 못한다. 실제로 이 맥이 그 상태다.
final class VoiceDictationMonitor {

    // 상태가 바뀔 때만 main 에서 부른다(같은 값으로 두 번 부르지 않는다).
    var onChange: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var isDictating = false

    private static let bundleID = "com.superduper.superwhisper"
    private let recordingsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/superwhisper/recordings", isDirectory: true)

    // 키로 먼저 눌러 둔 뒤 폴더가 나타나기를 기다리는 시간. 사람의 반응(단축키 → 녹음 시작)과
    // 파일 생성 사이는 실측 100ms 안쪽이라 넉넉하다.
    private let confirmWindow: TimeInterval = 2.5
    // 어떤 신호도 끝을 알려주지 않은 채 끝난 경우의 최후 방어선. 이보다 긴 받아쓰기는 없다고
    // 보는 게 아니라, 이보다 길면 음악이 계속 눌려 있는 쪽이 더 나쁘다는 판단이다.
    private let maxDictationSeconds: TimeInterval = 180

    private let queue = DispatchQueue(label: "cm.voice-dictation", qos: .utility)
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var activeSource: DispatchSourceFileSystemObject?
    private var activeFD: Int32 = -1
    private var activeDir: URL?
    private var lastEpoch = 0
    private var folderWatchActive = false

    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var confirmTimer: Timer?
    private var backstopTimer: Timer?
    private var superwhisperRunning = false

    // MARK: lifecycle

    // 여러 번 불려도 안전하다(설정 스위치가 켜질 때마다 호출된다).
    func start() {
        guard dirSource == nil, monitors.isEmpty else { return }
        superwhisperRunning = Self.isSuperwhisperRunning()
        watchWorkspace()
        startFolderWatch()
        startKeyWatch()
        log("받아쓰기 감시 시작 (폴더=\(folderWatchActive ? "예" : "아니오") 키=\(monitors.isEmpty ? "아니오" : "예") superwhisper=\(superwhisperRunning ? "실행중" : "없음"))")
    }

    func stop() {
        endDictation(reason: "감시 중단")
        stopFolderWatch()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
        observers.removeAll()
    }

    deinit { stop() }

    private func log(_ message: String) { onLog?(message) }

    // MARK: 1) 폴더 신호

    private func startFolderWatch() {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: recordingsDir.path, isDirectory: &isDir), isDir.boolValue else {
            // superwhisper 를 아직 한 번도 안 썼거나 경로가 다르다. 키 신호만으로 돌아간다.
            log("recordings 폴더 없음 (\(recordingsDir.path)) — 키 신호만 사용")
            return
        }
        let fd = open(recordingsDir.path, O_EVTONLY)
        guard fd >= 0 else { log("recordings 폴더를 열 수 없음 — 키 신호만 사용"); return }
        dirFD = fd
        lastEpoch = Self.maxEpoch(in: recordingsDir)
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        src.setEventHandler { [weak self] in self?.parentDirChanged() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
        folderWatchActive = true
    }

    private func stopFolderWatch() {
        dirSource?.cancel(); dirSource = nil; dirFD = -1
        detachActive()
        folderWatchActive = false
    }

    // 새 항목이 생겼거나 지워졌다. 지금까지 본 것보다 새로운 epoch 폴더가 "빈 채로" 있으면
    // 그게 방금 시작된 녹음이다. 이미 파일이 차 있다면 우리가 늦게 본 완료된 녹음이므로 무시한다.
    private func parentDirChanged() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)) ?? []
        var newest = 0
        for name in names {
            if let e = Int(name), e > newest { newest = e }
        }
        guard newest > lastEpoch else { return }
        lastEpoch = newest
        let dir = recordingsDir.appendingPathComponent(String(newest), isDirectory: true)
        guard Self.isEmptyDir(dir) else { return }
        DispatchQueue.main.async { [weak self] in self?.confirmStart(dir: dir) }
    }

    // 녹음 폴더가 확인됐다. 키로 이미 눌러 둔 상태면 상태는 그대로 두고 감시만 붙인다.
    private func confirmStart(dir: URL) {
        confirmTimer?.invalidate(); confirmTimer = nil
        attachActive(dir: dir)
        beginDictation(reason: "녹음 폴더 생성 \(dir.lastPathComponent)")
    }

    private func attachActive(dir: URL) {
        detachActive()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        activeFD = fd
        activeDir = dir
        // .write = 안에 파일이 생김(전사 완료), .delete/.rename = 폴더가 사라짐(취소).
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                           eventMask: [.write, .delete, .rename],
                                                           queue: queue)
        // 감시 대상 경로는 클로저가 값으로 들고 간다. self.activeDir 은 main 에서 쓰고 지우는
        // 값이라 여기(백그라운드 큐)서 읽으면 경합이 된다 — 어차피 이 소스는 이 폴더 전용이다.
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let gone = !FileManager.default.fileExists(atPath: dir.path)
            let filled = !gone && !Self.isEmptyDir(dir)
            guard gone || filled else { return }
            DispatchQueue.main.async {
                self.endDictation(reason: gone ? "녹음 취소(폴더 삭제)" : "녹음 종료(파일 생성)")
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        activeSource = src
    }

    private func detachActive() {
        activeSource?.cancel(); activeSource = nil; activeFD = -1; activeDir = nil
    }

    // MARK: 2) 키 신호

    private func startKeyWatch() {
        // 전역(다른 앱에서 누른 것) + 로컬(이 앱이 앞에 있을 때). 로컬 쪽은 이벤트를 그대로
        // 흘려보내야 원래 처리가 이어진다.
        let mask: NSEvent.EventTypeMask = [.flagsChanged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.flagsChanged(event)
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.flagsChanged(event)
            return event
        }) { monitors.append(m) }
    }

    // kVK_RightCommand. modifierFlags 의 장치별 비트(NX_DEVICERCMDKEYMASK)로 눌림/뗌을 가른다 —
    // .command 만 보면 왼쪽 ⌘ 를 같이 쥔 채 오른쪽을 뗄 때 눌린 것으로 잘못 읽는다.
    private static let rightCommandKeyCode: UInt16 = 54
    private static let rightCommandMask: UInt = 0x000010

    private func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.rightCommandKeyCode else { return }
        let down = (event.modifierFlags.rawValue & Self.rightCommandMask) != 0
        guard down, superwhisperRunning else { return }
        DispatchQueue.main.async { [weak self] in self?.rightCommandPressed() }
    }

    // 토글 단축키라 누를 때마다 의미가 뒤집힌다: 눌려 있지 않으면 시작, 눌려 있으면 정지.
    private func rightCommandPressed() {
        if isDictating {
            endDictation(reason: "오른쪽 ⌘ (정지)")
            return
        }
        beginDictation(reason: "오른쪽 ⌘ (시작)")
        // 폴더 감시가 살아 있을 때만 "확인되지 않으면 되돌린다"가 성립한다. 폴더를 못 보는
        // 상황에서는 확인할 방법이 없으니 다음 키 입력이나 백스톱이 끝을 맡는다.
        guard folderWatchActive else { return }
        confirmTimer?.invalidate()
        confirmTimer = Timer.scheduledTimer(withTimeInterval: confirmWindow, repeats: false) { [weak self] _ in
            guard let self = self, self.activeDir == nil else { return }
            self.endDictation(reason: "녹음이 시작되지 않음 — 되돌림")
        }
    }

    // MARK: superwhisper 실행 여부

    private func watchWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.superwhisperRunning = Self.isSuperwhisperRunning()
            })
        }
    }

    private static func isSuperwhisperRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    // MARK: 상태 전이 (main 전용)

    private func beginDictation(reason: String) {
        backstopTimer?.invalidate()
        backstopTimer = Timer.scheduledTimer(withTimeInterval: maxDictationSeconds, repeats: false) { [weak self] _ in
            self?.endDictation(reason: "제한 시간 초과 — 되돌림")
        }
        guard !isDictating else { return }
        isDictating = true
        log("받아쓰기 시작 — \(reason)")
        onChange?(true)
    }

    private func endDictation(reason: String) {
        confirmTimer?.invalidate(); confirmTimer = nil
        backstopTimer?.invalidate(); backstopTimer = nil
        detachActive()
        guard isDictating else { return }
        isDictating = false
        log("받아쓰기 종료 — \(reason)")
        onChange?(false)
    }

    // MARK: helpers

    private static func isEmptyDir(_ url: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.allSatisfy { $0.hasPrefix(".") }
    }

    private static func maxEpoch(in dir: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { Int($0) }.max() ?? 0
    }
}
