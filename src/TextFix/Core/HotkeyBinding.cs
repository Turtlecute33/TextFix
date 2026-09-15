// SPDX-License-Identifier: GPL-3.0-only
using TextFix.Interop;

namespace TextFix.Core;

/// <summary>
/// A global hotkey, stored in config.json as text ("Ctrl+Alt+J", "F13") so it stays hand-editable,
/// and converted here to the shapes RegisterHotKey and the msctls_hotkey32 control expect.
/// </summary>
internal readonly record struct HotkeyBinding(uint Modifiers, uint VirtualKey)
{
    // msctls_hotkey32 reports its own modifier bits, which are not the RegisterHotKey ones.
    private const int HotkeyfShift = 0x01;
    private const int HotkeyfControl = 0x02;
    private const int HotkeyfAlt = 0x04;

    internal bool IsEmpty => VirtualKey == 0;

    internal static readonly HotkeyBinding None = new(0, 0);

    internal static bool TryParse(string? text, out HotkeyBinding binding)
    {
        binding = None;
        if (string.IsNullOrWhiteSpace(text)) return false;

        uint modifiers = 0;
        uint vk = 0;
        foreach (string rawPart in text.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            string part = rawPart.ToLowerInvariant();
            switch (part)
            {
                case "ctrl" or "control":
                    modifiers |= Win32.MOD_CONTROL;
                    continue;
                case "alt" or "menu":
                    modifiers |= Win32.MOD_ALT;
                    continue;
                case "shift":
                    modifiers |= Win32.MOD_SHIFT;
                    continue;
                case "win" or "windows" or "super" or "meta":
                    modifiers |= Win32.MOD_WIN;
                    continue;
            }
            if (vk != 0) return false; // two non-modifier keys: not a hotkey
            if (!KeyNames.TryGetVirtualKey(part, out vk)) return false;
        }
        if (vk == 0) return false;
        binding = new HotkeyBinding(modifiers, vk);
        return true;
    }

    internal string Format()
    {
        if (IsEmpty) return string.Empty;
        var parts = new List<string>(4);
        if ((Modifiers & Win32.MOD_CONTROL) != 0) parts.Add("Ctrl");
        if ((Modifiers & Win32.MOD_ALT) != 0) parts.Add("Alt");
        if ((Modifiers & Win32.MOD_SHIFT) != 0) parts.Add("Shift");
        if ((Modifiers & Win32.MOD_WIN) != 0) parts.Add("Win");
        parts.Add(KeyNames.GetName(VirtualKey));
        return string.Join("+", parts);
    }

    /// <summary>Packs into the LOWORD shape HKM_SETHOTKEY expects.</summary>
    internal ushort ToControlValue()
    {
        int flags = 0;
        if ((Modifiers & Win32.MOD_SHIFT) != 0) flags |= HotkeyfShift;
        if ((Modifiers & Win32.MOD_CONTROL) != 0) flags |= HotkeyfControl;
        if ((Modifiers & Win32.MOD_ALT) != 0) flags |= HotkeyfAlt;
        return (ushort)(((uint)flags << 8) | (VirtualKey & 0xFF));
    }

    /// <summary>
    /// Unpacks an HKM_GETHOTKEY result. The control has no concept of the Windows key, so a
    /// Win-modified binding entered by hand in config.json survives a round trip through the
    /// settings window only if the user does not re-record that field.
    /// </summary>
    internal static HotkeyBinding FromControlValue(ushort value)
    {
        uint vk = (uint)(value & 0xFF);
        int flags = (value >> 8) & 0xFF;
        uint modifiers = 0;
        if ((flags & HotkeyfShift) != 0) modifiers |= Win32.MOD_SHIFT;
        if ((flags & HotkeyfControl) != 0) modifiers |= Win32.MOD_CONTROL;
        if ((flags & HotkeyfAlt) != 0) modifiers |= Win32.MOD_ALT;
        return vk == 0 ? None : new HotkeyBinding(modifiers, vk);
    }
}

internal static class KeyNames
{
    private static readonly Dictionary<string, uint> ByName = Build();
    private static readonly Dictionary<uint, string> ByKey = Invert(ByName);

    internal static bool TryGetVirtualKey(string lowerName, out uint vk) => ByName.TryGetValue(lowerName, out vk);

