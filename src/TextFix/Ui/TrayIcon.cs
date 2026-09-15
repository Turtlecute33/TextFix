// SPDX-License-Identifier: GPL-3.0-only
using TextFix.Core;
using TextFix.Interop;

namespace TextFix.Ui;

/// <summary>
/// The agent's entire permanent presence on screen: one tray icon, a tooltip that says what it is
/// doing, and a balloon for the rare failure the user has to know about. Deliberately created
/// through Shell_NotifyIcon rather than a UI framework, so the resident process carries no window
/// toolkit at all.
/// </summary>
internal sealed unsafe class TrayIcon : IDisposable
{
    private const uint IconId = 1;

    private readonly nint _hwnd;
    private nint _icon;
    private string _tooltip;
    private bool _added;

    internal TrayIcon(nint hwnd, string tooltip)
    {
        _hwnd = hwnd;
        _tooltip = tooltip;
        int size = Win32.GetSystemMetrics(Win32.SM_CXSMICON);
        _icon = NativeUi.LoadAppIcon(size <= 0 ? 16 : size);
        Add();
    }

    private void Add()
    {
        NOTIFYICONDATAW data = Build(Win32.NIF_MESSAGE | Win32.NIF_ICON | Win32.NIF_TIP);
        _added = Win32.Shell_NotifyIcon(Win32.NIM_ADD, &data);
        if (!_added) Log.Warn("Could not add the tray icon");
    }

    /// <summary>
    /// Re-adds the icon after Explorer restarts. Without this the agent keeps working but becomes
    /// invisible and unquittable until the next sign-in.
    /// </summary>
    internal void ReAdd()
    {
        _added = false;
        Add();
    }

    internal void SetTooltip(string text)
    {
        _tooltip = text;
        if (!_added) return;
        NOTIFYICONDATAW data = Build(Win32.NIF_TIP);
        Win32.Shell_NotifyIcon(Win32.NIM_MODIFY, &data);
    }

    internal void ShowBalloon(string title, string message, bool isError)
    {
        if (!_added) return;
        NOTIFYICONDATAW data = Build(Win32.NIF_INFO);
        Copy(data.szInfoTitle, 64, title);
        Copy(data.szInfo, 256, message);
        // No sound, and honour focus-assist: an agent that is meant to be invisible has no
        // business chiming during a presentation.
        data.dwInfoFlags = (isError ? Win32.NIIF_ERROR : Win32.NIIF_INFO)
            | Win32.NIIF_NOSOUND | Win32.NIIF_RESPECT_QUIET_TIME;
        Win32.Shell_NotifyIcon(Win32.NIM_MODIFY, &data);
    }

    private NOTIFYICONDATAW Build(uint flags)
    {
        var data = new NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(NOTIFYICONDATAW),
            hWnd = _hwnd,
            uID = IconId,
            uFlags = flags,
            uCallbackMessage = WM.TRAY_CALLBACK,
            hIcon = _icon,
        };
        Copy(data.szTip, 128, _tooltip);
        return data;
    }

    private static void Copy(char* destination, int capacity, string value)
    {
        int length = Math.Min(value.Length, capacity - 1);
        for (int i = 0; i < length; i++) destination[i] = value[i];
        destination[length] = '\0';
    }

    public void Dispose()
    {
        if (_added)
        {
            NOTIFYICONDATAW data = Build(0);
            Win32.Shell_NotifyIcon(Win32.NIM_DELETE, &data);
            _added = false;
        }
        if (_icon != 0)
        {
            Win32.DestroyIcon(_icon);
            _icon = 0;
        }
    }
}
