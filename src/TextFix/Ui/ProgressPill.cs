// SPDX-License-Identifier: GPL-3.0-only
using System.Diagnostics;
using System.Runtime.InteropServices;
using TextFix.Core;
using TextFix.Interop;

namespace TextFix.Ui;

/// <summary>
/// The indicator shown while a fix is in flight: a small glass capsule at the bottom centre of the
/// work area, with three white dots and a liquid drop that runs between them (see
/// <see cref="PillScene"/>). Every AI action has a network wait in the middle of it, and one
/// moving thing is the difference between "it is working" and "it is stuck".
///
/// It is always in the same place, so the eye finds it without a search, and it never covers the
/// text being fixed. The monitor is the one with the caret, or with the foreground window when the
/// app publishes no caret (Chromium and Electron).
///
/// It has two stages. The capsule comes up with still, dim dots the instant the hotkey is pressed,
/// and answers "did my key register?", which matters because the capture that follows can spend
/// the better part of a second in clipboard round trips. The drop starts to move once the request
/// is out, and answers "is it stuck?". A still capsule costs nothing to keep on screen: the frame
/// timer stops until something promotes or hides it.
///
/// Under reduced motion (Ease of Access &gt; "Animate controls and elements inside windows" off)
/// nothing moves or scales: the capsule fades in and out, and the dots fade one after the other in
/// place.
///
/// The window is layered, click-through, non-activating and marked as a tool window, so it cannot
/// take focus, appear in Alt+Tab, or intercept a click. It lives on its own thread with its own
/// message loop, so the animation stays smooth while the main thread is blocked in a clipboard
/// round trip.
/// </summary>
internal static unsafe class ProgressPill
{
    private const string ClassName = "TextFixPill";
    private const nuint TimerId = 1;

    // About 60 fps. The surface is small, so this is cheaper than it sounds.
    private const int FrameIntervalMs = 16;

    // 10 fps is plenty for a 1.5 s crossfade, and it is the difference between a reduced-motion
    // indicator that costs nothing and one that costs the same as the animated one.
    private const int ReducedFrameIntervalMs = 100;

    // Logical (96 dpi) size of the surface: the capsule and the margin around it.
    private const int SurfaceWidth = (int)(PillScene.Width + PillScene.Margin * 2);
    private const int SurfaceHeight = (int)(PillScene.Height + PillScene.Margin * 2);

    private static volatile nint _hwnd;
    private static nint _memoryDc;
    private static nint _bitmap;
    private static uint* _pixels;
    private static int _width;
    private static int _height;
    private static Thread? _thread;
    private static readonly ManualResetEventSlim Ready = new(false);
    private static readonly object Gate = new();
    private static bool _classRegistered;

    // Written by the agent thread under Gate, read by the indicator thread.
    private static int _requestedX;
    private static int _requestedY;
    private static uint _requestedDpi = 96;
    private static bool _requestedWorking;
    private static bool _requestedReduced;

    // Owned by the indicator thread.
    private static uint _dpi = 96;
    private static bool _visible;
    private static PillScene.Timeline _timeline;
    private static readonly PillScene.Frame Frame = new();

    /// <summary>
    /// Starts the indicator, or promotes one that is already up. Called from the agent thread; all
    /// the window work happens on the indicator thread.
    /// </summary>
    /// <param name="working">
    /// False for the quiet stage shown during the capture, true once the request is in flight.
    /// </param>
    internal static void Show(RECT caret, nint foreground, bool working)
    {
        try
        {
            EnsureThread();
            if (_hwnd == 0) return;

            nint monitor = 0;
            if (!caret.IsEmpty)
            {
                var centre = new POINT { X = (caret.Left + caret.Right) / 2, Y = (caret.Top + caret.Bottom) / 2 };
                monitor = Win32.MonitorFromPoint(centre, Win32.MONITOR_DEFAULTTONEAREST);
            }
            else if (foreground != 0)
            {
                monitor = Win32.MonitorFromWindow(foreground, Win32.MONITOR_DEFAULTTONEAREST);
            }
            else if (Win32.GetCursorPos(out POINT cursor))
            {
                monitor = Win32.MonitorFromPoint(cursor, Win32.MONITOR_DEFAULTTONEAREST);
            }
            var info = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
            if (monitor == 0 || !Win32.GetMonitorInfo(monitor, ref info)) return;

            // The foreground window is on that monitor in all but odd cases, so its DPI is the
            // monitor's DPI.
            uint dpi = NativeUi.DpiFor(foreground != 0 ? foreground : _hwnd);
            int width = NativeUi.Scale(SurfaceWidth, dpi);
            int height = NativeUi.Scale(SurfaceHeight, dpi);
            RECT work = info.rcWork;
            int x = (work.Left + work.Right - width) / 2;
            int y = work.Bottom - NativeUi.Scale((int)(PillScene.BottomGap - PillScene.Margin), dpi) - height;

            lock (Gate)
            {
                _requestedX = x;
                _requestedY = y;
                _requestedDpi = dpi;
                _requestedWorking = working;
                _requestedReduced = !NativeUi.AnimationsEnabled();
            }
            Win32.PostMessage(_hwnd, WM.PULSE_SHOW, 0, 0);
        }
        catch (Exception e)
        {
            Log.Warn("Indicator could not be shown: " + e.GetType().Name);
        }
    }

