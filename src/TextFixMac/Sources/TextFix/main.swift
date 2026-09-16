// SPDX-License-Identifier: GPL-3.0-only
import AppKit

// One agent per login session. Launching it again - from Spotlight, from the Finder, from the
// login item after a crash - brings up the settings of the copy that is already running instead of
// fighting it for the hotkeys.
let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.turtlecute33.textfix"
let alreadyRunning = NSRunningApplication
    .runningApplications(withBundleIdentifier: bundleIdentifier)
    .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

if alreadyRunning {
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Belt and braces with LSUIElement in Info.plist: no Dock icon, no Cmd+Tab entry, menu bar only.
// The plist is what prevents an icon appearing for the instant before this line runs; this line is
// what keeps the behaviour correct if the binary is ever run outside its bundle.
application.setActivationPolicy(.accessory)
application.run()
