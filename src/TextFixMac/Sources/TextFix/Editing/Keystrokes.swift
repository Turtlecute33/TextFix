// SPDX-License-Identifier: GPL-3.0-only
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Synthesised key chords, posted with CGEvent.
///
/// The detail that matters is the same one the Windows agent had to solve: the hotkey's own
/// modifiers are still physically down when the handler runs. On macOS the window server merges the
/// real hardware modifier state into a posted event, so a Cmd+V sent while the user is still
/// holding Ctrl+Opt arrives as Ctrl+Opt+Cmd+V - a different command in most editors, and a no-op in
/// the rest. Every held modifier is released first, and each event then carries exactly the flags
/// it is supposed to carry.
enum Keystrokes {
    /// Time given to the target app to process the modifier release before the chord arrives.
    /// Without a gap, fast apps occasionally see the chord while they still believe Opt is down.
    static let modifierSettleMs = 12

    /// Time given to the target app between two chords that depend on each other, such as the
    /// Cmd+A that must take effect before the Cmd+C that reads its result.
    static let chordSettleMs = 20

    /// Widened settle and per-event delay used for the one retry of a failed read.
    static let slowChordSettleMs = 90
    static let slowKeyEventDelayMs = 14

    /// Pause between the individual key events of one chord, or 0 to post them back to back. Set
    /// from keyEventDelayMs in config.json.
    static var keyEventDelayMs = 8

    private static let modifierKeyCodes: [CGKeyCode] = [
        CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand),
        CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption),
        CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl),
        CGKeyCode(kVK_Shift), CGKeyCode(kVK_RightShift),
        CGKeyCode(kVK_Function),
    ]

    /// One event source, created once: each one allocates a connection to the window server.
    ///
    /// Deliberately the combined session state rather than a private one. A private source would
    /// isolate our events from the modifiers the user is physically holding, which sounds like
    /// exactly what this file wants - but `releaseHeldModifiers` asks the *combined* state which
    /// keys are down, and modifier releases posted from a private source do not answer that
    /// question. The two would disagree forever, and every chord would pay the settle delay for a
    /// release that never appeared to take. Using one state for both, and setting the flags on each
    /// event explicitly, is what the rest of the platform does.
    private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Our synthesised keys must not be swallowed by the suppression interval that follows a
        // real keypress, which is exactly the situation we are in - the user just pressed the
        // hotkey.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateRemoteMouseDrag)
        return source
    }()

    /// True when the last failure was the system refusing to post events, which on macOS means one
    /// thing only: Accessibility permission has not been granted (or was revoked).
    private(set) static var lastSendBlocked = false

    static func clearSendBlocked() { lastSendBlocked = false }

    /// Releases any modifier the user is physically holding. Returns true if it sent anything.
    @discardableResult
    static func releaseHeldModifiers() -> Bool {
        let held = CGEventSource.flagsState(.combinedSessionState)
        let interesting: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard !held.intersection(interesting).isEmpty else { return false }

        var sent = 0
        for keyCode in modifierKeyCodes {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
            sent += 1
        }
        // Logged because a modifier still being down mid-fix is the signature of a held hotkey
        // re-asserting itself through auto-repeat, which is worth being able to see in a log.
        Log.debug("Released held modifiers before sending a chord")
        return sent > 0
    }

    /// Sends Command plus one key, for example Cmd+C, after clearing any modifier the user is
    /// holding. Pass `eventDelayMsOverride` to spread this one chord out further than the
    /// configured default.
    @discardableResult
    static func sendCommandChord(_ keyCode: Int, eventDelayMsOverride: Int? = nil) -> Bool {
        // Checked before *every* chord rather than once per fix, because a physically held key
        // keeps re-asserting itself: macOS auto-repeats a held modifier, so the modifiers released
        // at the start of a fix are down again by the time a chord goes out a few hundred
        // milliseconds later.
        if releaseHeldModifiers() { sleep(ms: modifierSettleMs) }

        guard let source else {
            lastSendBlocked = true
            Log.warn("Could not create an event source; keyboard input is not permitted")
            return false
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            lastSendBlocked = true
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cghidEventTap)
        let delay = eventDelayMsOverride ?? keyEventDelayMs
        if delay > 0 { sleep(ms: delay) }
        up.post(tap: .cghidEventTap)
        return true
    }

    static func sleep(ms: Int) {
        guard ms > 0 else { return }
        Thread.sleep(forTimeInterval: Double(ms) / 1000)
    }
}
