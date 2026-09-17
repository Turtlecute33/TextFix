// SPDX-License-Identifier: GPL-3.0-only
using System.Collections.Concurrent;
using System.Text;

namespace TextFix.Core;

/// <summary>
/// A deliberately small rolling log. It records what the agent tried and how the provider
/// answered - never the text being fixed, never a clipboard payload, never an API key. Those are
/// the whole point of the app being local, and a log file is the easiest place to leak them.
///
/// Writing happens on a single background thread rather than on the caller. A fix must never wait
/// on a disk write - several lines are written from the message thread during a capture, which is
/// already the latency-sensitive part - and one writer is also what makes the file safe to append
/// to from the message thread and the request task at the same time without a lock around the file
/// itself. <see cref="Flush"/> exists so the last lines of a session still land before the process
/// exits.
/// </summary>
internal static class Log
{
    private const long MaxBytes = 256 * 1024;
    private const int MaxQueued = 4096;

    private static readonly ConcurrentQueue<string> Pending = new();
    private static readonly AutoResetEvent Signal = new(false);
    private static readonly ManualResetEventSlim Drained = new(true);
    private static readonly object WriterGate = new();

    private static string? _path;
    private static bool _verbose;
    private static Thread? _writer;
    private static volatile bool _stopping;

    internal static bool Verbose
    {
        get => _verbose;
        set => _verbose = value;
    }

    internal static string Directory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TextFix");

    internal static string FilePath => _path ??= Path.Combine(Directory, "textfix.log");

    internal static void Info(string message) => Write("INFO ", message);

    internal static void Warn(string message) => Write("WARN ", message);

    internal static void Error(string message) => Write("ERROR", message);

    internal static void Debug(string message)
    {
        if (_verbose) Write("DEBUG", message);
    }

    private static void Write(string level, string message)
    {
        if (_stopping) return;
        // Bounded: a pathological failure loop must cost a few hundred kilobytes of queue, not the
        // whole heap. Dropping the newest line is the right end to drop from - the first ones say
        // what started it.
        if (Pending.Count >= MaxQueued) return;

        string stamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff");
        Pending.Enqueue(stamp + " " + level + " " + message + Environment.NewLine);
        Drained.Reset();
        EnsureWriter();
        Signal.Set();
    }

    private static void EnsureWriter()
    {
        if (_writer != null) return;
        lock (WriterGate)
        {
            if (_writer != null) return;
            _writer = new Thread(WriterLoop)
            {
                IsBackground = true,
                Name = "TextFix.Log",
            };
            _writer.Start();
        }
    }

    private static void WriterLoop()
    {
        while (true)
        {
            Signal.WaitOne();
            DrainOnce();
            // Only signalled once the queue is genuinely empty, so a line enqueued while the
            // batch above was being written cannot make Flush believe it is done.
            if (Pending.IsEmpty) Drained.Set();
            if (_stopping && Pending.IsEmpty) return;
        }
    }

    private static void DrainOnce()
    {
        if (Pending.IsEmpty) return;
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            Rotate();

            var batch = new StringBuilder();
            while (Pending.TryDequeue(out string? line)) batch.Append(line);
            if (batch.Length > 0) File.AppendAllText(FilePath, batch.ToString());
        }
        catch
        {
            // Logging must never be the reason a fix fails. Anything still queued is dropped
            // rather than retried forever against a disk that is not answering.
            while (Pending.TryDequeue(out _)) { }
        }
    }

    private static void Rotate()
    {
        var info = new FileInfo(FilePath);
        if (!info.Exists || info.Length <= MaxBytes) return;
        // One generation of history is enough to diagnose "it stopped working today".
        string previous = FilePath + ".1";
        File.Delete(previous);
        File.Move(FilePath, previous);
    }

    /// <summary>
    /// Waits briefly for the queue to reach the disk. Called once, on the way out, so the lines
    /// that explain why a session ended are not the ones that get lost.
    /// </summary>
    internal static void Flush()
    {
        if (_writer == null)
        {
            // Nothing was ever logged, or the writer never started: write what is queued inline
            // rather than leaving it in memory.
            DrainOnce();
            return;
        }
        _stopping = true;
        Signal.Set();
        Drained.Wait(1000);
    }
}