    internal static void Hide()
    {
        if (_hwnd == 0) return;
        Win32.PostMessage(_hwnd, WM.PULSE_HIDE, 0, 0);
    }

    internal static void Shutdown()
    {
        if (_hwnd == 0) return;
        Win32.PostMessage(_hwnd, WM.PULSE_QUIT, 0, 0);
        _thread?.Join(500);
    }

    private static void EnsureThread()
    {
        if (_thread != null)
        {
            Ready.Wait(1000);
            return;
        }
        lock (Gate)
        {
            if (_thread != null) return;
            _thread = new Thread(ThreadMain)
            {
                IsBackground = true,
                Name = "TextFix.Indicator",
            };
            _thread.Start();
        }
        // One-time and single-digit milliseconds: the window must exist before the first PostMessage.
        Ready.Wait(1000);
    }

    private static void ThreadMain()
    {
        try
        {
            if (!RegisterClass()) return;
            _hwnd = Win32.CreateWindowEx(
                WS.EX_LAYERED | WS.EX_TRANSPARENT | WS.EX_TOOLWINDOW | WS.EX_NOACTIVATE | WS.EX_TOPMOST,
                ClassName, null, WS.POPUP,
                0, 0, 10, 10, 0, 0, NativeUi.Instance, 0);
            if (_hwnd == 0)
            {
                Log.Warn("Could not create the indicator window (error " + Marshal.GetLastWin32Error() + ")");
                return;
            }
        }
        finally
        {
            Ready.Set();
        }

        while (Win32.GetMessage(out MSG message, 0, 0, 0) > 0)
        {
            Win32.TranslateMessage(message);
            Win32.DispatchMessage(message);
        }
        ReleaseSurface();
    }

    private static bool RegisterClass()
    {
        if (_classRegistered) return true;
        fixed (char* className = ClassName)
        {
            var windowClass = new WNDCLASSEXW
            {
                cbSize = (uint)sizeof(WNDCLASSEXW),
                lpfnWndProc = (nint)(delegate* unmanaged<nint, uint, nuint, nint, nint>)&WndProc,
                hInstance = NativeUi.Instance,
                lpszClassName = className,
            };
            if (Win32.RegisterClassEx(&windowClass) != 0)
            {
                _classRegistered = true;
                return true;
            }
        }
        // A class that is already registered is the one failure that means success. Anything else
        // must stay un-flagged so the next attempt retries rather than assuming a class exists.
        const int ErrorClassAlreadyExists = 1410;
        if (Marshal.GetLastWin32Error() == ErrorClassAlreadyExists)
        {
            _classRegistered = true;
            return true;
        }
        Log.Warn("Could not register the indicator window class (error " + Marshal.GetLastWin32Error() + ")");
        return false;
    }

    [UnmanagedCallersOnly]
    private static nint WndProc(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        try
        {
            return HandleMessage(hwnd, message, wParam, lParam);
        }
        catch (Exception e)
        {
            // An exception leaving an UnmanagedCallersOnly method ends the process on the spot.
            Log.Error("Indicator: " + e.GetType().Name);
            return Win32.DefWindowProc(hwnd, message, wParam, lParam);
        }
    }

    private static nint HandleMessage(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        switch (message)
        {
            case WM.PULSE_SHOW:
                OnShow(hwnd);
                return 0;

            case WM.PULSE_HIDE:
                // The dots melt back into one drop and the capsule shrinks; the timer stops when
                // the exit is complete.
                if (_visible && _timeline.HidingAt is null)
                {
                    _timeline.HidingAt = Now();
                    StartTimer(hwnd);
                }
                return 0;

            case WM.PULSE_QUIT:
                Win32.KillTimer(hwnd, TimerId);
                Win32.DestroyWindow(hwnd);
                return 0;

            case WM.TIMER:
                Paint(hwnd);
                return 0;

            case WM.DESTROY:
                Win32.PostQuitMessage(0);
                return 0;
        }
        return Win32.DefWindowProc(hwnd, message, wParam, lParam);
    }

