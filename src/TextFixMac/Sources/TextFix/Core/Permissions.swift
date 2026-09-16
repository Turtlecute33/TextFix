// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ApplicationServices

/// The one permission TextFix needs, and the one thing a user new to it will get stuck on.
///
/// macOS will not let any process read the text in another app's window or synthesise a keystroke
/// without Accessibility permission, and it deliberately gives no way to grant it programmatically.
/// All an app can do is ask, explain, and open the right pane - so that is what this does, in one
/// place, rather than leaving each call site to invent its own wording.
enum Permissions {
    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show its own "TextFix would like to control this computer" prompt. Only ever
    /// called from a user action, because the system shows it at most once per app per install and
    /// spending that on a background launch would waste it.
    @discardableResult
    static func requestWithSystemPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// The explanation shown when a hotkey press could not do anything because the permission is
    /// missing. Interrupting is the right call here: the alternative is a key that silently does
    /// nothing, which reads as a broken app.
    static func promptForAccessibility() {
        Log.warn("Accessibility permission is not granted")
        guard !isShowingPrompt else { return }
        isShowingPrompt = true
        defer { isShowingPrompt = false }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "TextFix needs Accessibility permission"
        alert.informativeText =
            "macOS only lets an app read and replace text in other apps once you allow it under "
            + "Privacy & Security > Accessibility.\n\nTurn on TextFix in that list, then press your "
            + "hotkey again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            // The system prompt is what actually adds TextFix to the list, so ask for it first and
            // then take the user to the pane where they flip the switch.
            requestWithSystemPrompt()
            openAccessibilitySettings()
        }
    }

    private static var isShowingPrompt = false
}
