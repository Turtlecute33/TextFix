// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.InteropServices;
using TextFix.Configuration;
using TextFix.Core;
using TextFix.Interop;

// Every DLL this app loads is a system one. Without this, a copy of TextFix.exe run from a
// Downloads folder would load a same-named DLL planted next to it before the real one.
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace TextFix;

internal static class Program
{
    private static int Main(string[] args)
    {
        // One agent per session. Launching it again - from the Start menu, or from the installer -
        // brings up the settings of the copy that is already running instead of fighting it for
        // the hotkeys.
        //
        // Any process running as this user could register the same window class and make every
        // launch exit here. That is not worth defending against: a named mutex has the identical
        // exposure, and code already running as the user can simply terminate the agent instead.
        nint existing = Win32.FindWindow(AgentWindow.ClassName, null);
        if (existing != 0)
        {
            // This process was just started by the user, so it may hand the foreground to the
            // running one. Without that, Windows refuses the settings window's SetForegroundWindow
            // and it opens behind whatever the user was looking at.
            Win32.GetWindowThreadProcessId(existing, out uint pid);
            if (pid != 0) Win32.AllowSetForegroundWindow(pid);
            Win32.PostMessage(existing, WM.SHOW_SETTINGS, 0, 0);
            return 0;
        }

        AppConfig config = AppConfig.Load();
        Log.Verbose = config.VerboseLog;
        if (Array.Exists(args, a => a.Equals("--settings", StringComparison.OrdinalIgnoreCase)))
        {
            config.WasCreatedFresh = true; // opens the window on startup
        }

        try
        {
            return new AgentWindow(config).Run();
        }
        catch (Exception e)
        {
            // Scrubbed like every other error that can reach a screen or a file. Nothing here is
            // expected to carry a key, but this is the one path that prints an exception in full,
            // and "expected" is not a good enough reason to make it the exception to the rule.
            Log.Error("Fatal: " + Ai.AiErrors.Scrub(e.ToString()));
            Log.Flush();
            Win32.MessageBox(
                0,
                "TextFix could not start:" + Environment.NewLine + Environment.NewLine
                    + Ai.AiErrors.Scrub(e.Message),
                "TextFix",
                Win32.MB_ICONERROR);
            return 1;
        }
    }
}