    private static void OnShow(nint hwnd)
    {
        int x;
        int y;
        uint dpi;
        bool working;
        bool reduced;
        lock (Gate)
        {
            x = _requestedX;
            y = _requestedY;
            dpi = _requestedDpi;
            working = _requestedWorking;
            reduced = _requestedReduced;
        }

        double now = Now();
        if (!_visible || _timeline.HidingAt is not null)
        {
            // A show while hidden - or during the exit - starts the entrance. A show while the
            // pill is up only promotes it: it does not move, and it does not come in again.
            int width = NativeUi.Scale(SurfaceWidth, dpi);
            int height = NativeUi.Scale(SurfaceHeight, dpi);
            EnsureSurface(width, height);
            if (_pixels == null) return;
            _dpi = dpi;
            _timeline = new PillScene.Timeline { ShownAt = now, Reduced = reduced };
            _visible = true;
            Win32.SetWindowPos(hwnd, Win32.HWND_TOPMOST, x, y, width, height, Win32.SWP_NOACTIVATE);
            // The first frame goes into the window before it is shown, so an old frame never flashes.
            Paint(hwnd);
            Win32.ShowWindow(hwnd, 4 /* SW_SHOWNOACTIVATE */);
        }
        if (working && _timeline.WorkingAt is null) _timeline.WorkingAt = now;
        Paint(hwnd);
        StartTimer(hwnd);
    }

    private static void StartTimer(nint hwnd) =>
        // Cast because the ternary is not a constant expression, so it will not widen to uint on
        // its own.
        Win32.SetTimer(hwnd, TimerId, (uint)(_timeline.Reduced ? ReducedFrameIntervalMs : FrameIntervalMs), 0);

    /// <summary>Seconds on the high-resolution clock. TickCount64 moves in 15.6 ms steps, which shows as judder.</summary>
    private static double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    private static void EnsureSurface(int width, int height)
    {
        if (_memoryDc != 0 && width == _width && height == _height) return;
        ReleaseSurface();

        _width = width;
        _height = height;
        nint screenDc = Win32.GetDC(0);
        _memoryDc = Win32.CreateCompatibleDC(screenDc);
        Win32.ReleaseDC(0, screenDc);
        if (_memoryDc == 0) return;

        var header = new BITMAPINFOHEADER
        {
            biSize = (uint)sizeof(BITMAPINFOHEADER),
            biWidth = width,
            // Negative height gives a top-down bitmap, so row 0 is the top row.
            biHeight = -height,
            biPlanes = 1,
            biBitCount = 32,
            biCompression = Win32.BI_RGB,
        };
        _bitmap = Win32.CreateDIBSection(_memoryDc, &header, Win32.DIB_RGB_COLORS, out nint bits, 0, 0);
        if (_bitmap == 0 || bits == 0)
        {
            ReleaseSurface();
            return;
        }
        _pixels = (uint*)bits;
        Win32.SelectObject(_memoryDc, _bitmap);
    }

    private static void ReleaseSurface()
    {
        if (_bitmap != 0)
        {
            Win32.DeleteObject(_bitmap);
            _bitmap = 0;
        }
        if (_memoryDc != 0)
        {
            Win32.DeleteDC(_memoryDc);
            _memoryDc = 0;
        }
        _pixels = null;
        _width = 0;
        _height = 0;
    }

    private static void Paint(nint hwnd)
    {
        if (_pixels == null || _memoryDc == 0 || !_visible)
        {
            Win32.KillTimer(hwnd, TimerId);
            return;
        }

        double now = Now();
        PillScene.FrameAt(now, _timeline, Frame);
        if (Frame.Finished)
        {
            _visible = false;
            Win32.KillTimer(hwnd, TimerId);
            Win32.ShowWindow(hwnd, Win32.SW_HIDE);
            return;
        }
        PillScene.Stage(now, _timeline, out double scale, out double opacity);
        PillScene.Render(Frame, scale, opacity, _pixels, _width, _height, _dpi / 96.0);

        var size = new SIZE { cx = _width, cy = _height };
        var source = new POINT { X = 0, Y = 0 };
        var blend = new BLENDFUNCTION
        {
            BlendOp = Win32.AC_SRC_OVER,
            BlendFlags = 0,
            SourceConstantAlpha = 255,
            AlphaFormat = Win32.AC_SRC_ALPHA,
        };
        Win32.GetWindowRect(hwnd, out RECT bounds);
        var destination = new POINT { X = bounds.Left, Y = bounds.Top };
        Win32.UpdateLayeredWindow(hwnd, 0, &destination, &size, _memoryDc, &source, 0, &blend, Win32.ULW_ALPHA);

        // A still capsule has nothing left to draw. Promoting or hiding it starts the timer again.
        if (Frame.Settled) Win32.KillTimer(hwnd, TimerId);
    }
}
