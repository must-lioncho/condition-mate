import AppKit

// Everything the status-bar menu displays, captured as one plain snapshot. The host app builds
// this on demand (menuNeedsUpdate → the `state` closure), so the GUI module needs no knowledge
// of the app's session/store/director/library objects — only of what the menu SHOWS.
public struct MenuState {
    public var isWorking = false
    public var isMuted = false
    public var liveStatus = ""
    public var sessionSeconds: Double = 0
    public var totalSeconds: Double = 0
    public var todaySeconds: Double = 0

    // Condition / BGM status block.
    public var conditionActive = false            // director.isActive
    public var strategyLabel = ""                 // director.activeProfileLabel
    public var phaseLabel = ""                    // director.phase.rawValue
    public var targetBPM: Double = 0
    public var releaseRemainingSeconds: Double?   // nil = no release countdown
    public var planSlotLabel: String?             // bgm-plan slot label, nil = no plan slot
    public var activeAppLabel = ""
    public var currentTrackTitle: String?         // nil = nothing playing
    public var musicEnabled = true
    public var trackCount = 0
    public var bpmRange: (min: Double, max: Double)?

    // Toggles / window block.
    public var bgmWindowEnabled = true
    public var drawInstalled = false              // draw plugin connected (toggle hidden otherwise)
    public var drawEnabled = true                 // Settings.drawEnabled (전체 드로우 on/off)
    public var cameraGuardInstalled = false       // camera-guard plugin installed (toggle hidden otherwise)
    public var cameraGuardOn = true               // Settings.cameraGuardOn (지킴이 on/off, 기본 켜짐)
    public var menuBarModeIsSports = true         // 스포츠(APM) vs 타임(clock)
    public var windowOpen = false
    public var windowModeIsBGM = false

    // Permissions / login item block.
    public var accessibilityTrusted = false
    public var loginItemAvailable = false         // only meaningful from a signed .app bundle
    public var loginItemEnabled = false

    public init() {}
}

// The menu's click targets. The host app (컨디션 매니저: AppDelegate) conforms; every method
// matches one menu item action.
public protocol MenuControllerActions: AnyObject {
    func toggleWorking()
    func toggleMute()
    func toggleMusic()
    func toggleMenuBarMode()
    func toggleDraw()
    func toggleCameraGuard()
    func dislikeCurrentTrack()
    func toggleAppWindowMode()
    func toggleBGMWindowAutoOpen()
    func chooseMusicFolder()
    func requestAccessibility()
    func toggleLoginItem()
    func quit()
}

// Builds the status-bar menu on demand. Rebuilding only when the menu opens
// (NSMenuDelegate) means zero rendering work while idle — important for the
// low-resource goal.
public final class MenuController: NSObject, NSMenuDelegate {

    public let menu = NSMenu()
    private weak var actions: MenuControllerActions?
    private let state: () -> MenuState

