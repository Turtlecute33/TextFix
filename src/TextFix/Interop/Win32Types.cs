// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.InteropServices;

namespace TextFix.Interop;

// Only the structures, messages and flags this app actually uses. Everything is laid out to
// match the Win32 headers exactly; cbSize fields are filled with sizeof() at the call site so a
// layout mistake surfaces as an immediate API failure rather than as silent corruption.

[StructLayout(LayoutKind.Sequential)]
internal struct POINT
{
    public int X;
    public int Y;
}

[StructLayout(LayoutKind.Sequential)]
internal struct SIZE
{
    public int cx;
    public int cy;
}

[StructLayout(LayoutKind.Sequential)]
internal struct RECT
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;

    public int Width => Right - Left;
    public int Height => Bottom - Top;
    public bool IsEmpty => Right <= Left || Bottom <= Top;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MSG
{
    public nint hwnd;
    public uint message;
    public nuint wParam;
    public nint lParam;
    public uint time;
    public POINT pt;
    public uint lPrivate;
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct WNDCLASSEXW
{
    public uint cbSize;
    public uint style;
    public nint lpfnWndProc;
    public int cbClsExtra;
    public int cbWndExtra;
    public nint hInstance;
    public nint hIcon;
    public nint hCursor;
    public nint hbrBackground;
    public char* lpszMenuName;
    public char* lpszClassName;
    public nint hIconSm;
}

[StructLayout(LayoutKind.Sequential)]
internal struct GUITHREADINFO
{
    public uint cbSize;
    public uint flags;
    public nint hwndActive;
    public nint hwndFocus;
    public nint hwndCapture;
    public nint hwndMenuOwner;
    public nint hwndMoveSize;
    public nint hwndCaret;
    public RECT rcCaret;
}

[StructLayout(LayoutKind.Sequential)]
internal struct KEYBDINPUT
{
    public ushort wVk;
    public ushort wScan;
    public uint dwFlags;
    public uint time;
    public nint dwExtraInfo;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MOUSEINPUT
{
    public int dx;
    public int dy;
    public uint mouseData;
    public uint dwFlags;
    public uint time;
    public nint dwExtraInfo;
}

[StructLayout(LayoutKind.Explicit)]
internal struct INPUTUNION
{
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
}

[StructLayout(LayoutKind.Sequential)]
internal struct INPUT
{
    public uint type;
    public INPUTUNION U;
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct NOTIFYICONDATAW
{
    public uint cbSize;
    public nint hWnd;
    public uint uID;
    public uint uFlags;
    public uint uCallbackMessage;
    public nint hIcon;
    public fixed char szTip[128];
    public uint dwState;
    public uint dwStateMask;
    public fixed char szInfo[256];
    public uint uVersion;
    public fixed char szInfoTitle[64];
    public uint dwInfoFlags;
    public Guid guidItem;
    public nint hBalloonIcon;
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct LOGFONTW
{
    public int lfHeight;
    public int lfWidth;
    public int lfEscapement;
    public int lfOrientation;
    public int lfWeight;
    public byte lfItalic;
    public byte lfUnderline;
    public byte lfStrikeOut;
    public byte lfCharSet;
    public byte lfOutPrecision;
    public byte lfClipPrecision;
    public byte lfQuality;
    public byte lfPitchAndFamily;
    public fixed char lfFaceName[32];
}

[StructLayout(LayoutKind.Sequential)]
internal struct BITMAPINFOHEADER
{
    public uint biSize;
    public int biWidth;
    public int biHeight;
    public ushort biPlanes;
    public ushort biBitCount;
    public uint biCompression;
    public uint biSizeImage;
    public int biXPelsPerMeter;
    public int biYPelsPerMeter;
    public uint biClrUsed;
    public uint biClrImportant;
}

[StructLayout(LayoutKind.Sequential)]
internal struct BLENDFUNCTION
{
    public byte BlendOp;
    public byte BlendFlags;
    public byte SourceConstantAlpha;
    public byte AlphaFormat;
}

[StructLayout(LayoutKind.Sequential)]
internal struct INITCOMMONCONTROLSEX
{
    public uint dwSize;
    public uint dwICC;
}

[StructLayout(LayoutKind.Sequential)]
internal struct DATA_BLOB
{
    public uint cbData;
    public nint pbData;
}

internal static class WM
{
    public const uint DESTROY = 0x0002;
    public const uint CLOSE = 0x0010;
    public const uint QUIT = 0x0012;
    public const uint ERASEBKGND = 0x0014;
    public const uint SETFONT = 0x0030;
    public const uint GETFONT = 0x0031;
    public const uint SETICON = 0x0080;
    public const uint KEYDOWN = 0x0100;
    public const uint COMMAND = 0x0111;
    public const uint TIMER = 0x0113;
    public const uint CTLCOLORSTATIC = 0x0138;
    public const uint CTLCOLOREDIT = 0x0133;
    public const uint CTLCOLORLISTBOX = 0x0134;
    public const uint CTLCOLORBTN = 0x0135;
    public const uint MOUSEMOVE = 0x0200;
    public const uint LBUTTONUP = 0x0202;
    public const uint LBUTTONDBLCLK = 0x0203;
    public const uint RBUTTONUP = 0x0205;
    public const uint HOTKEY = 0x0312;
    public const uint DPICHANGED = 0x02E0;
    public const uint APP = 0x8000;

    // Our own private messages.
    public const uint TRAY_CALLBACK = APP + 1;
    public const uint SHOW_SETTINGS = APP + 2;
    public const uint FIX_COMPLETE = APP + 3;
    public const uint PULSE_SHOW = APP + 4;
    public const uint PULSE_HIDE = APP + 5;
    public const uint PULSE_QUIT = APP + 6;
}

internal static class WS
{
    public const uint OVERLAPPED = 0x00000000;
    public const uint POPUP = 0x80000000;
    public const uint CHILD = 0x40000000;
    public const uint VISIBLE = 0x10000000;
    public const uint DISABLED = 0x08000000;
    public const uint CLIPSIBLINGS = 0x04000000;
    public const uint CLIPCHILDREN = 0x02000000;
    public const uint CAPTION = 0x00C00000;
    public const uint BORDER = 0x00800000;
    public const uint SYSMENU = 0x00080000;
    public const uint VSCROLL = 0x00200000;
    public const uint TABSTOP = 0x00010000;
    public const uint GROUP = 0x00020000;
    public const uint MINIMIZEBOX = 0x00020000;

    public const uint EX_TOOLWINDOW = 0x00000080;
    public const uint EX_TOPMOST = 0x00000008;
    public const uint EX_LAYERED = 0x00080000;
    public const uint EX_TRANSPARENT = 0x00000020;
    public const uint EX_NOACTIVATE = 0x08000000;
    public const uint EX_CLIENTEDGE = 0x00000200;
    public const uint EX_CONTROLPARENT = 0x00010000;
    public const uint EX_DLGMODALFRAME = 0x00000001;
    public const uint EX_APPWINDOW = 0x00040000;
}

internal static class VK
{
    public const ushort BACK = 0x08;
    public const ushort TAB = 0x09;
    public const ushort RETURN = 0x0D;
    public const ushort SHIFT = 0x10;
    public const ushort CONTROL = 0x11;
    public const ushort MENU = 0x12;
    public const ushort ESCAPE = 0x1B;
    public const ushort SPACE = 0x20;
    public const ushort LSHIFT = 0xA0;
    public const ushort RSHIFT = 0xA1;
    public const ushort LCONTROL = 0xA2;
    public const ushort RCONTROL = 0xA3;
    public const ushort LMENU = 0xA4;
    public const ushort RMENU = 0xA5;
    public const ushort LWIN = 0x5B;
    public const ushort RWIN = 0x5C;
    public const ushort KEY_A = 0x41;
    public const ushort KEY_C = 0x43;
    public const ushort KEY_V = 0x56;
}
