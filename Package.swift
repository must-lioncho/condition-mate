// swift-tools-version:5.9
import PackageDescription

// ConditionManager — a memory-light, macOS-only menu bar app.
// Pure AppKit (no SwiftUI runtime) to keep the resident footprint minimal.
let package = Package(
    name: "ConditionManager",
    platforms: [
        .macOS(.v13) // NSStatusItem + AVAudioPlayer; deliberately AppKit-only
    ],
    targets: [
        .executableTarget(
            name: "ConditionManager",
            path: "Sources/ConditionManager"
        )
    ]
)
