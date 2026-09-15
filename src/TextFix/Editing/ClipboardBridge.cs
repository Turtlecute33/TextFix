// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.InteropServices;
using TextFix.Core;
using TextFix.Interop;

namespace TextFix.Editing;

internal sealed class ClipboardSnapshot
{
    internal List<(uint Format, byte[] Data)> Blobs { get; } = [];

    /// <summary>False when something on the clipboard could not be captured and will be lost.</summary>
    internal bool Complete { get; set; } = true;

    internal bool IsEmpty => Blobs.Count == 0;
}

/// <summary>
/// Every clipboard operation the fix pipeline needs, with the failure modes Windows actually
/// produces: another process owning the clipboard for a few milliseconds, a format whose handle is
/// not global memory, and clipboard history quietly archiving text that was only ever meant to
/// live for one paste.
/// </summary>
internal static unsafe class ClipboardBridge
{
    // Opening the clipboard fails while another process holds it. That window is milliseconds
    // wide in practice, so a short bounded retry beats reporting a failure to the user.
    private const int OpenAttempts = 12;
    private const int OpenRetryDelayMs = 10;

    // Total ceiling on what we are willing to copy out and back in. A 40 MB screenshot on the
    // clipboard is not worth two 40 MB copies on every fix; above the cap the format is skipped
    // and the user is told the clipboard could not be fully restored.
    private const int MaxSnapshotBytes = 4 * 1024 * 1024;

    private static uint _formatHtml;
    private static uint _formatRtf;
    private static uint _formatPng;
    private static uint _formatExcludeMonitors;
    private static uint _formatNoHistory;
    private static uint _formatNoCloud;
    private static bool _formatsRegistered;

    private static void EnsureFormats()
    {
        if (_formatsRegistered) return;
        _formatHtml = Win32.RegisterClipboardFormat("HTML Format");
        _formatRtf = Win32.RegisterClipboardFormat("Rich Text Format");
        _formatPng = Win32.RegisterClipboardFormat("PNG");
        // The documented opt-outs that keep a transient payload out of clipboard managers, out of
        // Windows clipboard history (Win+V) and out of cloud sync to the user's other devices.
        _formatExcludeMonitors = Win32.RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        _formatNoHistory = Win32.RegisterClipboardFormat("CanIncludeInClipboardHistory");
        _formatNoCloud = Win32.RegisterClipboardFormat("CanUploadToCloudClipboard");
        _formatsRegistered = true;
    }

    internal static uint SequenceNumber() => Win32.GetClipboardSequenceNumber();

    private static bool TryOpen(nint owner)
    {
        for (int attempt = 0; attempt < OpenAttempts; attempt++)
        {
            if (Win32.OpenClipboard(owner)) return true;
            Thread.Sleep(OpenRetryDelayMs);
        }
        Log.Warn("Could not open the clipboard; another process is holding it");
        return false;
    }

    internal static string? GetText(nint owner)
    {
        if (!Win32.IsClipboardFormatAvailable(Win32.CF_UNICODETEXT)) return null;
        if (!TryOpen(owner)) return null;
        try
        {
            nint handle = Win32.GetClipboardData(Win32.CF_UNICODETEXT);
            if (handle == 0) return null;
            nint pointer = Win32.GlobalLock(handle);
            if (pointer == 0) return null;
            try
            {
                nuint bytes = Win32.GlobalSize(handle);
                if (bytes == 0) return null;
                int maxChars = (int)Math.Min(bytes / sizeof(char), int.MaxValue);
                var span = new ReadOnlySpan<char>((char*)pointer, maxChars);
                int end = span.IndexOf('\0');
                return end < 0 ? new string(span) : new string(span[..end]);
            }
            finally
            {
                Win32.GlobalUnlock(handle);
            }
        }
        finally
        {
            Win32.CloseClipboard();
        }
    }

    /// <summary>
    /// Puts <paramref name="text"/> on the clipboard. When <paramref name="transient"/> is set the
    /// payload is flagged so clipboard managers, Windows clipboard history and cloud sync leave it
    /// alone - correct for the one-paste buffer, wrong when we are deliberately handing the user
    /// their fixed text to paste themselves.
    /// </summary>
    internal static bool SetText(string text, nint owner, bool transient)
    {
        EnsureFormats();
        if (!TryOpen(owner)) return false;
        try
        {
            if (!Win32.EmptyClipboard()) return false;
            nint handle = AllocText(text);
            if (handle == 0) return false;
            if (Win32.SetClipboardData(Win32.CF_UNICODETEXT, handle) == 0)
            {
                // Ownership only transfers on success, so on failure the block is still ours.
                Win32.GlobalFree(handle);
                return false;
            }
            if (transient) MarkTransient();
            return true;
        }
        finally
        {
            Win32.CloseClipboard();
        }
    }

    private static void MarkTransient()
    {
        foreach (uint format in stackalloc uint[] { _formatExcludeMonitors, _formatNoHistory, _formatNoCloud })
        {
            if (format == 0) continue;
            nint block = Win32.GlobalAlloc(Win32.GMEM_MOVEABLE, sizeof(uint));
            if (block == 0) continue;
            nint pointer = Win32.GlobalLock(block);
            if (pointer == 0)
            {
                Win32.GlobalFree(block);
                continue;
            }
            *(uint*)pointer = 0;
            Win32.GlobalUnlock(block);
            if (Win32.SetClipboardData(format, block) == 0) Win32.GlobalFree(block);
        }
    }