    public init(actions: MenuControllerActions, state: @escaping () -> MenuState) {
        self.actions = actions
        self.state = state
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        let s = state()
        menu.removeAllItems()

        // --- Manual Start / Stop Working (top, prominent like Hubstaff) ---
        // ⌘S start/stop — app-wide shortcut (active on any page while the app is frontmost), wired
        // via a local key monitor in AppDelegate. Mute additionally carries a SYSTEM-WIDE ⌃⌘M
        // (GlobalHotKey), which works from any app; ⌘M still works in-app. Shown for discoverability.
        if s.isWorking {
            addBigAction("■  챌린지 중단  ⌘S", action: #selector(onToggleWorking), color: .systemRed)
        } else {
            addBigAction("▶  챌린지 시작  ⌘S", action: #selector(onToggleWorking), color: .systemGreen)
        }
        // Music mute toggle (음원 on/off) — same source of truth (session.isMuted) as ⌘M, the
        // dashboard mute dot, and the BGM player, so every surface shows and controls one state.
        if s.isMuted {
            addItem("🔇  음소거 해제 (소리 켜기)  ⌃⌘M", action: #selector(onToggleMuteMenu))
        } else {
            addItem("🔊  음소거 (챌린지는 계속)  ⌃⌘M", action: #selector(onToggleMuteMenu))
        }
        addDisabled("\(s.liveStatus) · 세션 \(Formatting.clock(s.sessionSeconds))")
        addDisabled("⌃⌘M 음소거 (전역 · 어느 앱에서든) · ⌘S 챌린지 (앱 활성 시)")

        menu.addItem(.separator())

        // --- Cumulative progress (the "leveling up" headline) ---
        addDisabled("누적 \(Formatting.hoursLabel(s.totalSeconds))", bold: true)
        addDisabled(Formatting.milestoneProgress(forSeconds: s.totalSeconds))
        addDisabled("오늘 \(Formatting.hoursLabel(s.todaySeconds))")

        menu.addItem(.separator())

        // --- Condition / BGM status ---
        if s.conditionActive {
            let app = s.activeAppLabel.isEmpty ? "" : " · \(s.activeAppLabel)"
            let plan = s.planSlotLabel.map { " · 플랜 \($0)" } ?? ""
            addDisabled("전략: \(s.strategyLabel)\(plan)\(app)")
            addDisabled("컨디션: \(s.phaseLabel) · 목표 \(Int(s.targetBPM)) BPM")
            if let remain = s.releaseRemainingSeconds {
                addDisabled("  릴리즈 \(Int(remain / 60))분 \(Int(remain.truncatingRemainder(dividingBy: 60)))초 남음")
            }
            if let title = s.currentTrackTitle {
                addDisabled("♪ \(title)")
                addItem("✕  이 곡 싫어요 (다른 곡으로 교체)", action: #selector(onDislikeTrack))
            }
        } else if s.musicEnabled {
            if s.trackCount == 0 {
                addDisabled("음원 없음 — 음악 폴더를 선택하세요")
            } else {
                addDisabled("컨디션 대기 중 (챌린지 시작 시 재생)")
            }
        } else {
            addDisabled("음악 꺼짐")
        }
        if s.trackCount > 0 {
            let r = s.bpmRange.map { " (\(Int($0.min))–\(Int($0.max)) BPM)" } ?? ""
            addDisabled("음원 \(s.trackCount)곡\(r)")
        }

        menu.addItem(.separator())

        // --- Toggles ---
        addCheck("음악 (BGM)", checked: s.musicEnabled, action: #selector(onToggleMusic))
        addCheck("창 자동 열기 (BGM 자동재생)", checked: s.bgmWindowEnabled, action: #selector(onToggleBGMWindow))
        // 드로우 전체 on/off — accidental left-⌥ strokes / triple-⌘ text pops are easy to
        // trigger while working, so the widget gets a one-click kill switch. Same source of
        // truth as the plugin card's sub-switch (Settings.drawEnabled); hidden when the draw
        // plugin isn't installed (the toggle would be meaningless).
        if s.drawInstalled {
            addCheck("그리기 (왼쪽 ⌥ 드로우)", checked: s.drawEnabled, action: #selector(onToggleDraw))
        }
        // 카메라 지킴이 on/off — same source of truth as the plugin card's sub-switch
        // (Settings.cameraGuardOn); hidden when the camera-guard plugin isn't installed.
        if s.cameraGuardInstalled {
            addCheck("카메라 지킴이 (개더 상시-ON)", checked: s.cameraGuardOn, action: #selector(onToggleCameraGuard))
        }
        // Menu-bar gauge: 스포츠(라이브 APM) ↔ 타임(시간). Label shows the next state.
        let modeLabel = s.menuBarModeIsSports
            ? "메뉴바: ⚡APM (스포츠) → 시간으로"
            : "메뉴바: ⏱ 시간 (타임) → APM으로"
        addItem(modeLabel, action: #selector(onToggleMenuBarMode))
        // Single unified window-toggle entry (replaces the old two separate "열기" items):
        // closed -> opens in the current in-window mode; open -> switches the SAME window's mode.
        // Label always shows the destination state, consistent with the menu-bar mode line above
        // and with the in-window segmented toggle (they share the same mode and stay in sync).
        addItem(windowToggleLabel(s), action: #selector(onToggleAppWindowMode))

        menu.addItem(.separator())

        // --- Setup ---
        // Per-app tracked-strategy and BPM/release settings entries were removed:
        // the plan map (bgm-plan.json slots) drives strategy now, and the stored
        // Settings values keep working without a menu surface.
        addItem("음악 폴더 선택…", action: #selector(onChooseFolder))

        menu.addItem(.separator())

        // --- Permission status ---
        // Leading icon makes the granted/needed state readable at a glance:
        // green check when trusted, amber warning when action is still needed.
        if !s.accessibilityTrusted {
            let item = addItem("손쉬운 사용 권한 요청 (키 입력 감지)", action: #selector(onRequestAccessibility))
            item.image = statusIcon("exclamationmark.triangle.fill", color: .systemOrange)
        } else {
            let item = addDisabled("손쉬운 사용 권한: 허용됨")
            item.image = statusIcon("checkmark.circle.fill", color: .systemGreen)
        }

        // --- Login at startup (only meaningful from a signed .app bundle) ---
        if s.loginItemAvailable {
            addCheck("로그인 시 자동 시작", checked: s.loginItemEnabled, action: #selector(onToggleLoginItem))
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
    private func windowToggleLabel(_ s: MenuState) -> String {
        if !s.windowOpen {
            return s.windowModeIsBGM ? "창 열기 (컨디션 모드)" : "창 열기 (대시보드 모드)"
        }
        return s.windowModeIsBGM ? "대시보드 모드로 전환" : "컨디션 모드로 전환"
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

    // MARK: - Actions

    @objc private func onToggleWorking() { actions?.toggleWorking() }
    @objc private func onToggleMuteMenu() { actions?.toggleMute() }
    @objc private func onToggleMusic() { actions?.toggleMusic() }
    @objc private func onToggleMenuBarMode() { actions?.toggleMenuBarMode() }
    @objc private func onToggleDraw() { actions?.toggleDraw() }
    @objc private func onToggleCameraGuard() { actions?.toggleCameraGuard() }
    @objc private func onDislikeTrack() { actions?.dislikeCurrentTrack() }
    @objc private func onToggleAppWindowMode() { actions?.toggleAppWindowMode() }
    @objc private func onToggleBGMWindow() { actions?.toggleBGMWindowAutoOpen() }
    @objc private func onChooseFolder() { actions?.chooseMusicFolder() }
    @objc private func onRequestAccessibility() { actions?.requestAccessibility() }
    @objc private func onToggleLoginItem() { actions?.toggleLoginItem() }
    @objc private func onQuit() { actions?.quit() }
}
