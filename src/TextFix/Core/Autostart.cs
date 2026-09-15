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

    internal static bool IsEnabled()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
            return key?.GetValue(ValueName) is string value && value.Length > 0;
        }
        catch (Exception e)
        {
            Log.Warn("Could not read the Run key: " + e.GetType().Name);
            return false;
        }
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
