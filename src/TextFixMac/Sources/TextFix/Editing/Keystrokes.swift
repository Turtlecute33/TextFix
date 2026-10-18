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

    /// Sends Command plus one letter, for example Cmd+C, after clearing any modifier the user is
    /// holding. Pass `eventDelayMsOverride` to spread this one chord out further than the
    /// configured default.
    @discardableResult
    static func sendCommandChord(_ letter: Character, eventDelayMsOverride: Int? = nil) -> Bool {
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
        let keyCode = commandKeyCode(for: letter)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
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

    // ---- keyboard layout ----

    /// Where the letters this file presses sit on a US keyboard, used when the layout cannot be
    /// read.
    private static let ansiKeyCodes: [Character: Int] = ["a": kVK_ANSI_A, "c": kVK_ANSI_C, "v": kVK_ANSI_V]

    /// The key that types `letter` with Command held, in the keyboard layout in use right now.
    ///
    /// A key code is a position on the keyboard, not a letter, and apps match Cmd shortcuts by the
    /// letter the layout gives that position. The US positions are wrong on many layouts: on
    /// French AZERTY the US "A" position types Q, so a select-all sent there is Cmd+Q and quits
    /// the app; on Dvorak, Cmd+C and Cmd+V land as Cmd+J and Cmd+K. Layouts whose letters are not
    /// Latin fall back to the ASCII-capable layout macOS itself uses for shortcuts.
    private static func commandKeyCode(for letter: Character) -> CGKeyCode {
        let fallback = ansiKeyCodes[letter] ?? 0
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ]
        for case let source? in sources {
            if let code = keyCode(typing: letter, in: source, preferring: fallback) { return code }
        }
        return CGKeyCode(fallback)
    }

    private static func keyCode(typing letter: Character, in source: TISInputSource, preferring preferred: Int) -> CGKeyCode? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            let target = String(letter)
            func types(_ code: Int) -> Bool {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeys, chars.count, &length, &chars)
                return status == noErr && String(utf16CodeUnits: chars, count: length).lowercased() == target
            }
            // The US position first: on most layouts it is right, and it is the one the user's
            // own fingers would use if the two disagreed on a key that types the letter twice.
            if types(preferred) { return CGKeyCode(preferred) }
            for code in 0..<128 where code != preferred && types(code) { return CGKeyCode(code) }
            return nil
        }
    }

    static func sleep(ms: Int) {
        guard ms > 0 else { return }
        Thread.sleep(forTimeInterval: Double(ms) / 1000)
    }
}
