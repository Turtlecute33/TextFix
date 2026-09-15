// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.InteropServices;
using TextFix.Core;
using TextFix.Interop;

namespace TextFix.Editing;

/// <summary>
/// Synthesised key chords. Two details matter more than the rest:
///
/// 1. The hotkey's own modifiers are still physically down when the handler runs. Sending Ctrl+C
///    on top of a held Alt produces Ctrl+Alt+C, which is a different command in most editors, so
///    every held modifier is released first.
/// 2. SendInput cannot reach a window owned by a process at a higher integrity level. That shows
///    up as a zero return with ERROR_ACCESS_DENIED, and it is worth telling the user about rather
///    than leaving them with a hotkey that silently does nothing in one app.
/// </summary>
internal static unsafe class Keystrokes
{
    private const int ErrorAccessDenied = 5;

    /// <summary>
    /// Time given to the target app to process the modifier release before the chord arrives.
    /// Without a gap, fast apps occasionally see the chord while they still believe Alt is down.
    /// </summary>
    internal const int ModifierSettleMs = 12;

    /// <summary>
    /// Time given to the target app between two chords that depend on each other, such as the
    /// Ctrl+A that must take effect before the Ctrl+C that reads its result.
    /// </summary>
    internal const int ChordSettleMs = 20;

    /// <summary>Widened settle and per-event delay used for the one retry of a failed read.</summary>
    internal const int SlowChordSettleMs = 90;

    internal const int SlowKeyEventDelayMs = 12;

    private static readonly int[] ModifierKeys =
    [
        VK.LCONTROL, VK.RCONTROL, VK.LMENU, VK.RMENU, VK.LSHIFT, VK.RSHIFT, VK.LWIN, VK.RWIN,
    ];

    /// <summary>Releases any modifier the user is physically holding. Returns true if it sent anything.</summary>
    internal static bool ReleaseHeldModifiers()
    {
        Span<INPUT> inputs = stackalloc INPUT[ModifierKeys.Length];
        int count = 0;
        foreach (int vk in ModifierKeys)
        {
            if ((Win32.GetAsyncKeyState(vk) & 0x8000) == 0) continue;
            inputs[count++] = KeyEvent((ushort)vk, up: true);
        }
        if (count == 0) return false;
        // Logged because a modifier still being down mid-fix is the signature of a held hotkey
        // re-asserting itself through auto-repeat, which is worth being able to see in a log.
        Log.Debug("Released " + count + " held modifier(s) before sending a chord");
        Send(inputs[..count]);
        return true;
    }

    /// <summary>
    /// Pause between the individual key events of one chord, or 0 to send the chord as a single
    /// atomic SendInput batch.
    ///
    /// One batch looks like the obviously correct choice and is not: hosts that sample the
    /// keyboard on their own schedule rather than per message can see a chord delivered in a
    /// single tick with the modifier not yet applied, and simply drop it. Telegram Desktop does
    /// exactly this with Ctrl+A. Set from keyEventDelayMs in config.json, which defaults to 12.
    /// </summary>
    internal static int KeyEventDelayMs { get; set; } = 12;

    /// <summary>
    /// Sends Ctrl plus one key, for example Ctrl+C, after clearing any modifier the user is
    /// holding. Pass <paramref name="eventDelayMsOverride"/> to spread this one chord out further
    /// than the configured default.
    /// </summary>
    internal static bool SendCtrlChord(ushort key, int? eventDelayMsOverride = null)
    {
        // Checked before *every* chord rather than once per fix, because a physically held key
        // keeps re-asserting itself: Windows auto-repeats a held modifier after roughly 250 ms, so
        // the modifiers released at the start of a fix are down again by the time a chord goes out
        // a few hundred milliseconds later. That turned the whole-field Ctrl+A into Ctrl+Alt+A for
        // anyone who holds their hotkey for longer than an instant, which selects nothing.
        if (ReleaseHeldModifiers()) Thread.Sleep(ModifierSettleMs);

        Span<INPUT> chord =
        [
            KeyEvent(VK.CONTROL, up: false),
            KeyEvent(key, up: false),
            KeyEvent(key, up: true),
            KeyEvent(VK.CONTROL, up: true),
        ];
        int delay = eventDelayMsOverride ?? KeyEventDelayMs;
        if (delay <= 0) return Send(chord);

        Span<INPUT> single = stackalloc INPUT[1];
        for (int i = 0; i < chord.Length; i++)
        {
            single[0] = chord[i];
            if (!Send(single)) return false;
            if (i < chord.Length - 1) Thread.Sleep(delay);
        }
        return true;
    }

    private static INPUT KeyEvent(ushort vk, bool up)
    {
        uint flags = up ? Win32.KEYEVENTF_KEYUP : 0;
        if (IsExtended(vk)) flags |= Win32.KEYEVENTF_EXTENDEDKEY;
        return new INPUT
        {
            type = Win32.INPUT_KEYBOARD,
            U = new INPUTUNION
            {
                ki = new KEYBDINPUT
                {
                    wVk = vk,
                    // Filled in even though the virtual key is authoritative: a few hosts read the
                    // scan code instead, and an empty one makes their key handling misbehave.
                    wScan = (ushort)Win32.MapVirtualKey(vk, 0),
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = 0,
                },
            },
        };
    }

    private static bool IsExtended(ushort vk) => vk is VK.RCONTROL or VK.RMENU or VK.LWIN or VK.RWIN;

    private static bool Send(Span<INPUT> inputs)
    {
        fixed (INPUT* pointer = inputs)
        {
            uint sent = Win32.SendInput((uint)inputs.Length, pointer, sizeof(INPUT));
            if (sent == (uint)inputs.Length) return true;
            int error = Marshal.GetLastWin32Error();
            LastSendBlocked = error == ErrorAccessDenied;
            Log.Warn("SendInput delivered " + sent + " of " + inputs.Length + " events (error " + error + ")");
            return false;
        }
    }

    /// <summary>
    /// True when the last failure was Windows refusing to inject into a higher-integrity window,
    /// which is the one SendInput failure with a useful explanation for the user.
    /// </summary>
    internal static bool LastSendBlocked { get; private set; }

    internal static void ClearSendBlocked() => LastSendBlocked = false;
}
