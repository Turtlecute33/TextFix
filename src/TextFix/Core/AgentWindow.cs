// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.InteropServices;
using TextFix.Ai;
using TextFix.Configuration;
using TextFix.Interop;
using TextFix.Ui;

namespace TextFix.Core;

/// <summary>
/// The resident half of the app: a hidden top-level window that owns the tray icon, the global
/// hotkeys and the message loop. It is never shown, carries WS_EX_TOOLWINDOW so it cannot appear
/// in Alt+Tab, and exists only because RegisterHotKey and Shell_NotifyIcon both need somewhere to
/// deliver messages.
/// </summary>
internal sealed unsafe class AgentWindow
{
    internal const string ClassName = "TextFixAgentWnd";
    internal const string IdleTooltip = "TextFix";

    private const int HotkeyIdBase = 100;
    private const uint MenuActionBase = 1000;
    private const uint MenuSettings = 2001;
    private const uint MenuPause = 2002;
    private const uint MenuOpenLog = 2003;
    private const uint MenuOpenConfig = 2004;
    private const uint MenuQuit = 2005;

    private static AgentWindow? _instance;

    private AppConfig _config;
    private nint _hwnd;
    private TrayIcon? _tray;
    private FixService? _fix;
    private SettingsWindow? _settings;
    private uint _taskbarCreatedMessage;
    private bool _paused;
    private readonly List<int> _registeredHotkeys = [];

    internal AgentWindow(AppConfig config)
    {
        _config = config;
        _instance = this;
    }

    internal int Run()
    {
        NativeUi.InitCommonControls();
        if (!CreateHiddenWindow()) return 1;

        _tray = new TrayIcon(_hwnd, IdleTooltip);
        _fix = new FixService(_hwnd, _tray, () => _config);
        // Explorer can restart; without this the icon disappears for the rest of the session.
        _taskbarCreatedMessage = Win32.RegisterWindowMessage("TaskbarCreated");

        ApplyConfig();
        // The Run key stores an absolute path, so moving or reinstalling the exe silently breaks
        // run-at-login. config.json remembers what the user actually asked for, so put it back.
        Autostart.Reconcile(_config.StartWithWindows);
        Log.Info("Agent started");

        if (_config.WasCreatedFresh)
        {
            // First run: an agent with no API key can do nothing, so say so up front rather than
            // waiting for the user to press a hotkey and get an error.
            OpenSettings();
        }
        else if (_config.PrewarmOnStartup && SecretStore.HasApiKey(_config.ProviderValue))
        {
            // Warms the TLS session so the first fix of the session is as fast as the second.
            // Opt-out, because it is the one thing the agent does without being asked.
            AiClient.Prewarm(_config.ProviderValue);
        }

        int result = MessageLoop();

        CaretPulse.Shutdown();
        UnregisterHotkeys();
        _fix?.Dispose();
        _tray?.Dispose();
        Log.Info("Agent stopped");
        // The log is written on its own thread, so the last few lines need somewhere to land
        // before the process goes away.
        Log.Flush();
        return result;
    }

    private int MessageLoop()
    {
        while (true)
        {
            int available = Win32.GetMessage(out MSG message, 0, 0, 0);
            if (available == 0) return 0;      // WM_QUIT
            if (available == -1) return 1;     // error

            // Gives the settings window Tab navigation, Enter and Esc without a dialog template.
            if (_settings is { Handle: not 0 } settings && Win32.IsDialogMessage(settings.Handle, ref message))
            {
                continue;
            }
            Win32.TranslateMessage(message);
            Win32.DispatchMessage(message);
        }
    }

    private bool CreateHiddenWindow()
    {
        fixed (char* className = ClassName)
        {
            var windowClass = new WNDCLASSEXW
            {
                cbSize = (uint)sizeof(WNDCLASSEXW),
                lpfnWndProc = (nint)(delegate* unmanaged<nint, uint, nuint, nint, nint>)&StaticWndProc,
                hInstance = NativeUi.Instance,
                lpszClassName = className,
                hIcon = NativeUi.LoadAppIcon(32),
            };
            if (Win32.RegisterClassEx(&windowClass) == 0)
            {
                Log.Error("RegisterClassEx failed (" + Marshal.GetLastWin32Error() + ")");
                return false;
            }
        }

        // A real (if never shown) top-level window rather than a message-only one: TrackPopupMenu
        // needs a window that can be brought to the foreground, or the tray menu will not dismiss
        // when the user clicks away from it.
        _hwnd = Win32.CreateWindowEx(
            WS.EX_TOOLWINDOW, ClassName, "TextFix", WS.POPUP,
            0, 0, 0, 0, 0, 0, NativeUi.Instance, 0);
        if (_hwnd == 0)
        {
            Log.Error("CreateWindowEx failed (" + Marshal.GetLastWin32Error() + ")");
            return false;
        }
        return true;
    }

