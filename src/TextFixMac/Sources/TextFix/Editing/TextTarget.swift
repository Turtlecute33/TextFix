// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum CaptureMode {
    /// The user had text selected, and only that text is fixed.
    case selection
    /// Nothing was selected, so the whole field was taken and is fixed as a unit.
    case wholeText
}

enum CaptureSource {
    /// Read straight out of the focused element. No pasteboard, no synthesised keys, and the
    /// selection is a fact rather than something inferred.
    case accessibility
    /// The Windows-style fallback: park a marker on the pasteboard, press Cmd+C, and look at what
    /// came back. Used for hosts that publish no usable text through AX.
    case pasteboard
}

final class TextCapture {
    let text: String
    let mode: CaptureMode
    let source: CaptureSource
    let element: AXUIElement?
    let appPid: pid_t
    /// The range the text occupies, when AX told us. Needed to re-select the whole field before a
    /// paste, since the AX read never selected anything.
    let fullRange: CFRange?
    /// The pasteboard as it was before the capture borrowed it. Nil on the Accessibility path,
    /// which borrows nothing: there the snapshot is taken just before a paste, if one happens.
    let saved: PasteboardSnapshot?
    /// Quartz screen coordinates (origin top-left), or nil when the host publishes no caret.
    let caretRect: CGRect?
    /// `changeCount` once the capture was done. Anything else on the pasteboard by the time the
    /// request comes back was put there by someone else - most likely the user.
    let pasteboardCount: Int

    init(text: String, mode: CaptureMode, source: CaptureSource, element: AXUIElement?,
         appPid: pid_t, fullRange: CFRange?, saved: PasteboardSnapshot?, caretRect: CGRect?) {
        self.text = text
        self.mode = mode
        self.source = source
        self.element = element
        self.appPid = appPid
        self.fullRange = fullRange
        self.saved = saved
        self.caretRect = caretRect
        self.pasteboardCount = PasteboardBridge.changeCount
    }
}

enum ReplaceOutcome {
    case replaced
    /// Focus moved, or the text under it changed, while the request was out.
    case focusChanged
    /// The app took the Accessibility write but did not confirm it in time. It may still land, so
    /// a paste on top of it could insert the text twice.
    case unconfirmed
    /// macOS refused to let us post events or write the element: Accessibility permission.
    case blocked
    case failed
}

struct CaptureOptions {
    let allowSelectAll: Bool
    let skipPasswordFields: Bool
    let takeSnapshot: Bool
    let useAccessibilityRead: Bool
    let selectionProbeMs: Int
    let copyTimeoutMs: Int
    /// The most text worth reading off the pasteboard, in UTF-16 code units. One more than the
    /// caller's limit, so an oversized read is recognisably over it without being materialised in
    /// full on the main thread.
    let maxUTF16: Int
}

enum CaptureResult {
    case captured(TextCapture)
    case failed(String)
}

/// Reads the text under the caret out of whatever app has focus, and writes the fixed version back.
///
/// Unlike Windows, macOS *does* offer a way to ask another application about the text it is
/// showing: the Accessibility API. When the focused element answers, TextFix reads the selection
/// directly - it learns exactly what is selected instead of inferring it, spends no pasteboard
/// round trip, and synthesises no keys at all for the read. That is the fast path and it is what
/// runs in native apps, Safari, Chrome and most Electron hosts.
///
/// When the focused element publishes nothing usable - a canvas-rendered editor, a game, an app
/// with accessibility switched off - it falls back to what the user's own hands would do: park a
/// unique marker on the pasteboard, press Cmd+C, and see whether the marker is still there. The
/// marker is what makes "was anything selected" decidable, since copying the same text twice leaves
/// the pasteboard byte-identical and `changeCount` moves for every other writer on the system.
enum TextTarget {
    /// A short messaging timeout, set once on the system-wide element. Without it a hung or
    /// beachballing app can block the main thread inside an AX call for the system default, which
    /// would freeze the menu bar item along with it.
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    // ---- capture ----

    /// - Parameter onTargetResolved: called once the focused element is known and has passed the
    ///   secure-field check, with its caret rectangle if it publishes one. This is where the caller
    ///   puts its indicator on screen: everything after it can take the better part of a second on
    ///   the pasteboard path, and a hotkey that changes nothing for that long reads as a dead key.
    static func capture(
        options: CaptureOptions, onTargetResolved: (CGRect?) -> Void
    ) -> CaptureResult {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return .failed("No app has focus.")
        }
        let pid = frontmost.processIdentifier

