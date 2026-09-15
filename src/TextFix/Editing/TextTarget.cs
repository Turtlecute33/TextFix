// SPDX-License-Identifier: GPL-3.0-only
using TextFix.Core;
using TextFix.Interop;

namespace TextFix.Editing;

internal enum CaptureMode
{
    /// <summary>The user had text selected, and only that text is fixed.</summary>
    Selection,

    /// <summary>Nothing was selected, so the whole field was selected and is fixed as a unit.</summary>
    WholeText,
}

internal sealed class TextCapture
{
    internal required string Text { get; init; }
    internal required CaptureMode Mode { get; init; }
    internal required nint Foreground { get; init; }
    internal required nint Focus { get; init; }
    internal ClipboardSnapshot? Saved { get; init; }
    internal RECT CaretRect { get; init; }
}

internal enum ReplaceOutcome
{
    Pasted,
    FocusChanged,
    /// <summary>Windows refused to inject keys, almost always an elevated target window.</summary>
    Blocked,
    Failed,
}

internal sealed record CaptureOptions(
    bool AllowSelectAll,
    bool SkipPasswordFields,
    bool TakeSnapshot,
    int SelectionProbeMs,
    int CopyTimeoutMs);

/// <summary>
/// Reads the text under the caret out of whatever app has focus, and writes the fixed version
/// back. There is no Windows equivalent of Android's InputConnection, so this works the way the
/// user's own hands would: copy, then paste over the same selection.
///
/// Selection detection is the interesting part, because Windows will not tell us whether the
/// focused control has a selection. Content comparison cannot answer it (copying the same text
/// twice leaves the clipboard byte-identical) and neither can the clipboard sequence number on its
/// own (it moves for every writer on the desktop, including clipboard history and cloud sync). So
/// a unique marker is parked on the clipboard first: after the probing Ctrl+C, the marker still
/// being there means the selection was empty, and anything else is what the host copied. Only in
/// the first case does the whole-field path select everything.
/// </summary>
internal static unsafe class TextTarget
{
    internal static nint GetFocusWindow(nint foreground)
    {
        if (foreground == 0) return 0;
        uint thread = Win32.GetWindowThreadProcessId(foreground, out _);
        if (thread == 0) return 0;
        var info = new GUITHREADINFO { cbSize = (uint)sizeof(GUITHREADINFO) };
        return Win32.GetGUIThreadInfo(thread, ref info) ? info.hwndFocus : 0;
    }

    /// <summary>
    /// The caret rectangle in screen coordinates, or an empty rectangle when the focused app does
    /// not publish one (Chromium and most Electron apps do not). Used only to place the indicator.
    /// </summary>
    internal static RECT GetCaretRect(nint foreground)
    {
        if (foreground == 0) return default;
        uint thread = Win32.GetWindowThreadProcessId(foreground, out _);
        if (thread == 0) return default;
        var info = new GUITHREADINFO { cbSize = (uint)sizeof(GUITHREADINFO) };
        if (!Win32.GetGUIThreadInfo(thread, ref info)) return default;
        if (info.hwndCaret == 0 || info.rcCaret.IsEmpty) return default;

        var topLeft = new POINT { X = info.rcCaret.Left, Y = info.rcCaret.Top };
        var bottomRight = new POINT { X = info.rcCaret.Right, Y = info.rcCaret.Bottom };
        if (!Win32.ClientToScreen(info.hwndCaret, ref topLeft)) return default;
        if (!Win32.ClientToScreen(info.hwndCaret, ref bottomRight)) return default;
        return new RECT
        {
            Left = topLeft.X,
            Top = topLeft.Y,
            Right = Math.Max(bottomRight.X, topLeft.X + 1),
            Bottom = Math.Max(bottomRight.Y, topLeft.Y + 1),
        };
    }

