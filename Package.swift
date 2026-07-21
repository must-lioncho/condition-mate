// swift-tools-version:5.9
import PackageDescription

// ConditionManager — a memory-light, macOS-only menu bar app.
// Pure AppKit (no SwiftUI runtime) to keep the resident footprint minimal.
let package = Package(
    name: "ConditionManager",
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
        // progress formatting. Deliberately app-agnostic — no ConditionManager types; the app
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
        .executableTarget(
            name: "ConditionManager",
            dependencies: ["WebCLI", "GUI", "Draw"],
            path: "Sources/ConditionManager"
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
            dependencies: ["ConditionManager"],
            path: "tests/RelatedGoalSearchTests"
        )
    ]
)
