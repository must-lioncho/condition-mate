import AppKit

// Builds the status-bar menu on demand. Rebuilding only when the menu opens
// (NSMenuDelegate) means zero rendering work while idle — important for the
// low-resource goal.
final class MenuController: NSObject, NSMenuDelegate {

    let menu = NSMenu()
    private weak var delegate: AppDelegate?

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        guard let d = delegate else { return }
        menu.removeAllItems()
        let s = Settings.shared

        // --- Manual Start / Stop Working (top, prominent like Hubstaff) ---
        // ⌘S start/stop, ⌘M mute — app-wide shortcuts (active on any page while the app is frontmost),
        // wired via a local key monitor in AppDelegate; shown here for discoverability.
        if d.isWorking {
            addBigAction("■  챌린지 중단  ⌘S", action: #selector(onToggleWorking), color: .systemRed)
        } else {
            addBigAction("▶  챌린지 시작  ⌘S", action: #selector(onToggleWorking), color: .systemGreen)
        }
        // Music mute toggle (음원 on/off) — same source of truth (session.isMuted) as ⌘M, the
        // dashboard mute dot, and the BGM player, so every surface shows and controls one state.
        if d.session.isMuted {
            addItem("🔇  음소거 해제 (소리 켜기)  ⌘M", action: #selector(onToggleMuteMenu))
        } else {
            addItem("🔊  음소거 (챌린지는 계속)  ⌘M", action: #selector(onToggleMuteMenu))
        }
        addDisabled("\(d.liveStatus) · 세션 \(Formatting.clock(d.sessionSeconds))")
        addDisabled("⌘M 음소거 · ⌘S 챌린지 (앱 활성 시 어느 페이지든)")

        menu.addItem(.separator())

        // --- Cumulative progress (the "leveling up" headline) ---
        addDisabled("누적 \(Formatting.hoursLabel(d.store.data.totalSeconds))", bold: true)
        addDisabled(Formatting.milestoneProgress(forSeconds: d.store.data.totalSeconds))
        addDisabled("오늘 \(Formatting.hoursLabel(d.store.todaySeconds))")

        menu.addItem(.separator())

        // --- Condition / BGM status ---
        if d.director.isActive {
            let app = d.activeAppLabel.isEmpty ? "" : " · \(d.activeAppLabel)"
            let plan = d.bgmPlan.slot().map { " · 플랜 \($0.label)" } ?? ""
            addDisabled("전략: \(d.director.activeProfileLabel)\(plan)\(app)")
            addDisabled("컨디션: \(d.director.phase.rawValue) · 목표 \(Int(d.director.targetBPM)) BPM")
            if let remain = d.director.releaseRemaining {
                addDisabled("  릴리즈 \(Int(remain / 60))분 \(Int(remain.truncatingRemainder(dividingBy: 60)))초 남음")
            }
            if let title = d.audio.currentTitle {
                addDisabled("♪ \(title)")
                addItem("✕  이 곡 싫어요 (다른 곡으로 교체)", action: #selector(onDislikeTrack))
            }
        } else if s.musicEnabled {
            if d.library.tracks.isEmpty {
                addDisabled("음원 없음 — 음악 폴더를 선택하세요")
            } else {
                addDisabled("컨디션 대기 중 (챌린지 시작 시 재생)")
            }
        } else {
            addDisabled("음악 꺼짐")
        }
        if !d.library.tracks.isEmpty {
            let range = d.library.bpmRange
            let r = range.map { " (\(Int($0.min))–\(Int($0.max)) BPM)" } ?? ""
            addDisabled("음원 \(d.library.tracks.count)곡\(r)")
        }

        menu.addItem(.separator())

        // --- Toggles ---
        addCheck("음악 (BGM)", checked: s.musicEnabled, action: #selector(onToggleMusic))
        addCheck("창 자동 열기 (BGM 자동재생)", checked: s.bgmWindowEnabled, action: #selector(onToggleBGMWindow))
        // Menu-bar gauge: 스포츠(라이브 APM) ↔ 타임(시간). Label shows the next state.
        let modeLabel = d.menuBarMode == .sports
            ? "메뉴바: ⚡APM (스포츠) → 시간으로"
            : "메뉴바: ⏱ 시간 (타임) → APM으로"
        addItem(modeLabel, action: #selector(onToggleMenuBarMode))
        // Single unified window-toggle entry (replaces the old two separate "열기" items):
        // closed -> opens in the current in-window mode; open -> switches the SAME window's mode.
        // Label always shows the destination state, consistent with the menu-bar mode line above
        // and with the in-window segmented toggle (they share the same mode and stay in sync).
        addItem(windowToggleLabel(d), action: #selector(onToggleAppWindowMode))

        menu.addItem(.separator())

        // --- Setup ---
        addItem("음악 폴더 선택…", action: #selector(onChooseFolder))
        addItem("현재 앱을 추적에 추가", action: #selector(onAddApp))

        // Tracked apps submenu — each app maps to a BGM strategy (profile).
        let trackedItem = NSMenuItem(title: "추적 앱 · BGM 전략 (\(s.trackedApps.count))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if s.trackedApps.isEmpty {
            let empty = NSMenuItem(title: "없음 — '현재 앱을 추적에 추가' 사용", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            for id in s.trackedApps {
                let name = appName(forBundleID: id) ?? id
                let currentKey = s.profileKey(for: id)
                let profile = BGMProfile.by(key: currentKey)
                let appItem = NSMenuItem(title: "\(name) — \(profile.label)", action: nil, keyEquivalent: "")
                appItem.submenu = buildAppProfileMenu(bundleID: id, name: name, currentKey: currentKey)
                sub.addItem(appItem)
            }
        }
        trackedItem.submenu = sub
        menu.addItem(trackedItem)

        // Settings submenu (BPM range + release minutes)
        menu.addItem(buildSettingsSubmenu(s))

        menu.addItem(.separator())

        // --- Permission status ---
        // Leading icon makes the granted/needed state readable at a glance:
        // green check when trusted, amber warning when action is still needed.
        if !d.activity.isTrusted {
            let item = addItem("손쉬운 사용 권한 요청 (키 입력 감지)", action: #selector(onRequestAccessibility))
            item.image = statusIcon("exclamationmark.triangle.fill", color: .systemOrange)
        } else {
            let item = addDisabled("손쉬운 사용 권한: 허용됨")
            item.image = statusIcon("checkmark.circle.fill", color: .systemGreen)
        }

        // --- Login at startup (only meaningful from a signed .app bundle) ---
        if LoginItem.isBundled {
            addCheck("로그인 시 자동 시작", checked: LoginItem.isEnabled, action: #selector(onToggleLoginItem))
        } else {
            addDisabled("로그인 자동 시작: .app 번들 실행 시 사용 가능")
        }

        menu.addItem(.separator())
        addItem("종료", action: #selector(onQuit), key: "q")
    }

    // Label for the single unified window-toggle menu entry. Always names the destination state
    // (mirrors the "메뉴바: … → …" pattern above), so one click always does what the label says:
    //   closed            -> "창 열기 (컨디션 모드)" / "창 열기 (대시보드 모드)" depending on last mode
    //   open, 컨디션 mode  -> "대시보드 모드로 전환"
    //   open, 대시보드 mode -> "컨디션 모드로 전환"
    private func windowToggleLabel(_ d: AppDelegate) -> String {
        if !d.appWindowIsOpen {
            return d.appWindowMode == .bgm ? "창 열기 (컨디션 모드)" : "창 열기 (대시보드 모드)"
        }
        return d.appWindowMode == .bgm ? "대시보드 모드로 전환" : "컨디션 모드로 전환"
    }

    // Per-app BGM strategy picker.
    private func buildAppProfileMenu(bundleID: String, name: String, currentKey: String) -> NSMenu {
        let m = NSMenu()
        let header = NSMenuItem(title: "\(name) · 1분 이상 사용 시 이 전략으로", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        for p in BGMProfile.all {
            let i = NSMenuItem(title: "\(p.label)  \(Int(p.minBPM))–\(Int(p.maxBPM))",
                               action: #selector(onSetProfile(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = [bundleID, p.key]
            i.state = (p.key == currentKey) ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        let remove = NSMenuItem(title: "✕  추적에서 제거", action: #selector(onRemoveApp(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = bundleID
        m.addItem(remove)
        return m
    }

    private func buildSettingsSubmenu(_ s: Settings) -> NSMenuItem {
        let item = NSMenuItem(title: "설정", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let bpmHeader = NSMenuItem(title: "BPM 범위: \(Int(s.minBPM))–\(Int(s.maxBPM))", action: nil, keyEquivalent: "")
        bpmHeader.isEnabled = false
        sub.addItem(bpmHeader)
        for (lo, hi) in [(70.0, 130.0), (70.0, 150.0), (80.0, 170.0), (90.0, 180.0)] {
            let i = NSMenuItem(title: "  \(Int(lo))–\(Int(hi)) BPM", action: #selector(onSetBPMRange(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = [lo, hi]
            i.state = (s.minBPM == lo && s.maxBPM == hi) ? .on : .off
            sub.addItem(i)
        }

        sub.addItem(.separator())
        let relHeader = NSMenuItem(title: "릴리즈 길이: \(Int(s.releaseMinutes))분", action: nil, keyEquivalent: "")
        relHeader.isEnabled = false
        sub.addItem(relHeader)
        for m in [5.0, 7.0, 10.0] {
            let i = NSMenuItem(title: "  \(Int(m))분", action: #selector(onSetRelease(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = m
            i.state = (s.releaseMinutes == m) ? .on : .off
            sub.addItem(i)
        }

        item.submenu = sub
        return item
    }

    // MARK: - Item builders

    @discardableResult
    private func addDisabled(_ title: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            )
        }
        menu.addItem(item)
        return item
    }

    // Small tinted SF Symbol for use as a leading menu-item icon.
    private func statusIcon(_ symbol: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let tinted = base.copy() as! NSImage
        tinted.isTemplate = false
        tinted.lockFocus()
        color.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }

    // Prominent, colored, bold action — the Start/Stop headline.
    private func addBigAction(_ title: String, action: Selector, color: NSColor) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1),
                .foregroundColor: color,
            ]
        )
        menu.addItem(item)
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
        return item
    }

    private func addCheck(_ title: String, checked: Bool, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    private func appName(forBundleID id: String) -> String? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return nil
    }

    // MARK: - Actions

    @objc private func onToggleWorking() { delegate?.toggleWorking() }
    @objc private func onToggleMuteMenu() { delegate?.toggleMute() }
    @objc private func onToggleMusic() { delegate?.toggleMusic() }
    @objc private func onToggleMenuBarMode() { delegate?.toggleMenuBarMode() }
    @objc private func onDislikeTrack() { delegate?.dislikeCurrentTrack() }
    @objc private func onToggleAppWindowMode() { delegate?.toggleAppWindowMode() }
    @objc private func onToggleBGMWindow() { delegate?.toggleBGMWindowAutoOpen() }
    @objc private func onChooseFolder() { delegate?.chooseMusicFolder() }
    @objc private func onAddApp() { delegate?.addCurrentFrontmostApp() }
    @objc private func onRequestAccessibility() { delegate?.requestAccessibility() }
    @objc private func onToggleLoginItem() { delegate?.toggleLoginItem() }
    @objc private func onQuit() { delegate?.quit() }

    @objc private func onRemoveApp(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            Settings.shared.removeTrackedApp(id)
        }
    }

    @objc private func onSetProfile(_ sender: NSMenuItem) {
        if let arr = sender.representedObject as? [String], arr.count == 2 {
            delegate?.setAppProfile(arr[1], for: arr[0])
        }
    }

    @objc private func onSetBPMRange(_ sender: NSMenuItem) {
        if let pair = sender.representedObject as? [Double], pair.count == 2 {
            delegate?.setBPMRange(min: pair[0], max: pair[1])
        }
    }

    @objc private func onSetRelease(_ sender: NSMenuItem) {
        if let m = sender.representedObject as? Double {
            delegate?.setReleaseMinutes(m)
        }
    }
}
