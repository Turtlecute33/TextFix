// SPDX-License-Identifier: GPL-3.0-only
using Microsoft.Win32;

namespace TextFix.Core;

/// <summary>
/// Run-at-login through the per-user Run key. No service, no scheduled task, no elevation: the
/// agent is a user-session tool and has no business running before or outside the session.
/// </summary>
internal static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "TextFix";

    internal static bool IsEnabled() => CurrentValue() is { Length: > 0 };

    private static string? CurrentValue()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
            return key?.GetValue(ValueName) as string;
        }
        catch (Exception e)
        {
            Log.Warn("Could not read the Run key: " + e.GetType().Name);
            return null;
        }
    }

    /// <summary>
    /// Puts the Run entry back when config.json says the user wants run-at-login but the registry
    /// disagrees. The Run key stores an absolute path, so moving the exe, reinstalling it, or
    /// restoring a profile onto a new machine leaves a stale entry - or none at all - and the
    /// feature silently stops working with nothing to see in the settings window.
    /// </summary>
    internal static void Reconcile(bool wanted)
    {
        if (!wanted) return;
        string? exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe)) return;
        string expected = "\"" + exe + "\"";
        if (string.Equals(CurrentValue(), expected, StringComparison.OrdinalIgnoreCase)) return;
        SetEnabled(true);
        Log.Info("Restored the run-at-login entry; it did not match this executable");
    }

    internal static void SetEnabled(bool enabled)
    {
        try
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (!enabled)
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
                return;
            }
            string? exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe))
            {
                Log.Warn("Could not determine the executable path; run at login not enabled");
                return;
            }
            // Quoted so a path containing spaces still launches, which the default
            // %LOCALAPPDATA%\Programs location guarantees it will.
            key.SetValue(ValueName, "\"" + exe + "\"", RegistryValueKind.String);
        }
        catch (Exception e)
        {
            Log.Warn("Could not update the Run key: " + e.GetType().Name);
        }
    }
}
