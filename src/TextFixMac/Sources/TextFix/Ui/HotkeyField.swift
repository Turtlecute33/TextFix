// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Carbon.HIToolbox

/// A field that records a key combination: click it, press the keys you want, done.
///
/// macOS has no equivalent of the Windows msctls_hotkey32 control, so this is the one piece of UI
/// the port had to build from nothing. The two things that make it feel right are catching
/// Cmd-based combinations before AppKit turns them into menu key equivalents, and refusing to
/// record a bare letter - claiming `A` globally would break typing everywhere on the machine.
final class HotkeyField: NSView {
    var binding: HotkeyBinding? {
        didSet {
            needsDisplay = true
            publishAccessibilityValue()
        }
    }

    /// Called with the new binding, or nil when the field was cleared.
    var onChange: ((HotkeyBinding?) -> Void)?

    /// Called with a complaint when the user pressed something that cannot be a global hotkey, so
    /// the window can say why nothing was recorded.
    var onRejected: ((String) -> Void)?

    private var recording = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Hotkey")
        setAccessibilityHelp("Focus this field and press the key combination you want.")
        publishAccessibilityValue()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The combination is drawn, not laid out, so without this VoiceOver can say that a hotkey
    /// field exists but never what is in it - which is the only thing about it worth knowing.
    private func publishAccessibilityValue() {
        if let binding, !binding.isEmpty {
            setAccessibilityValue(binding.format())
        } else {
            setAccessibilityValue("Not set")
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 22) }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        recording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// Cmd-based combinations never reach keyDown - AppKit offers them to the menu bar first - so
    /// they are intercepted here while the field is recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return false }
        return handle(event)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            window?.makeFirstResponder(nil)
            return true
        case kVK_Delete, kVK_ForwardDelete:
            binding = nil
            onChange?(nil)
            window?.makeFirstResponder(nil)
            return true
        case kVK_Tab where !event.modifierFlags.contains(.command):
            // Leave Tab alone so the field can be stepped past with the keyboard.
            return false
        default:
            break
        }

        let candidate = HotkeyBinding.from(event: event)
        if candidate.modifiers == 0 && !candidate.isSafeWithoutModifiers {
            onRejected?(
                "\(candidate.display()) on its own would be swallowed everywhere on this Mac. "
                + "Add Control, Option, Shift or Command, or use one of F13-F20.")
            return true
        }
        binding = candidate
        onChange?(candidate)
        window?.makeFirstResponder(nil)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)

        NSColor.textBackgroundColor.setFill()
        path.fill()

        if recording {
            // Doubles as the focus ring: focusing this field *is* recording, so one indicator
            // covers both, and at two points it clears the same bar a real focus ring has to.
            NSColor.keyboardFocusIndicatorColor.setStroke()
            path.lineWidth = 2
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        path.stroke()

        let text: String
        let color: NSColor
        if recording {
            text = "Press keys…"
            color = .secondaryLabelColor
        } else if let binding, !binding.isEmpty {
            text = binding.display()
            color = .labelColor
        } else {
            text = "Click to set"
            color = .tertiaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .regular : .medium),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
