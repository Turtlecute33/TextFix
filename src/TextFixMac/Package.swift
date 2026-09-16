// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

// The macOS agent. No dependencies, by design: AppKit for the menu bar and the settings window,
// the Accessibility API to read the text under the caret, Carbon for the global hotkeys and
// URLSession for the one HTTP call. `swift build` produces the binary that build-mac.sh wraps
// into TextFix.app.
let package = Package(
    name: "TextFix",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TextFix",
            path: "Sources/TextFix",
            swiftSettings: [
                // Nothing here is throughput-bound - the process spends its life asleep waiting
                // for a keystroke - so trade the inlining for a smaller resident image.
                .unsafeFlags(["-Osize"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
