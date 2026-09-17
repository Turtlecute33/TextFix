// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.InteropServices;

namespace TextFix.Interop;

/// <summary>
/// Source-generated P/Invoke for every Win32 entry point the agent uses. LibraryImport rather
/// than DllImport so the marshalling stubs are compiled ahead of time - nothing here needs the
/// reflection-based marshaller that Native AOT does not ship.
/// </summary>
internal static unsafe partial class Win32
{
    private const string User32 = "user32.dll";
    private const string Kernel32 = "kernel32.dll";
    private const string Gdi32 = "gdi32.dll";
    private const string Shell32 = "shell32.dll";
    private const string ComCtl32 = "comctl32.dll";
    private const string Crypt32 = "crypt32.dll";

    // ---- module / process ----

    [LibraryImport(Kernel32, EntryPoint = "GetModuleHandleW", SetLastError = true)]
    internal static partial nint GetModuleHandle(nint lpModuleName);

    // ---- windows ----

    [LibraryImport(User32, EntryPoint = "RegisterClassExW", SetLastError = true)]
    internal static partial ushort RegisterClassEx(WNDCLASSEXW* lpwcx);

    [LibraryImport(User32, EntryPoint = "CreateWindowExW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint CreateWindowEx(
        uint dwExStyle, string lpClassName, string? lpWindowName, uint dwStyle,
        int x, int y, int nWidth, int nHeight, nint hWndParent, nint hMenu, nint hInstance, nint lpParam);

    [LibraryImport(User32, EntryPoint = "DefWindowProcW")]
    internal static partial nint DefWindowProc(nint hWnd, uint msg, nuint wParam, nint lParam);

    [LibraryImport(User32, EntryPoint = "DestroyWindow", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyWindow(nint hWnd);

    [LibraryImport(User32, EntryPoint = "FindWindowW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint FindWindow(string? lpClassName, string? lpWindowName);

    [LibraryImport(User32, EntryPoint = "ShowWindow")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool ShowWindow(nint hWnd, int nCmdShow);

    [LibraryImport(User32, EntryPoint = "SetWindowPos", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetWindowPos(nint hWnd, nint hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [LibraryImport(User32, EntryPoint = "GetWindowRect", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetWindowRect(nint hWnd, out RECT lpRect);

    [LibraryImport(User32, EntryPoint = "SetWindowTextW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetWindowText(nint hWnd, string lpString);

    [LibraryImport(User32, EntryPoint = "GetWindowTextW", SetLastError = true)]
    internal static partial int GetWindowText(nint hWnd, char* lpString, int nMaxCount);

    [LibraryImport(User32, EntryPoint = "GetWindowTextLengthW", SetLastError = true)]
    internal static partial int GetWindowTextLength(nint hWnd);

    [LibraryImport(User32, EntryPoint = "SendMessageW")]
    internal static partial nint SendMessage(nint hWnd, uint msg, nuint wParam, nint lParam);

    [LibraryImport(User32, EntryPoint = "SendMessageW", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint SendMessageString(nint hWnd, uint msg, nuint wParam, string lParam);

    [LibraryImport(User32, EntryPoint = "PostMessageW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool PostMessage(nint hWnd, uint msg, nuint wParam, nint lParam);

    [LibraryImport(User32, EntryPoint = "RegisterWindowMessageW", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial uint RegisterWindowMessage(string lpString);

    [LibraryImport(User32, EntryPoint = "SetTimer")]
    internal static partial nuint SetTimer(nint hWnd, nuint nIDEvent, uint uElapse, nint lpTimerFunc);

    [LibraryImport(User32, EntryPoint = "KillTimer")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool KillTimer(nint hWnd, nuint uIDEvent);

    [LibraryImport(User32, EntryPoint = "GetMessageW")]
    internal static partial int GetMessage(out MSG lpMsg, nint hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [LibraryImport(User32, EntryPoint = "TranslateMessage")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool TranslateMessage(in MSG lpMsg);

    [LibraryImport(User32, EntryPoint = "DispatchMessageW")]
    internal static partial nint DispatchMessage(in MSG lpMsg);

    [LibraryImport(User32, EntryPoint = "IsDialogMessageW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool IsDialogMessage(nint hDlg, ref MSG lpMsg);

    [LibraryImport(User32, EntryPoint = "PostQuitMessage")]
    internal static partial void PostQuitMessage(int nExitCode);

    [LibraryImport(User32, EntryPoint = "GetForegroundWindow")]
    internal static partial nint GetForegroundWindow();

    [LibraryImport(User32, EntryPoint = "SetForegroundWindow")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetForegroundWindow(nint hWnd);

    [LibraryImport(User32, EntryPoint = "GetWindowThreadProcessId")]
    internal static partial uint GetWindowThreadProcessId(nint hWnd, out uint lpdwProcessId);

    [LibraryImport(User32, EntryPoint = "GetGUIThreadInfo", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO pgui);

    [LibraryImport(User32, EntryPoint = "GetClassNameW", SetLastError = true)]
    internal static partial int GetClassName(nint hWnd, char* lpClassName, int nMaxCount);

    [LibraryImport(User32, EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    internal static partial nint GetWindowLongPtr(nint hWnd, int nIndex);

    [LibraryImport(User32, EntryPoint = "EnableWindow")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool EnableWindow(nint hWnd, [MarshalAs(UnmanagedType.Bool)] bool bEnable);

    [LibraryImport(User32, EntryPoint = "ClientToScreen")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool ClientToScreen(nint hWnd, ref POINT lpPoint);

    [LibraryImport(User32, EntryPoint = "GetCursorPos")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetCursorPos(out POINT lpPoint);

    [LibraryImport(User32, EntryPoint = "GetSystemMetrics")]
    internal static partial int GetSystemMetrics(int nIndex);

    [LibraryImport(User32, EntryPoint = "GetDpiForWindow")]
    internal static partial uint GetDpiForWindow(nint hWnd);

    [LibraryImport(User32, EntryPoint = "GetDpiForSystem")]
    internal static partial uint GetDpiForSystem();

    [LibraryImport(User32, EntryPoint = "AdjustWindowRectExForDpi", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool AdjustWindowRectExForDpi(
        ref RECT lpRect, uint dwStyle, [MarshalAs(UnmanagedType.Bool)] bool bMenu, uint dwExStyle, uint dpi);

    [LibraryImport(User32, EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SystemParametersInfo(uint uiAction, uint uiParam, void* pvParam, uint fWinIni);

    [LibraryImport(User32, EntryPoint = "GetSysColor")]
    internal static partial uint GetSysColor(int nIndex);

    [LibraryImport(User32, EntryPoint = "GetSysColorBrush")]
    internal static partial nint GetSysColorBrush(int nIndex);

    [LibraryImport(User32, EntryPoint = "MessageBoxW", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial int MessageBox(nint hWnd, string lpText, string lpCaption, uint uType);

    [LibraryImport(User32, EntryPoint = "LoadIconW", SetLastError = true)]
    internal static partial nint LoadIcon(nint hInstance, nint lpIconName);

    [LibraryImport(User32, EntryPoint = "LoadImageW", SetLastError = true)]
    internal static partial nint LoadImage(nint hInst, nint name, uint type, int cx, int cy, uint fuLoad);

    [LibraryImport(User32, EntryPoint = "LoadCursorW", SetLastError = true)]
    internal static partial nint LoadCursor(nint hInstance, nint lpCursorName);

    [LibraryImport(User32, EntryPoint = "DestroyIcon", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyIcon(nint hIcon);

    // ---- menus ----

    [LibraryImport(User32, EntryPoint = "CreatePopupMenu", SetLastError = true)]
    internal static partial nint CreatePopupMenu();

    [LibraryImport(User32, EntryPoint = "AppendMenuW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool AppendMenu(nint hMenu, uint uFlags, nuint uIDNewItem, string? lpNewItem);

    [LibraryImport(User32, EntryPoint = "TrackPopupMenu", SetLastError = true)]
    internal static partial int TrackPopupMenu(nint hMenu, uint uFlags, int x, int y, int nReserved, nint hWnd, nint prcRect);

    [LibraryImport(User32, EntryPoint = "DestroyMenu", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyMenu(nint hMenu);

    // ---- hotkeys / input ----

    [LibraryImport(User32, EntryPoint = "RegisterHotKey", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool RegisterHotKey(nint hWnd, int id, uint fsModifiers, uint vk);

    [LibraryImport(User32, EntryPoint = "UnregisterHotKey", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterHotKey(nint hWnd, int id);

    [LibraryImport(User32, EntryPoint = "SendInput", SetLastError = true)]
    internal static partial uint SendInput(uint cInputs, INPUT* pInputs, int cbSize);

    [LibraryImport(User32, EntryPoint = "MapVirtualKeyW")]
    internal static partial uint MapVirtualKey(uint uCode, uint uMapType);

    [LibraryImport(User32, EntryPoint = "GetAsyncKeyState")]
    internal static partial short GetAsyncKeyState(int vKey);

    // ---- clipboard ----

    [LibraryImport(User32, EntryPoint = "OpenClipboard", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool OpenClipboard(nint hWndNewOwner);

    [LibraryImport(User32, EntryPoint = "CloseClipboard", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool CloseClipboard();

    [LibraryImport(User32, EntryPoint = "EmptyClipboard", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool EmptyClipboard();

    [LibraryImport(User32, EntryPoint = "GetClipboardData", SetLastError = true)]
    internal static partial nint GetClipboardData(uint uFormat);

    [LibraryImport(User32, EntryPoint = "SetClipboardData", SetLastError = true)]
    internal static partial nint SetClipboardData(uint uFormat, nint hMem);

    [LibraryImport(User32, EntryPoint = "IsClipboardFormatAvailable")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool IsClipboardFormatAvailable(uint format);

    [LibraryImport(User32, EntryPoint = "EnumClipboardFormats", SetLastError = true)]
    internal static partial uint EnumClipboardFormats(uint format);

    [LibraryImport(User32, EntryPoint = "RegisterClipboardFormatW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    internal static partial uint RegisterClipboardFormat(string lpszFormat);

    [LibraryImport(User32, EntryPoint = "GetClipboardSequenceNumber")]
    internal static partial uint GetClipboardSequenceNumber();

    // ---- global memory ----

    [LibraryImport(Kernel32, EntryPoint = "GlobalAlloc", SetLastError = true)]
    internal static partial nint GlobalAlloc(uint uFlags, nuint dwBytes);

    [LibraryImport(Kernel32, EntryPoint = "GlobalLock", SetLastError = true)]
    internal static partial nint GlobalLock(nint hMem);

    [LibraryImport(Kernel32, EntryPoint = "GlobalUnlock", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GlobalUnlock(nint hMem);

    [LibraryImport(Kernel32, EntryPoint = "GlobalSize", SetLastError = true)]
    internal static partial nuint GlobalSize(nint hMem);

    [LibraryImport(Kernel32, EntryPoint = "GlobalFree", SetLastError = true)]
    internal static partial nint GlobalFree(nint hMem);

    [LibraryImport(Kernel32, EntryPoint = "LocalFree")]
    internal static partial nint LocalFree(nint hMem);

    // ---- gdi ----

    [LibraryImport(User32, EntryPoint = "GetDC")]
    internal static partial nint GetDC(nint hWnd);

    [LibraryImport(User32, EntryPoint = "ReleaseDC")]
    internal static partial int ReleaseDC(nint hWnd, nint hDC);

    [LibraryImport(User32, EntryPoint = "UpdateLayeredWindow", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UpdateLayeredWindow(
        nint hWnd, nint hdcDst, POINT* pptDst, SIZE* psize, nint hdcSrc, POINT* pptSrc,
        uint crKey, BLENDFUNCTION* pblend, uint dwFlags);

    [LibraryImport(Gdi32, EntryPoint = "CreateCompatibleDC", SetLastError = true)]
    internal static partial nint CreateCompatibleDC(nint hdc);

    [LibraryImport(Gdi32, EntryPoint = "DeleteDC", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DeleteDC(nint hdc);

    [LibraryImport(Gdi32, EntryPoint = "CreateDIBSection", SetLastError = true)]
    internal static partial nint CreateDIBSection(nint hdc, BITMAPINFOHEADER* pbmi, uint usage, out nint ppvBits, nint hSection, uint offset);

    [LibraryImport(Gdi32, EntryPoint = "SelectObject", SetLastError = true)]
    internal static partial nint SelectObject(nint hdc, nint h);

    [LibraryImport(Gdi32, EntryPoint = "DeleteObject", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DeleteObject(nint ho);

    [LibraryImport(Gdi32, EntryPoint = "CreateFontIndirectW", SetLastError = true)]
    internal static partial nint CreateFontIndirect(LOGFONTW* lplf);

    [LibraryImport(Gdi32, EntryPoint = "SetBkColor")]
    internal static partial uint SetBkColor(nint hdc, uint color);

    // ---- shell ----

    [LibraryImport(Shell32, EntryPoint = "Shell_NotifyIconW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool Shell_NotifyIcon(uint dwMessage, NOTIFYICONDATAW* lpData);

    [LibraryImport(Shell32, EntryPoint = "ShellExecuteW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint ShellExecute(nint hwnd, string? lpOperation, string lpFile, string? lpParameters, string? lpDirectory, int nShowCmd);

    // ---- common controls ----

    [LibraryImport(ComCtl32, EntryPoint = "InitCommonControlsEx")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool InitCommonControlsEx(in INITCOMMONCONTROLSEX picce);

    // ---- DPAPI ----

    [LibraryImport(Crypt32, EntryPoint = "CryptProtectData", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool CryptProtectData(
        in DATA_BLOB pDataIn, string? szDataDescr, in DATA_BLOB pOptionalEntropy,
        nint pvReserved, nint pPromptStruct, uint dwFlags, out DATA_BLOB pDataOut);

    [LibraryImport(Crypt32, EntryPoint = "CryptUnprotectData", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool CryptUnprotectData(
        in DATA_BLOB pDataIn, nint ppszDataDescr, in DATA_BLOB pOptionalEntropy,
        nint pvReserved, nint pPromptStruct, uint dwFlags, out DATA_BLOB pDataOut);

    // ---- constants used with the above ----

    internal const int GWL_STYLE = -16;
    internal const int SW_HIDE = 0;
    internal const int SW_SHOWNORMAL = 1;
    internal const int SW_SHOW = 5;
    internal const int SW_RESTORE = 9;

    internal const int SM_CXSMICON = 49;
    internal const int SM_CYSMICON = 50;
    internal const int SM_XVIRTUALSCREEN = 76;
    internal const int SM_YVIRTUALSCREEN = 77;
    internal const int SM_CXVIRTUALSCREEN = 78;
    internal const int SM_CYVIRTUALSCREEN = 79;

    /// <summary>
    /// "Animate controls and elements inside windows" in Ease of Access. This is what Windows
    /// offers in place of the reduced-motion setting every other platform has, and it is off for
    /// exactly the people who should not be shown a light travelling across their screen.
    /// </summary>
    internal const uint SPI_GETCLIENTAREAANIMATION = 0x1042;

    internal const int COLOR_BTNFACE = 15;
    internal const int COLOR_WINDOW = 5;
    internal const int COLOR_WINDOWTEXT = 8;
    internal const int COLOR_GRAYTEXT = 17;

    internal const uint IMAGE_ICON = 1;
    internal const uint LR_DEFAULTCOLOR = 0;
    internal const uint LR_SHARED = 0x8000;

    internal const uint SWP_NOSIZE = 0x0001;
    internal const uint SWP_NOMOVE = 0x0002;
    internal const uint SWP_NOZORDER = 0x0004;
    internal const uint SWP_NOACTIVATE = 0x0010;
    internal const uint SWP_SHOWWINDOW = 0x0040;
    internal const uint SWP_HIDEWINDOW = 0x0080;
    internal const nint HWND_TOPMOST = -1;
    internal const nint HWND_MESSAGE = -3;

    internal const uint MF_STRING = 0x0000;
    internal const uint MF_SEPARATOR = 0x0800;
    internal const uint MF_CHECKED = 0x0008;
    internal const uint MF_UNCHECKED = 0x0000;
    internal const uint MF_GRAYED = 0x0001;
    internal const uint TPM_RIGHTBUTTON = 0x0002;
    internal const uint TPM_RIGHTALIGN = 0x0008;
    internal const uint TPM_BOTTOMALIGN = 0x0020;
    internal const uint TPM_RETURNCMD = 0x0100;
    internal const uint TPM_NONOTIFY = 0x0080;

    internal const uint MOD_ALT = 0x0001;
    internal const uint MOD_CONTROL = 0x0002;
    internal const uint MOD_SHIFT = 0x0004;
    internal const uint MOD_WIN = 0x0008;
    internal const uint MOD_NOREPEAT = 0x4000;

    internal const uint INPUT_KEYBOARD = 1;
    internal const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    internal const uint KEYEVENTF_KEYUP = 0x0002;

    internal const uint CF_TEXT = 1;
    internal const uint CF_BITMAP = 2;
    internal const uint CF_METAFILEPICT = 3;
    internal const uint CF_DIB = 8;
    internal const uint CF_PALETTE = 9;
    internal const uint CF_UNICODETEXT = 13;
    internal const uint CF_ENHMETAFILE = 14;
    internal const uint CF_HDROP = 15;
    internal const uint CF_DIBV5 = 17;

    internal const uint GMEM_MOVEABLE = 0x0002;

    internal const uint DIB_RGB_COLORS = 0;
    internal const uint BI_RGB = 0;
    internal const byte AC_SRC_OVER = 0x00;
    internal const byte AC_SRC_ALPHA = 0x01;
    internal const uint ULW_ALPHA = 0x00000002;

    internal const uint NIM_ADD = 0x00000000;
    internal const uint NIM_MODIFY = 0x00000001;
    internal const uint NIM_DELETE = 0x00000002;
    internal const uint NIM_SETVERSION = 0x00000004;
    internal const uint NIF_MESSAGE = 0x00000001;
    internal const uint NIF_ICON = 0x00000002;
    internal const uint NIF_TIP = 0x00000004;
    internal const uint NIF_INFO = 0x00000010;
    internal const uint NIF_SHOWTIP = 0x00000080;
    internal const uint NIIF_NONE = 0x00000000;
    internal const uint NIIF_INFO = 0x00000001;
    internal const uint NIIF_WARNING = 0x00000002;
    internal const uint NIIF_ERROR = 0x00000003;
    internal const uint NIIF_NOSOUND = 0x00000010;
    internal const uint NIIF_RESPECT_QUIET_TIME = 0x00000080;
    internal const uint NOTIFYICON_VERSION_4 = 4;

    internal const uint ICC_HOTKEY_CLASS = 0x00000040;
    internal const uint ICC_STANDARD_CLASSES = 0x00004000;

    internal const uint CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    internal const int MB_OK = 0x0;
    internal const uint MB_ICONERROR = 0x10;
    internal const uint MB_ICONWARNING = 0x30;
    internal const uint MB_ICONINFORMATION = 0x40;
    internal const uint MB_TOPMOST = 0x00040000;

    /// <summary>Reads a window's text into a managed string.</summary>
    internal static string GetWindowTextValue(nint hWnd)
    {
        int len = GetWindowTextLength(hWnd);
        if (len <= 0) return string.Empty;
        Span<char> buffer = len < 1024 ? stackalloc char[len + 1] : new char[len + 1];
        fixed (char* p = buffer)
        {
            int written = GetWindowText(hWnd, p, len + 1);
            return written <= 0 ? string.Empty : new string(p, 0, written);
        }
    }

    internal static string GetClassNameValue(nint hWnd)
    {
        char* buffer = stackalloc char[256];
        int written = GetClassName(hWnd, buffer, 256);
        return written <= 0 ? string.Empty : new string(buffer, 0, written);
    }
}