    internal static string GetName(uint vk) => ByKey.TryGetValue(vk, out string? name) ? name : "0x" + vk.ToString("X2");

    private static Dictionary<string, uint> Build()
    {
        var map = new Dictionary<string, uint>(StringComparer.Ordinal);

        for (uint c = 'A'; c <= 'Z'; c++) map[char.ToLowerInvariant((char)c).ToString()] = c;
        for (uint d = '0'; d <= '9'; d++) map[((char)d).ToString()] = d;
        for (uint f = 1; f <= 24; f++) map["f" + f] = 0x6F + f;
        for (uint n = 0; n <= 9; n++) map["numpad" + n] = 0x60 + n;

        map["space"] = 0x20;
        map["enter"] = 0x0D;
        map["return"] = 0x0D;
        map["tab"] = 0x09;
        map["esc"] = 0x1B;
        map["escape"] = 0x1B;
        map["backspace"] = 0x08;
        map["insert"] = 0x2D;
        map["delete"] = 0x2E;
        map["del"] = 0x2E;
        map["home"] = 0x24;
        map["end"] = 0x23;
        map["pageup"] = 0x21;
        map["pagedown"] = 0x22;
        map["left"] = 0x25;
        map["up"] = 0x26;
        map["right"] = 0x27;
        map["down"] = 0x28;
        map["printscreen"] = 0x2C;
        map["scrolllock"] = 0x91;
        map["pause"] = 0x13;
        map["capslock"] = 0x14;
        map["apps"] = 0x5D;
        map["numlock"] = 0x90;
        map["numpadmultiply"] = 0x6A;
        map["numpadadd"] = 0x6B;
        map["numpadsubtract"] = 0x6D;
        map["numpaddecimal"] = 0x6E;
        map["numpaddivide"] = 0x6F;
        // Named rather than punctuated so nothing collides with the "+" separator.
        map["semicolon"] = 0xBA;
        map["plus"] = 0xBB;
        map["comma"] = 0xBC;
        map["minus"] = 0xBD;
        map["period"] = 0xBE;
        map["slash"] = 0xBF;
        map["backquote"] = 0xC0;
        map["lbracket"] = 0xDB;
        map["backslash"] = 0xDC;
        map["rbracket"] = 0xDD;
        map["quote"] = 0xDE;
        return map;
    }

    private static Dictionary<uint, string> Invert(Dictionary<string, uint> source)
    {
        var result = new Dictionary<uint, string>();
        // Canonical display names, chosen before the aliases so "Enter" wins over "Return".
        string[] canonical =
        [
            "space", "enter", "tab", "esc", "backspace", "insert", "delete", "home", "end",
            "pageup", "pagedown", "left", "up", "right", "down", "printscreen", "scrolllock",
            "pause", "capslock", "apps", "numlock", "numpadmultiply", "numpadadd",
            "numpadsubtract", "numpaddecimal", "numpaddivide", "semicolon", "plus", "comma",
            "minus", "period", "slash", "backquote", "lbracket", "backslash", "rbracket", "quote",
        ];
        foreach (string name in canonical)
        {
            if (source.TryGetValue(name, out uint vk)) result[vk] = Display(name);
        }
        foreach ((string name, uint vk) in source)
        {
            if (!result.ContainsKey(vk)) result[vk] = Display(name);
        }
        return result;
    }

    private static string Display(string lowerName) => lowerName switch
    {
        "pageup" => "PageUp",
        "pagedown" => "PageDown",
        "printscreen" => "PrintScreen",
        "scrolllock" => "ScrollLock",
        "capslock" => "CapsLock",
        "numlock" => "NumLock",
        "numpadmultiply" => "NumpadMultiply",
        "numpadadd" => "NumpadAdd",
        "numpadsubtract" => "NumpadSubtract",
        "numpaddecimal" => "NumpadDecimal",
        "numpaddivide" => "NumpadDivide",
        "lbracket" => "LBracket",
        "rbracket" => "RBracket",
        _ when lowerName.Length > 1 && lowerName[0] == 'f' && char.IsAsciiDigit(lowerName[1]) => lowerName.ToUpperInvariant(),
        _ when lowerName.StartsWith("numpad", StringComparison.Ordinal) => "Numpad" + lowerName[6..],
        _ => char.ToUpperInvariant(lowerName[0]) + lowerName[1..],
    };
}