        // The hotkeys stay registered while the settings window is open, so a press there would
        // otherwise send TextFix's own prompt or model field off to be rewritten.
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            return .failed("Switch to the app with your text first.")
        }

        if let bundle = frontmost.bundleIdentifier, terminalBundles.contains(bundle) {
            // A terminal publishes its whole scrollback as the field's value - output, paths,
            // tokens - and pasting back into it types into the shell.
            return .failed("TextFix does not work in terminal windows.")
        }

        guard isTrusted else {
            return .failed("TextFix needs Accessibility permission to read the text.")
        }

        let element = focusedElement()
        if options.skipPasswordFields, let element, isSecureField(element) {
            return .failed("That looks like a password field, so nothing was sent.")
        }

        onTargetResolved(element.flatMap {
            caretRect(element: $0, range: Ax.range($0, kAXSelectedTextRangeAttribute))
        })

        // Fast path: ask the element directly. It borrows nothing, so it snapshots nothing: the
        // replace takes its own snapshot just before it pastes, which also means a copy the user
        // makes while the request is out is what they get back.
        if options.useAccessibilityRead, let element,
           let capture = captureViaAccessibility(element: element, pid: pid, options: options) {
            return .captured(capture)
        }

        // Taken before the probe overwrites the pasteboard. This path cannot work without
        // borrowing it.
        let saved = options.takeSnapshot ? PasteboardBridge.snapshot() : nil
        return capturePasteboard(element: element, pid: pid, options: options, saved: saved)
    }

    /// Terminal emulators, by bundle identifier.
    private static let terminalBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
        "co.zeit.hyper", "com.mitchellh.ghostty", "org.tabby",
    ]

    private static func captureViaAccessibility(
        element: AXUIElement, pid: pid_t, options: CaptureOptions
    ) -> TextCapture? {
        // An element that answers neither of these is not a text control we can work with, and
        // falling through to the pasteboard probe is the right answer for it.
        let selected = Ax.string(element, kAXSelectedTextAttribute)
        let selectedRange = Ax.range(element, kAXSelectedTextRangeAttribute)

        if let selected, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.debug("AX read: \(selected.count) selected characters")
            return TextCapture(
                text: selected, mode: .selection, source: .accessibility, element: element,
                appPid: pid, fullRange: selectedRange, saved: nil,
                caretRect: caretRect(element: element, range: selectedRange))
        }

        guard options.allowSelectAll else { return nil }

        guard let whole = Ax.string(element, kAXValueAttribute),
              !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let length = Ax.int(element, kAXNumberOfCharactersAttribute) ?? whole.utf16.count
        Log.debug("AX read: whole field, \(whole.count) characters")
        return TextCapture(
            text: whole, mode: .wholeText, source: .accessibility, element: element,
            appPid: pid, fullRange: CFRange(location: 0, length: length), saved: nil,
            caretRect: caretRect(element: element, range: selectedRange))
    }

    private static func capturePasteboard(
        element: AXUIElement?, pid: pid_t, options: CaptureOptions, saved: PasteboardSnapshot?
    ) -> CaptureResult {
        var probeMarker: String?

        // Every failure below happens after the pasteboard has been overwritten with a probe
        // marker, so failing has to put the user's pasteboard back. Nothing else in the pipeline
        // knows a capture was in progress, so the cleanup belongs here.
        func cleanup(_ message: String) -> CaptureResult {
            if let saved {
                PasteboardBridge.restoreOrClear(saved)
            } else if let probeMarker,
                      PasteboardBridge.text(maxUTF16: probeMarker.utf16.count + 1) == probeMarker {
                PasteboardBridge.clear()
            }
            return .failed(message)
        }

        /// CGEvent.post reports nothing, so a chord that went nowhere looks exactly like an empty
        /// field. The one cause the user can act on is the permission, so ask about it before
        /// telling them a field they can see has text in it is empty.
        func readFailureMessage() -> String {
            if !isTrusted || Keystrokes.lastSendBlocked {
                return "macOS blocked keyboard input. Grant TextFix Accessibility permission."
            }
            return "Could not read any text from that field."
        }

        Keystrokes.clearSendBlocked()

        let marker = PasteboardBridge.newProbeMarker()
        probeMarker = marker
        guard PasteboardBridge.setText(marker, transient: true, concealed: true) else {
            return cleanup("Could not use the pasteboard.")
        }
        let baseline = PasteboardBridge.changeCount

        guard Keystrokes.sendCommandChord("c") else {
            return cleanup("Could not send keys to that app. Check Accessibility permission.")
        }

        var mode = CaptureMode.selection
        var text = PasteboardBridge.waitForCopy(
            marker: marker, baseline: baseline, timeoutMs: options.selectionProbeMs,
            maxUTF16: options.maxUTF16)
        // Read into a constant first: the log message is built later, on the log queue, and must
        // not read a variable this function goes on to change.
        let probeLength = text?.count
        Log.debug("Selection probe: \(probeLength.map { "\($0) characters" } ?? "nothing selected")")

        if text == nil || text!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard options.allowSelectAll else { return cleanup("Nothing is selected.") }

            // Nothing was selected: take the whole field. Cmd+A leaves it selected, so the paste at
            // the end replaces exactly what was read. The select-all needs a gap before the copy
            // asks for its result, or an app that handles both chords in one batch answers from the
            // pre-selection state.
            func readWholeField(settleMs: Int, chordDelayMs: Int?) -> String? {
                guard Keystrokes.sendCommandChord("a", eventDelayMsOverride: chordDelayMs) else { return nil }
                Keystrokes.sleep(ms: settleMs)

                let nextMarker = PasteboardBridge.newProbeMarker()
                probeMarker = nextMarker
                guard PasteboardBridge.setText(nextMarker, transient: true, concealed: true) else { return nil }
                let mark = PasteboardBridge.changeCount
                guard Keystrokes.sendCommandChord("c", eventDelayMsOverride: chordDelayMs) else { return nil }
                return PasteboardBridge.waitForCopy(
                    marker: nextMarker, baseline: mark, timeoutMs: options.copyTimeoutMs,
                    maxUTF16: options.maxUTF16)
            }

            text = readWholeField(settleMs: Keystrokes.chordSettleMs, chordDelayMs: nil)
            if text == nil || text!.isEmpty {
                // One slower retry: spaced-out key events and a longer settle. It is idempotent -
                // selecting and copying twice changes nothing in the field - and it costs a few
                // hundred milliseconds only on a read that was going to fail anyway.
                Log.debug("Whole-field read came back empty; retrying with spaced-out key events")
                text = readWholeField(
                    settleMs: Keystrokes.slowChordSettleMs, chordDelayMs: Keystrokes.slowKeyEventDelayMs)
            }
            guard let whole = text, !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return cleanup(readFailureMessage())
            }
            text = whole
            mode = .wholeText
        }

        guard let captured = text, !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return cleanup("There is no text to fix here.")
        }

        return .captured(TextCapture(
            text: captured, mode: mode, source: .pasteboard, element: element, appPid: pid,
            fullRange: nil, saved: saved,
            caretRect: element.flatMap { caretRect(element: $0, range: Ax.range($0, kAXSelectedTextRangeAttribute)) }))
    }

    // ---- replace ----

    /// - Parameter beforePaste: called once, just before the pasteboard is borrowed for a paste,
    ///   and not at all when the text goes back without one. The caller's chance to snapshot what
    ///   the user is holding at that moment.
    static func replace(
        capture: TextCapture, with replacement: String, requireSameFocus: Bool, mode: ReplaceMode,
        beforePaste: () -> Void
    ) -> ReplaceOutcome {
        if requireSameFocus {
            guard let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.processIdentifier == capture.appPid else {
                return .focusChanged
            }
            if let original = capture.element {
                guard let current = focusedElement(), CFEqual(current, original) else {
                    return .focusChanged
                }
            }
            // Same field is not enough. A click elsewhere in it while the request was out moves
            // the selection, and a paste would then insert the fix there and keep the original;
            // typing during the wait changes the text a whole-field replace would write over.
            if capture.source == .accessibility, let element = capture.element {
                let current = capture.mode == .selection
                    ? Ax.string(element, kAXSelectedTextAttribute)
                    : Ax.string(element, kAXValueAttribute)
                if let current, current != capture.text {
                    Log.debug("The text under the caret changed during the request")
                    return .focusChanged
                }
            }
        }

        if mode == .accessibility, let element = capture.element, capture.source == .accessibility {
            switch replaceViaAccessibility(element: element, capture: capture, replacement: replacement) {
            case .success:
                return .replaced
            case .cannotComplete:
                // The app did not answer in time, which is not the same as refusing: the write
                // may still land, and a paste on top of it would put the text in twice.
                return .unconfirmed
            default:
                Log.debug("Accessibility write was refused; falling back to a paste")
            }
        }

        return replaceViaPaste(capture: capture, replacement: replacement, beforePaste: beforePaste)
    }

    private static func replaceViaAccessibility(
        element: AXUIElement, capture: TextCapture, replacement: String
    ) -> AXError {
        if capture.mode == .wholeText, let range = capture.fullRange {
            guard Ax.setRange(element, kAXSelectedTextRangeAttribute, range) else { return .failure }
        }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, replacement as CFString)
    }

    private static func replaceViaPaste(
        capture: TextCapture, replacement: String, beforePaste: () -> Void
    ) -> ReplaceOutcome {
        // A whole-field capture read through AX never selected anything, so a bare Cmd+V would
        // insert at the caret and leave the original text in place. Select the field first - a pure
        // selection change, which costs the user no undo step.
        if capture.source == .accessibility && capture.mode == .wholeText {
            var selected = false
            if let element = capture.element, let range = capture.fullRange {
                selected = Ax.setRange(element, kAXSelectedTextRangeAttribute, range)
            }
            if !selected {
                Keystrokes.clearSendBlocked()
                guard Keystrokes.sendCommandChord("a") else {
                    return Keystrokes.lastSendBlocked ? .blocked : .failed
                }
                Keystrokes.sleep(ms: Keystrokes.chordSettleMs)
            }
        }

        beforePaste()
        guard PasteboardBridge.setText(replacement, transient: true) else { return .failed }

        Keystrokes.clearSendBlocked()
        guard Keystrokes.sendCommandChord("v") else {
            return Keystrokes.lastSendBlocked ? .blocked : .failed
        }
        // CGEvent.post has no return value, so a permission revoked since the capture would
        // otherwise look exactly like a successful paste. This is the one question with an answer.
        guard isTrusted else { return .blocked }
        return .replaced
    }

    // ---- accessibility helpers ----

    static func focusedElement() -> AXUIElement? {
        guard let value = Ax.copy(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        if let subrole = Ax.string(element, kAXSubroleAttribute),
           subrole == (kAXSecureTextFieldSubrole as String) {
            Log.debug("Refused: the focused element is a secure text field")
            return true
        }
        return false
    }

    /// The caret rectangle in Quartz screen coordinates, or nil when the focused app publishes
    /// none. Used only to place the indicator.
    static func caretRect(element: AXUIElement, range: CFRange?) -> CGRect? {
        if let range {
            // A zero-length range is the caret itself; a few hosts answer only for a real span, so
            // one character is the fallback.
            for probe in [CFRange(location: range.location, length: 0),
                          CFRange(location: range.location, length: 1)] {
                if let rect = Ax.bounds(element, for: probe), rect.width >= 0, rect.height > 0 {
                    return rect
                }
            }
        }
        // No usable range: fall back to the bottom-left of the field itself, which is still closer
        // to the user's eye than the mouse pointer.
        if let position = Ax.point(element, kAXPositionAttribute),
           let size = Ax.size(element, kAXSizeAttribute), size.height > 0 {
            return CGRect(x: position.x, y: position.y, width: 1, height: size.height)
        }
        return nil
    }
}

/// The small slice of the Accessibility API this app uses, wrapped so the call sites read as
/// intent rather than as CFTypeRef plumbing.
enum Ax {
    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return (value as! CFString) as String
    }

    static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }
        return ((value as! CFNumber) as NSNumber).intValue
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var result = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &result) else { return nil }
        return result
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var result = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &result) else { return nil }
        return result
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var result = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &result) else { return nil }
        return result
    }

    static func bounds(_ element: AXUIElement, for range: CFRange) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &result) else { return nil }
        return result
    }

    @discardableResult
    static func setString(_ element: AXUIElement, _ attribute: String, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFString) == .success
    }

    @discardableResult
    static func setRange(_ element: AXUIElement, _ attribute: String, _ range: CFRange) -> Bool {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }
}
