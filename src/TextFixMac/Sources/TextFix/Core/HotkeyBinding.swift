// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Carbon.HIToolbox

/// A global hotkey, stored in config.json as text ("Cmd+Opt+J", "F13") so it stays hand-editable,
/// and converted here to the shapes RegisterEventHotKey and NSEvent expect.
///
/// Displayed with the usual glyphs - the menu bar shows "⌃⌥J", not "Ctrl+Opt+J" - because that is
/// what every other macOS app shows and what is printed on the user's keycaps.
struct HotkeyBinding: Equatable {
    /// Carbon modifier mask: cmdKey / shiftKey / optionKey / controlKey.
    let modifiers: UInt32

    /// A virtual key code (kVK_*), not a character: the binding survives a keyboard layout change.
    let keyCode: UInt32

    static let none = HotkeyBinding(modifiers: 0, keyCode: UInt32.max)

    var isEmpty: Bool { keyCode == UInt32.max }

    // ---- parsing ----

    static func parse(_ text: String?) -> HotkeyBinding? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var keyCode: UInt32?

        for rawPart in text.split(separator: "+") {
            let part = rawPart.trimmingCharacters(in: .whitespaces).lowercased()
            if part.isEmpty { continue }
            switch part {
            case "cmd", "command", "meta", "super", "win", "windows", "⌘":
                modifiers |= UInt32(cmdKey)
                continue
            case "opt", "option", "alt", "⌥":
                modifiers |= UInt32(optionKey)
                continue
            case "ctrl", "control", "⌃":
                modifiers |= UInt32(controlKey)
                continue
            case "shift", "⇧":
                modifiers |= UInt32(shiftKey)
                continue
            default:
                break
            }
            if keyCode != nil { return nil } // two non-modifier keys: not a hotkey
            guard let code = KeyNames.keyCode(for: part) else { return nil }
            keyCode = code
        }
        guard let keyCode else { return nil }
        return HotkeyBinding(modifiers: modifiers, keyCode: keyCode)
    }

    /// The form written to config.json. Spelled out rather than glyphed so the file stays
    /// something you can type into a text editor.
    func format() -> String {
        if isEmpty { return "" }
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Ctrl") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Opt") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Cmd") }
        parts.append(KeyNames.name(for: keyCode))
        return parts.joined(separator: "+")
    }

    /// The form shown on screen: ⌃⌥⇧⌘ in Apple's canonical order, then the key.
    func display() -> String {
        if isEmpty { return "" }
        var glyphs = ""
        if modifiers & UInt32(controlKey) != 0 { glyphs += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { glyphs += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { glyphs += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { glyphs += "⌘" }
        return glyphs + KeyNames.displayName(for: keyCode)
    }

    // ---- NSEvent bridge, for the recorder in the settings window ----

    static func from(event: NSEvent) -> HotkeyBinding {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return HotkeyBinding(modifiers: modifiers, keyCode: UInt32(event.keyCode))
    }

    /// F13 through F20 exist precisely because no keyboard sends them by accident, which makes
    /// them the only keys worth claiming globally without a modifier. They are also what a VIA or
    /// QMK board can be told to send from a spare key.
    var isSafeWithoutModifiers: Bool {
        KeyNames.functionKeys13Through20.contains(keyCode)
    }
}

enum KeyNames {
    /// Written as an array of pairs rather than a literal dictionary so the canonical name for a
    /// key code is simply the first entry that mentions it - the aliases below it are accepted on
    /// input and never used for display.
    private static let table: [(String, Int)] = [
        ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
        ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
        ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
        ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
        ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
        ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
        ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),

        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
        ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
        ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),

        ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4), ("f5", kVK_F5),
        ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10),
        ("f11", kVK_F11), ("f12", kVK_F12), ("f13", kVK_F13), ("f14", kVK_F14), ("f15", kVK_F15),
        ("f16", kVK_F16), ("f17", kVK_F17), ("f18", kVK_F18), ("f19", kVK_F19), ("f20", kVK_F20),

        ("space", kVK_Space), ("enter", kVK_Return), ("return", kVK_Return),
        ("tab", kVK_Tab), ("esc", kVK_Escape), ("escape", kVK_Escape),
        ("delete", kVK_Delete), ("backspace", kVK_Delete),
        ("forwarddelete", kVK_ForwardDelete), ("del", kVK_ForwardDelete),
        ("home", kVK_Home), ("end", kVK_End),
        ("pageup", kVK_PageUp), ("pagedown", kVK_PageDown),
        ("left", kVK_LeftArrow), ("right", kVK_RightArrow),
        ("up", kVK_UpArrow), ("down", kVK_DownArrow),
        ("help", kVK_Help), ("insert", kVK_Help),

        // Named rather than punctuated so nothing collides with the "+" separator.
        ("semicolon", kVK_ANSI_Semicolon), ("plus", kVK_ANSI_Equal), ("equal", kVK_ANSI_Equal),
        ("comma", kVK_ANSI_Comma), ("minus", kVK_ANSI_Minus), ("period", kVK_ANSI_Period),
        ("slash", kVK_ANSI_Slash), ("backquote", kVK_ANSI_Grave),
        ("lbracket", kVK_ANSI_LeftBracket), ("backslash", kVK_ANSI_Backslash),
        ("rbracket", kVK_ANSI_RightBracket), ("quote", kVK_ANSI_Quote),

        ("numpad0", kVK_ANSI_Keypad0), ("numpad1", kVK_ANSI_Keypad1), ("numpad2", kVK_ANSI_Keypad2),
        ("numpad3", kVK_ANSI_Keypad3), ("numpad4", kVK_ANSI_Keypad4), ("numpad5", kVK_ANSI_Keypad5),
        ("numpad6", kVK_ANSI_Keypad6), ("numpad7", kVK_ANSI_Keypad7), ("numpad8", kVK_ANSI_Keypad8),
        ("numpad9", kVK_ANSI_Keypad9),
        ("numpadmultiply", kVK_ANSI_KeypadMultiply), ("numpadadd", kVK_ANSI_KeypadPlus),
        ("numpadsubtract", kVK_ANSI_KeypadMinus), ("numpaddecimal", kVK_ANSI_KeypadDecimal),
        ("numpaddivide", kVK_ANSI_KeypadDivide), ("numpadenter", kVK_ANSI_KeypadEnter),
    ]

    private static let byName: [String: UInt32] = {
        var map: [String: UInt32] = [:]
        map.reserveCapacity(table.count)
        for (name, code) in table { map[name] = UInt32(code) }
        return map
    }()

    private static let byCode: [UInt32: String] = {
        var map: [UInt32: String] = [:]
        // First mention wins, so "enter" beats "return" and "delete" beats "backspace".
        for (name, code) in table where map[UInt32(code)] == nil { map[UInt32(code)] = name }
        return map
    }()

    static let functionKeys13Through20: Set<UInt32> = [
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    static func keyCode(for lowerName: String) -> UInt32? { byName[lowerName] }

    /// The name written to config.json.
    static func name(for keyCode: UInt32) -> String {
        guard let raw = byCode[keyCode] else { return "0x" + String(keyCode, radix: 16, uppercase: true) }
        switch raw {
        case "pageup": return "PageUp"
        case "pagedown": return "PageDown"
        case "forwarddelete": return "ForwardDelete"
        case "lbracket": return "LBracket"
        case "rbracket": return "RBracket"
        default:
            if raw.count > 1, raw.hasPrefix("f"), raw.dropFirst().allSatisfy(\.isNumber) {
                return raw.uppercased()
            }
            if raw.hasPrefix("numpad") { return "Numpad" + raw.dropFirst(6).capitalizedFirst }
            return raw.capitalizedFirst
        }
    }

    /// The glyph shown on screen. Arrow keys, Return and friends have keycap symbols that every
    /// Mac user reads faster than the word.
    static func displayName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: return name(for: keyCode).uppercased()
        }
    }
}

extension StringProtocol {
    var capitalizedFirst: String {
        guard let first else { return String(self) }
        return first.uppercased() + dropFirst()
    }
}