    [UnmanagedCallersOnly]
    private static nint StaticWndProc(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        AgentWindow? self = _instance;
        if (self != null)
        {
            nint? handled = self.HandleMessage(hwnd, message, wParam, lParam);
            if (handled.HasValue) return handled.Value;
        }
        return Win32.DefWindowProc(hwnd, message, wParam, lParam);
    }

    private nint? HandleMessage(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        if (message == _taskbarCreatedMessage && _taskbarCreatedMessage != 0)
        {
            _tray?.ReAdd();
            return 0;
        }

        switch (message)
        {
            case WM.HOTKEY:
                OnHotkey((int)wParam);
                return 0;

            case WM.TRAY_CALLBACK:
                switch ((uint)lParam)
                {
                    case WM.RBUTTONUP:
                        ShowTrayMenu();
                        return 0;
                    case WM.LBUTTONDBLCLK:
                        OpenSettings();
                        return 0;
                }
                return 0;

            case WM.FIX_COMPLETE:
                _fix?.Complete((long)wParam);
                return 0;

            case WM.TIMER:
                if (wParam == FixService.RestoreTimerId)
                {
                    _fix?.OnRestoreTimer();
                    return 0;
                }
                return null;

            case WM.SHOW_SETTINGS:
                OpenSettings();
                return 0;

            case WM.CLOSE:
                // Nothing can close the agent by accident; only the tray menu quits it.
                return 0;

            case WM.DESTROY:
                // A clipboard restore still on the timer has to happen here, before the queue is
                // torn down. GetMessage retrieves WM_QUIT well ahead of WM_TIMER, so a quit inside
                // the restore delay would drop the restore and leave the user holding our output
                // instead of whatever they had copied.
                _fix?.FlushPendingRestore();
                Win32.PostQuitMessage(0);
                return 0;
        }
        return null;
    }

    private void OnHotkey(int id)
    {
        int index = id - HotkeyIdBase;
        if (index < 0 || index >= _config.Actions.Count) return;
        _fix?.Start(index);
    }

    private void ShowTrayMenu()
    {
        nint menu = Win32.CreatePopupMenu();
        if (menu == 0) return;
        try
        {
            for (int i = 0; i < _config.Actions.Count; i++)
            {
                FixActionConfig action = _config.Actions[i];
                string label = action.Name;
                if (HotkeyBinding.TryParse(action.Hotkey, out HotkeyBinding binding) && !binding.IsEmpty)
                {
                    label += "   (" + binding.Format() + ")";
                }
                uint flags = Win32.MF_STRING | (action.Enabled ? 0 : Win32.MF_GRAYED);
                Win32.AppendMenu(menu, flags, MenuActionBase + (uint)i, label);
            }
            Win32.AppendMenu(menu, Win32.MF_SEPARATOR, 0, null);
            Win32.AppendMenu(menu, Win32.MF_STRING | (_paused ? Win32.MF_CHECKED : 0), MenuPause, "Pause hotkeys");
            Win32.AppendMenu(menu, Win32.MF_STRING, MenuSettings, "Settings...");
            Win32.AppendMenu(menu, Win32.MF_STRING, MenuOpenConfig, "Open config folder");
            Win32.AppendMenu(menu, Win32.MF_STRING, MenuOpenLog, "Open log");
            Win32.AppendMenu(menu, Win32.MF_SEPARATOR, 0, null);
            Win32.AppendMenu(menu, Win32.MF_STRING, MenuQuit, "Quit TextFix");

            Win32.GetCursorPos(out POINT cursor);
            // Required so the menu closes when the user clicks somewhere else.
            Win32.SetForegroundWindow(_hwnd);
            int command = Win32.TrackPopupMenu(
                menu,
                Win32.TPM_RIGHTBUTTON | Win32.TPM_RETURNCMD | Win32.TPM_NONOTIFY,
                cursor.X, cursor.Y, 0, _hwnd, 0);
            if (command != 0) OnMenuCommand((uint)command);
        }
        finally
        {
            Win32.DestroyMenu(menu);
        }
    }

