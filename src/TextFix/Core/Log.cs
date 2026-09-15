// SPDX-License-Identifier: GPL-3.0-only
namespace TextFix.Core;

/// <summary>
/// A deliberately small rolling log. It records what the agent tried and how the provider
/// answered - never the text being fixed, never a clipboard payload, never an API key. Those are
/// the whole point of the app being local, and a log file is the easiest place to leak them.
/// </summary>
internal static class Log
{
    private const long MaxBytes = 256 * 1024;
    private static readonly object Gate = new();
    private static string? _path;
    private static bool _verbose;

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
        try
        {
            lock (Gate)
            {
                System.IO.Directory.CreateDirectory(Directory);
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > MaxBytes)
                {
                    // One generation of history is enough to diagnose "it stopped working today".
                    string previous = FilePath + ".1";
                    File.Delete(previous);
                    File.Move(FilePath, previous);
                }
                string stamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff");
                File.AppendAllText(FilePath, stamp + " " + level + " " + message + Environment.NewLine);
            }
        }
        catch
        {
            // Logging must never be the reason a fix fails.
        }
    }
}