    internal static bool TryCapture(nint owner, CaptureOptions options, out TextCapture? capture, out string error)
    {
        capture = null;
        error = string.Empty;

        nint foreground = Win32.GetForegroundWindow();
        if (foreground == 0)
        {
            error = "No window has focus.";
            return false;
        }
        nint focus = GetFocusWindow(foreground);
        RECT caret = GetCaretRect(foreground);

        if (options.SkipPasswordFields && LooksLikePasswordField(focus))
        {
            error = "That looks like a password field, so nothing was sent.";
            return false;
        }

        ClipboardSnapshot? saved = options.TakeSnapshot ? ClipboardBridge.Snapshot(owner) : null;
        string? probeMarker = null;

        // Every failure below happens after the clipboard has been overwritten with a probe
        // marker, so failing has to put the user's clipboard back. Nothing else in the pipeline
        // knows a capture was in progress, so the cleanup belongs here; the message is returned
        // rather than assigned because a local function cannot touch an out parameter.
        string Cleanup(string message)
        {
            if (saved != null) ClipboardBridge.RestoreOrClear(saved, owner);
            else if (probeMarker != null && ClipboardBridge.GetText(owner) == probeMarker) ClipboardBridge.Clear(owner);
            return message;
        }

        Keystrokes.ClearSendBlocked();

        // Park a marker on the clipboard so the copy below is detectable even on a desktop with
        // other clipboard writers running.
        probeMarker = ClipboardBridge.NewProbeMarker();
        if (!ClipboardBridge.SetText(probeMarker, owner, transient: true))
        {
            error = Cleanup("Could not use the clipboard. Another app may be holding it.");
            return false;
        }
        uint baseline = ClipboardBridge.SequenceNumber();

        if (!Keystrokes.SendCtrlChord(VK.KEY_C))
        {
            error = Cleanup(Keystrokes.LastSendBlocked
                ? "Windows blocked keyboard input to that window. It is probably running as administrator."
                : "Could not send keys to that window.");
            return false;
        }

        CaptureMode mode = CaptureMode.Selection;
        string? text = ClipboardBridge.WaitForCopy(probeMarker, baseline, options.SelectionProbeMs, owner);
        Log.Debug("Selection probe: " + (text == null ? "nothing selected" : text.Length + " characters"));

        if (string.IsNullOrWhiteSpace(text))
        {
            if (!options.AllowSelectAll)
            {
                error = Cleanup("Nothing is selected.");
                return false;
            }

            // Nothing was selected: take the whole field. Ctrl+A leaves it selected, so the paste
            // at the end replaces exactly what was read. The select-all needs a gap before the
            // copy asks for its result, or an app that handles both chords in one message batch
            // answers from the pre-selection state.
            string? ReadWholeField(int settleMs, int? chordDelayMs)
            {
                if (!Keystrokes.SendCtrlChord(VK.KEY_A, chordDelayMs)) return null;
                Thread.Sleep(settleMs);

                probeMarker = ClipboardBridge.NewProbeMarker();
                if (!ClipboardBridge.SetText(probeMarker, owner, transient: true)) return null;
                uint mark = ClipboardBridge.SequenceNumber();
                if (!Keystrokes.SendCtrlChord(VK.KEY_C, chordDelayMs)) return null;
                return ClipboardBridge.WaitForCopy(probeMarker, mark, options.CopyTimeoutMs, owner);
            }

            text = ReadWholeField(Keystrokes.ChordSettleMs, null);
            if (string.IsNullOrWhiteSpace(text))
            {
                // One slower retry: spaced-out key events and a longer settle. It is idempotent -
                // selecting and copying twice changes nothing in the field - and it costs a few
                // hundred milliseconds only on a read that was going to fail anyway.
                Log.Debug("Whole-field read came back empty; retrying with spaced-out key events");
                text = ReadWholeField(Keystrokes.SlowChordSettleMs, Keystrokes.SlowKeyEventDelayMs);
            }
            Log.Debug("Whole-field read: " + (text == null ? "nothing" : text.Length + " characters"));
            if (string.IsNullOrWhiteSpace(text))
            {
                error = Cleanup("Could not read any text from that field.");
                return false;
            }
            mode = CaptureMode.WholeText;
        }

        if (string.IsNullOrWhiteSpace(text))
        {
            error = Cleanup("There is no text to fix here.");
            return false;
        }

        capture = new TextCapture
        {
            Text = text,
            Mode = mode,
            Foreground = foreground,
            Focus = focus,
            Saved = saved,
            CaretRect = caret,
        };
        return true;
    }

    internal static ReplaceOutcome Replace(nint owner, TextCapture capture, string replacement, bool requireSameFocus)
    {
        if (requireSameFocus)
        {
            nint foreground = Win32.GetForegroundWindow();
            nint focus = GetFocusWindow(foreground);
            bool sameWindow = foreground == capture.Foreground;
            bool sameControl = capture.Focus == 0 || focus == capture.Focus;
            if (!sameWindow || !sameControl) return ReplaceOutcome.FocusChanged;
        }

        if (!ClipboardBridge.SetText(replacement, owner, transient: true)) return ReplaceOutcome.Failed;

        Keystrokes.ClearSendBlocked();
        if (!Keystrokes.SendCtrlChord(VK.KEY_V))
        {
            return Keystrokes.LastSendBlocked ? ReplaceOutcome.Blocked : ReplaceOutcome.Failed;
        }
        return ReplaceOutcome.Pasted;
    }

    /// <summary>
    /// Best-effort password detection. It can only see native edit controls - a password box in a
    /// browser is indistinguishable from any other field from out here - but it costs one style
    /// read and catches Windows dialogs, installers and desktop apps.
    /// </summary>
    private static bool LooksLikePasswordField(nint focus)
    {
        if (focus == 0) return false;
        const long EsPassword = 0x0020;

        string className = Win32.GetClassNameValue(focus);
        if (className.Contains("password", StringComparison.OrdinalIgnoreCase))
        {
            Log.Debug("Refused: focused control class looks like a password field");
            return true;
        }
        bool editLike = className.Equals("Edit", StringComparison.OrdinalIgnoreCase)
            || className.StartsWith("RichEdit", StringComparison.OrdinalIgnoreCase)
            || className.StartsWith("RICHEDIT", StringComparison.Ordinal);
        if (!editLike) return false;

        long style = Win32.GetWindowLongPtr(focus, Win32.GWL_STYLE);
        return (style & EsPassword) != 0;
    }
}