    private static nint AllocText(string text)
    {
        nuint bytes = (nuint)((text.Length + 1) * sizeof(char));
        nint handle = Win32.GlobalAlloc(Win32.GMEM_MOVEABLE, bytes);
        if (handle == 0) return 0;
        nint pointer = Win32.GlobalLock(handle);
        if (pointer == 0)
        {
            Win32.GlobalFree(handle);
            return 0;
        }
        try
        {
            var destination = new Span<char>((char*)pointer, text.Length + 1);
            text.CopyTo(destination);
            destination[text.Length] = '\0';
        }
        finally
        {
            Win32.GlobalUnlock(handle);
        }
        return handle;
    }

    /// <summary>
    /// Copies out the formats worth restoring: text, files, bitmaps and rich text. Deliberately an
    /// allow-list rather than an enumeration of everything on the clipboard - asking an app like
    /// Excel for all forty formats it advertises forces it to render every one of them, which
    /// costs seconds, and the exotic ones are never what the user is holding on to.
    /// </summary>
    internal static ClipboardSnapshot? Snapshot(nint owner)
    {
        EnsureFormats();
        Span<uint> wanted =
        [
            Win32.CF_UNICODETEXT, Win32.CF_HDROP, Win32.CF_DIB, _formatHtml, _formatRtf, _formatPng,
        ];

        if (!TryOpen(owner)) return null;
        try
        {
            var snapshot = new ClipboardSnapshot();
            int budget = MaxSnapshotBytes;
            foreach (uint format in wanted)
            {
                if (format == 0) continue;
                if (!Win32.IsClipboardFormatAvailable(format)) continue;

                nint handle = Win32.GetClipboardData(format);
                if (handle == 0) continue;
                nuint size = Win32.GlobalSize(handle);
                // Zero means this is not a global-memory handle (a GDI bitmap, say). Copying it
                // would be meaningless, so record that the restore will be partial.
                if (size == 0)
                {
                    snapshot.Complete = false;
                    continue;
                }
                if (size > (nuint)budget)
                {
                    snapshot.Complete = false;
                    continue;
                }
                nint pointer = Win32.GlobalLock(handle);
                if (pointer == 0)
                {
                    snapshot.Complete = false;
                    continue;
                }
                try
                {
                    byte[] data = new byte[(int)size];
                    Marshal.Copy(pointer, data, 0, data.Length);
                    snapshot.Blobs.Add((format, data));
                    budget -= data.Length;
                }
                finally
                {
                    Win32.GlobalUnlock(handle);
                }
            }
            return snapshot;
        }
        finally
        {
            Win32.CloseClipboard();
        }
    }

    internal static void Restore(ClipboardSnapshot snapshot, nint owner)
    {
        if (!TryOpen(owner)) return;
        try
        {
            if (!Win32.EmptyClipboard()) return;
            foreach ((uint format, byte[] data) in snapshot.Blobs)
            {
                nint handle = Win32.GlobalAlloc(Win32.GMEM_MOVEABLE, (nuint)data.Length);
                if (handle == 0) continue;
                nint pointer = Win32.GlobalLock(handle);
                if (pointer == 0)
                {
                    Win32.GlobalFree(handle);
                    continue;
                }
                try
                {
                    Marshal.Copy(data, 0, pointer, data.Length);
                }
                finally
                {
                    Win32.GlobalUnlock(handle);
                }
                if (Win32.SetClipboardData(format, handle) == 0) Win32.GlobalFree(handle);
            }
        }
        finally
        {
            Win32.CloseClipboard();
        }
    }

    /// <summary>
    /// Puts a snapshot back, or clears the clipboard when the snapshot recorded that there was
    /// nothing there to begin with - leaving our own scratch content behind would be a change the
    /// user never asked for.
    /// </summary>
    internal static void RestoreOrClear(ClipboardSnapshot snapshot, nint owner)
    {
        if (snapshot.IsEmpty) Clear(owner);
        else Restore(snapshot, owner);
    }

    /// <summary>
    /// Clears the clipboard entirely. Used when there was nothing to restore, so the fixed text
    /// does not linger after the paste.
    /// </summary>
    internal static void Clear(nint owner)
    {
        if (!TryOpen(owner)) return;
        try
        {
            Win32.EmptyClipboard();
        }
        finally
        {
            Win32.CloseClipboard();
        }
    }

    /// <summary>
    /// A value nothing else will ever put on the clipboard. Written before a probing Ctrl+C so
    /// that "did the copy happen" becomes "is the marker still there", which is decidable.
    /// </summary>
    internal static string NewProbeMarker() => "TextFixprobe" + Guid.NewGuid().ToString("N");

    /// <summary>
    /// Waits for a Ctrl+C to land, and returns what it copied.
    ///
    /// The sequence number alone cannot answer this. It moves on *any* clipboard write, and on a
    /// normal desktop there are several other writers - clipboard history, cloud clipboard sync,
    /// a clipboard manager - so a bump proves nothing about our copy. Comparing content cannot
    /// answer it either, because copying the same text twice leaves the clipboard byte-identical.
    ///
    /// Writing our own marker first makes it decidable: if the clipboard still holds the marker,
    /// the copy did not happen (the selection was empty); if it holds anything else, that is what
    /// the host copied. The sequence number is still used, but only to avoid reading the clipboard
    /// in a tight loop.
    /// </summary>
    internal static string? WaitForCopy(string marker, uint baseline, int timeoutMs, nint owner)
    {
        long deadline = Environment.TickCount64 + timeoutMs;
        uint lastSeen = baseline;
        while (true)
        {
            uint current = Win32.GetClipboardSequenceNumber();
            if (current != lastSeen)
            {
                lastSeen = current;
                string? text = GetText(owner);
                if (text != null && text.Length > 0 && !string.Equals(text, marker, StringComparison.Ordinal))
                {
                    return text;
                }
            }
            if (Environment.TickCount64 >= deadline) return null;
            Thread.Sleep(4);
        }
    }
}
