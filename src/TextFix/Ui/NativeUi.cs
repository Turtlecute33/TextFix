// SPDX-License-Identifier: GPL-3.0-only
using TextFix.Interop;

namespace TextFix.Ui;

/// <summary>Small shared helpers for the hand-built Win32 UI: module handle, DPI, and the UI font.</summary>
internal static unsafe class NativeUi
{
    internal static nint Instance { get; } = Win32.GetModuleHandle(0);

    /// <summary>The icon compiled into the exe. Resource 32512 is where the app icon lands.</summary>
    private const nint AppIconResource = 32512;

    internal static nint LoadAppIcon(int size)
    {
        nint icon = Win32.LoadImage(Instance, AppIconResource, Win32.IMAGE_ICON, size, size, Win32.LR_DEFAULTCOLOR);
        if (icon != 0) return icon;
        // Falling back to the generic application icon is better than a blank tray slot.
        return Win32.LoadIcon(0, 32512);
    }

    internal static int Scale(int value, uint dpi) => (int)Math.Round(value * dpi / 96.0);

    internal static uint DpiFor(nint hwnd)
    {
        uint dpi = hwnd == 0 ? 0 : Win32.GetDpiForWindow(hwnd);
        if (dpi == 0) dpi = Win32.GetDpiForSystem();
        return dpi == 0 ? 96 : dpi;
    }

    /// <summary>
    /// Segoe UI at the shell's usual 9 pt, scaled for the window's DPI. Created directly rather
    /// than read out of NONCLIENTMETRICS: it is the same answer on every supported Windows
    /// version, for one API call instead of a 500-byte struct.
    /// </summary>
    internal static nint CreateUiFont(uint dpi, bool bold = false)
    {
        var logFont = new LOGFONTW
        {
            lfHeight = -(int)Math.Round(9.0 * dpi / 72.0),
            lfWeight = bold ? 700 : 400,
            lfCharSet = 1,      // DEFAULT_CHARSET
            lfQuality = 5,      // CLEARTYPE_QUALITY
            lfPitchAndFamily = 0,
        };
        const string face = "Segoe UI";
        for (int i = 0; i < face.Length; i++) logFont.lfFaceName[i] = face[i];
        logFont.lfFaceName[face.Length] = '\0';
        return Win32.CreateFontIndirect(&logFont);
    }

    internal static void InitCommonControls()
    {
        var icc = new INITCOMMONCONTROLSEX
        {
            dwSize = (uint)sizeof(INITCOMMONCONTROLSEX),
            dwICC = Win32.ICC_STANDARD_CLASSES | Win32.ICC_HOTKEY_CLASS,
        };
        Win32.InitCommonControlsEx(icc);
    }

    /// <summary>Keeps a rectangle inside the virtual desktop, so an indicator never lands offscreen.</summary>
    internal static void ClampToScreen(ref int x, ref int y, int width, int height)
    {
        int left = Win32.GetSystemMetrics(Win32.SM_XVIRTUALSCREEN);
        int top = Win32.GetSystemMetrics(Win32.SM_YVIRTUALSCREEN);
        int right = left + Win32.GetSystemMetrics(Win32.SM_CXVIRTUALSCREEN);
        int bottom = top + Win32.GetSystemMetrics(Win32.SM_CYVIRTUALSCREEN);
        x = Math.Clamp(x, left, Math.Max(left, right - width));
        y = Math.Clamp(y, top, Math.Max(top, bottom - height));
    }
}