    private void OnMenuCommand(uint command)
    {
        switch (command)
        {
            case MenuSettings:
                OpenSettings();
                return;
            case MenuPause:
                _paused = !_paused;
                if (_paused) UnregisterHotkeys();
                else RegisterHotkeys();
                _tray?.SetTooltip(_paused ? "TextFix - hotkeys paused" : IdleTooltip);
                return;
            case MenuOpenLog:
                OpenPath(File.Exists(Log.FilePath) ? Log.FilePath : Log.Directory);
                return;
            case MenuOpenConfig:
                OpenPath(AppConfig.Directory);
                return;
            case MenuQuit:
                Win32.DestroyWindow(_hwnd);
                return;
        }
        if (command >= MenuActionBase && command < MenuActionBase + 100)
        {
            // Running from the menu means the target window just lost focus to our menu, so the
            // capture would read the wrong window. Fixing that properly needs the previous
            // foreground window, which TrackPopupMenu has already taken; keep the entry as a
            // reminder of the hotkey instead of doing something surprising.
            int index = (int)(command - MenuActionBase);
            if (index < _config.Actions.Count)
            {
                FixActionConfig action = _config.Actions[index];
                HotkeyBinding.TryParse(action.Hotkey, out HotkeyBinding binding);
                string hint = binding.IsEmpty
                    ? "Assign a hotkey for " + action.Name + " in settings."
                    : "Press " + binding.Format() + " while your text box has focus.";
                _tray?.ShowBalloon(action.Name, hint, isError: false);
            }
        }
    }

    private static void OpenPath(string path)
    {
        try
        {
            Win32.ShellExecute(0, "open", path, null, null, Win32.SW_SHOWNORMAL);
        }
        catch (Exception e)
        {
            Log.Warn("Could not open " + Path.GetFileName(path) + ": " + e.GetType().Name);
        }
    }

    private void OpenSettings()
    {
        if (_settings is { Handle: not 0 })
        {
            _settings.Focus();
            return;
        }
        // A registered hotkey never reaches a window, so the hotkey capture control could not
        // record the combination the user is already using. Release them while the window is open.
        UnregisterHotkeys();
        _settings = new SettingsWindow(_config, OnSettingsClosed);
        if (!_settings.Show(_hwnd))
        {
            _settings = null;
            if (!_paused) RegisterHotkeys();
        }
    }

    private void OnSettingsClosed(AppConfig? saved)
    {
        _settings = null;
        if (saved != null)
        {
            _config = saved;
            _config.Normalize();
            _config.Save();
            Log.Info("Settings saved");
        }
        ApplyConfig();
    }

    private void ApplyConfig()
    {
        Log.Verbose = _config.VerboseLog;
        Editing.Keystrokes.KeyEventDelayMs = _config.KeyEventDelayMs;
        UnregisterHotkeys();
        if (!_paused) RegisterHotkeys();
        _tray?.SetTooltip(_paused ? "TextFix - hotkeys paused" : IdleTooltip);
    }

    private void RegisterHotkeys()
    {
        var taken = new List<string>();
        for (int i = 0; i < _config.Actions.Count; i++)
        {
            FixActionConfig action = _config.Actions[i];
            if (!action.Enabled) continue;
            if (!HotkeyBinding.TryParse(action.Hotkey, out HotkeyBinding binding) || binding.IsEmpty)
            {
                if (!string.IsNullOrWhiteSpace(action.Hotkey))
                {
                    Log.Warn("Could not understand the hotkey for " + action.Name + ": " + action.Hotkey);
                }
                continue;
            }
            int id = HotkeyIdBase + i;
            // MOD_NOREPEAT: holding the key must fire once, not once per repeat.
            if (Win32.RegisterHotKey(_hwnd, id, binding.Modifiers | Win32.MOD_NOREPEAT, binding.VirtualKey))
            {
                _registeredHotkeys.Add(id);
            }
            else
            {
                Log.Warn("Hotkey " + binding.Format() + " is already taken by another application");
                taken.Add(action.Name + " (" + binding.Format() + ")");
            }
        }
        if (taken.Count > 0)
        {
            _tray?.ShowBalloon(
                "Hotkey unavailable",
                "Another app already owns: " + string.Join(", ", taken),
                isError: true);
        }
    }

    private void UnregisterHotkeys()
    {
        foreach (int id in _registeredHotkeys) Win32.UnregisterHotKey(_hwnd, id);
        _registeredHotkeys.Clear();
    }
}
