// swift-tools-version:5.9
import PackageDescription

// ConditionMate — a memory-light, macOS-only menu bar app.
// Pure AppKit (no SwiftUI runtime) to keep the resident footprint minimal.
let package = Package(
    name: "ConditionMate",
    platforms: [
        .macOS(.v13) // NSStatusItem + AVAudioPlayer; deliberately AppKit-only
    ],
    products: [
        // Exported so other packages/apps can depend on the GUI toolkit directly.
        .library(name: "GUI", targets: ["GUI"])
    ],
    targets: [
        // The in-page web terminal stack (PTY engine + shared xterm.js client engine +
        // IME diagnostics). Its own target so the web-CLI layer — xterm version bumps,
        // IME fixes, polling protocol — evolves in one place (Sources/WebCLI).
        .target(
            name: "WebCLI",
            path: "Sources/WebCLI"
        ),
        // Reusable AppKit GUI toolkit: web-surface app window (dual persistent WKWebViews,
        // zen fold, JS dialog/file-picker plumbing), status-bar lightning gauge, menu builder,
        // progress formatting. Deliberately app-agnostic — no ConditionMate types; the app
        // injects behavior via hooks/configuration so other apps can reuse it (Sources/GUI).
        .target(
            name: "GUI",
            path: "Sources/GUI"
        ),
        // Screen-drawing overlay engine (드로우 plugin): transparent click-through
        // per-screen windows, left-⌥-to-draw / left-⌃-to-wipe key polling. App-agnostic
        // like GUI — the app decides when it runs (Sources/Draw).
        .target(
            name: "Draw",
            path: "Sources/Draw"
        ),
        // 외부 연동 레지스트리 (Sources/Plugins/Integrations): 이 앱이 기대는 모든
        // 자격증명(슬랙 토큰·LLM API 키)의 카탈로그·키체인 접근·라이브 연결 검사·
        // 기능 게이팅. 앱과 플러그인이 같은 사실을 보게 하려고 별도 타깃으로 뺐다 —
        // Slack 타깃과 앱 타깃이 둘 다 의존한다(한곳에서 고치면 모두 고쳐진다).
        .target(
            name: "Integrations",
            path: "Sources/Plugins/Integrations"
        ),
        // Slack 👀 번역 plugin (independent development): dashboard-side stores/page
        // (SlackTranslateStore/SlackActionLog/SlackTranslateContent) plus the external
        // Socket Mode daemon under Daemon/ (not compiled — launchd runs the .mjs).
        // App-agnostic like GUI/Draw; the app injects data dir + settings hooks.
        // 연동 키는 스스로 들고 있지 않고 Integrations 레지스트리에 묻는다.
        .target(
            name: "Slack",
            dependencies: ["Integrations"],
            path: "Sources/Plugins/Slack",
            exclude: ["Daemon"]
        ),
        // 지라 번역 plugin (Sources/Plugins/Jira): 고정 포트 로컬 브리지 + Gemini 번역.
        // 짝이 되는 크롬 익스텐션은 Extension/ 에 있고 컴파일 대상이 아니다 —
        // Scripts/install-jira-ext.sh 가 토큰을 심어 <data>/chrome-jira-translate 로
        // 복사하고, 크롬은 그 폴더를 압축해제 확장으로 읽는다.
        .target(
            name: "Jira",
            dependencies: ["Integrations"],
            path: "Sources/Plugins/Jira",
            exclude: ["Extension"]
        ),
        .executableTarget(
            name: "ConditionMate",
            dependencies: ["WebCLI", "GUI", "Draw", "Slack", "Jira", "Integrations"],
            path: "Sources/ConditionMate"
        ),
        // Standalone web terminal: serves the in-app CLI 세션 view to a real browser,
        // reusing the WebCLI target (PtySession + CMWebCLI engine) verbatim. Run it
        // directly — `swift run WebCLIServer` — independent of the menu-bar app.
        .executableTarget(
            name: "WebCLIServer",
            dependencies: ["WebCLI"],
            path: "Sources/WebCLIServer"
        ),
        // Deterministic unit tests for the AI 큐 연관성 검색 (DASH-9 content-substance cascade).
        // @testable imports the app target to reach RelatedGoalSearch's internal API. Never
        // invokes `claude -p` — all retrieval/substance/reconcile logic is pure.
        .testTarget(
            name: "RelatedGoalSearchTests",
            dependencies: ["ConditionMate"],
            path: "tests/RelatedGoalSearchTests"
        )
    ]
)
