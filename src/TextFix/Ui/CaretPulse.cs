// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using TextFix.Core;
using TextFix.Interop;

namespace TextFix.Ui;

/// <summary>
/// The indicator shown next to the caret while a fix is in flight: a small dark capsule with a
/// light sweeping through it. Every AI action has a network wait in the middle of it, and one
/// moving thing is the difference between "it is working" and "it is stuck".
///
/// It is drawn rather than composed of controls because it has to be legible on an unknown
/// background - a white document, a black editor, a photo - so it brings its own contrast: a dark
/// capsule with a soft drop shadow and a hairline rim, and a bright indeterminate sweep inside it.
/// It fades and scales in and out instead of blinking into existence.
///
/// The window is layered, click-through, non-activating and marked as a tool window, so it cannot
/// take focus, appear in Alt+Tab, or intercept a click. It lives on its own thread with its own
/// message loop, so the animation stays smooth while the main thread is blocked in a clipboard
/// round trip, and the whole thing costs one timer over a surface of a few thousand pixels while
/// visible and nothing at all when hidden.
/// </summary>
internal static unsafe class CaretPulse
{
    private const string ClassName = "TextFixPulse";
    private const nuint TimerId = 1;

    // 60 fps. The surface is tiny, so this is cheaper than it sounds and is what makes the sweep
    // read as smooth rather than as a stutter.
    private const int FrameIntervalMs = 16;

    private const int SweepPeriodMs = 1150;
    private const int FadeInMs = 150;
    private const int FadeOutMs = 130;

    // Logical (96 dpi) geometry. The margin is headroom for the drop shadow, which has to live
    // inside the window because a layered window cannot draw outside its own bounds.
    private const int PillWidth = 52;
    private const int PillHeight = 15;
    private const int Margin = 6;

    private const int SurfaceWidth = PillWidth + Margin * 2;
    private const int SurfaceHeight = PillHeight + Margin * 2;

    private enum Phase
    {
        In,
        Loop,
        Out,
        Hidden,
    }

    private static volatile nint _hwnd;
    private static nint _memoryDc;
    private static nint _bitmap;
    private static uint* _pixels;
    private static int _width;
    private static int _height;
    private static uint _dpi = 96;
    private static long _shownAtTicks;
    private static long _fadeOutAtTicks;
    private static Phase _phase = Phase.Hidden;
    private static Thread? _thread;
    private static readonly ManualResetEventSlim Ready = new(false);
    private static readonly object Gate = new();
    private static int _requestedX;
    private static int _requestedY;
    private static bool _classRegistered;

    /// <summary>
    /// Positions the indicator for the given caret rectangle and starts it. Called from the agent
    /// thread; all the window work happens on the indicator thread.
    /// </summary>
    internal static void Show(RECT caret, nint foreground)
    {
        try
        {
            EnsureThread();
            if (_hwnd == 0) return;

            uint dpi = NativeUi.DpiFor(foreground != 0 ? foreground : _hwnd);
            int width = NativeUi.Scale(SurfaceWidth, dpi);
            int height = NativeUi.Scale(SurfaceHeight, dpi);

            int x;
            int y;
            if (!caret.IsEmpty)
            {
                // Just below the caret rather than beside it, so it never sits on top of the text
                // being fixed. Nudged left by the shadow margin so the capsule lines up with the
                // caret rather than the invisible surface around it.
                x = caret.Left - NativeUi.Scale(Margin, dpi) + NativeUi.Scale(2, dpi);
                y = caret.Bottom + NativeUi.Scale(4, dpi) - NativeUi.Scale(Margin, dpi);
            }
            else if (Win32.GetCursorPos(out POINT cursor))
            {
                // Chromium and Electron apps publish no caret. The pointer is the next best guess
                // at where the user is looking, offset so the capsule never sits under the cursor.
                x = cursor.X + NativeUi.Scale(12, dpi);
                y = cursor.Y + NativeUi.Scale(20, dpi);
            }
            else
            {
                return;
            }
            NativeUi.ClampToScreen(ref x, ref y, width, height);

            lock (Gate)
            {
                _requestedX = x;
                _requestedY = y;
                _dpi = dpi;
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
            RegisterClass();
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

    private static void RegisterClass()
    {
        if (_classRegistered) return;
        fixed (char* className = ClassName)
        {
            var windowClass = new WNDCLASSEXW
            {
                cbSize = (uint)sizeof(WNDCLASSEXW),
                lpfnWndProc = (nint)(delegate* unmanaged<nint, uint, nuint, nint, nint>)&WndProc,
                hInstance = NativeUi.Instance,
                lpszClassName = className,
            };
            Win32.RegisterClassEx(&windowClass);
        }
        _classRegistered = true;
    }

    [UnmanagedCallersOnly]
    private static nint WndProc(nint hwnd, uint message, nuint wParam, nint lParam)
    {
        switch (message)
        {
            case WM.PULSE_SHOW:
                OnShow(hwnd);
                return 0;

            case WM.PULSE_HIDE:
                // Fades out rather than vanishing; the timer stops once the fade completes.
                if (_phase is Phase.In or Phase.Loop)
                {
                    _phase = Phase.Out;
                    _fadeOutAtTicks = Environment.TickCount64;
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
        lock (Gate)
        {
            x = _requestedX;
            y = _requestedY;
            dpi = _dpi;
        }

        int width = NativeUi.Scale(SurfaceWidth, dpi);
        int height = NativeUi.Scale(SurfaceHeight, dpi);
        EnsureSurface(width, height);
        if (_pixels == null) return;

        // A show during a fade-out restarts the entrance rather than resuming a half-faded pill.
        _shownAtTicks = Environment.TickCount64;
        _phase = Phase.In;
        Win32.SetWindowPos(hwnd, Win32.HWND_TOPMOST, x, y, width, height, Win32.SWP_NOACTIVATE);
        Win32.ShowWindow(hwnd, 4 /* SW_SHOWNOACTIVATE */);
        Paint(hwnd);
        Win32.SetTimer(hwnd, TimerId, FrameIntervalMs, 0);
    }

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
        if (_pixels == null || _memoryDc == 0) return;

        long now = Environment.TickCount64;

        // Entrance and exit: opacity plus a small scale, which is what makes it read as arriving
        // rather than blinking on.
        float opacity = 1f;
        switch (_phase)
        {
            case Phase.In:
                float inProgress = Math.Clamp((now - _shownAtTicks) / (float)FadeInMs, 0f, 1f);
                opacity = EaseOut(inProgress);
                if (inProgress >= 1f) _phase = Phase.Loop;
                break;

            case Phase.Out:
                float outProgress = Math.Clamp((now - _fadeOutAtTicks) / (float)FadeOutMs, 0f, 1f);
                opacity = 1f - EaseOut(outProgress);
                if (outProgress >= 1f)
                {
                    _phase = Phase.Hidden;
                    Win32.KillTimer(hwnd, TimerId);
                    Win32.ShowWindow(hwnd, Win32.SW_HIDE);
                    return;
                }
                break;

            case Phase.Hidden:
                Win32.KillTimer(hwnd, TimerId);
                return;
        }

        // 0.94 -> 1.0 on entry, and back down on exit.
        float scale = 0.94f + 0.06f * opacity;
        Render(now, opacity, scale);

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
    }

    /// <summary>
    /// Draws the whole indicator in one pass over the surface. Everything is a signed distance to
    /// the capsule, which gives antialiased edges, a soft shadow and a hairline rim from the same
    /// number without any clipping regions or extra bitmaps.
    /// </summary>
    private static void Render(long now, float opacity, float scale)
    {
        new Span<uint>(_pixels, _width * _height).Clear();

        float centreX = _width / 2f;
        float centreY = _height / 2f;
        float halfWidth = NativeUi.Scale(PillWidth, _dpi) / 2f * scale;
        float halfHeight = NativeUi.Scale(PillHeight, _dpi) / 2f * scale;
        float radius = halfHeight;
        float shadowSpread = NativeUi.Scale(Margin, _dpi) * 0.9f;
        float shadowDrop = NativeUi.Scale(2, _dpi);

        // Sweep position: one pass left to right per period, entering and leaving beyond the ends
        // so the bright segment appears to travel through the capsule rather than bounce inside it.
        float phase = (now % SweepPeriodMs) / (float)SweepPeriodMs;
        float travel = EaseInOut(phase);
        float sweepHalfWidth = halfWidth * 0.34f;
        // Overshoot is exactly one segment half-width at each end: enough for the light to enter
        // and leave through the rim, but not so much that the capsule sits empty for part of the
        // cycle - which is what a wider overshoot looked like, and it read as broken rather than
        // as working.
        float sweepCentreX = centreX + (halfWidth + sweepHalfWidth) * (travel * 2f - 1f);
        // Fade the segment at both ends of its run, so it never pops in or out at the rim.
        float sweepFade = MathF.Min(1f, MathF.Sin(phase * MathF.PI) * 1.8f);

        for (int y = 0; y < _height; y++)
        {
            for (int x = 0; x < _width; x++)
            {
                float px = x + 0.5f;
                float py = y + 0.5f;

                // Drop shadow, measured against a capsule pushed down a couple of pixels.
                float shadowDistance = CapsuleDistance(px, py - shadowDrop, centreX, centreY, halfWidth, halfHeight, radius);
                if (shadowDistance < shadowSpread)
                {
                    float falloff = 1f - Math.Clamp(shadowDistance / shadowSpread, 0f, 1f);
                    float shadowAlpha = falloff * falloff * 0.34f * opacity;
                    if (shadowAlpha > 0.002f) Blend(x, y, 0, 0, 0, (byte)(shadowAlpha * 255));
                }

                float distance = CapsuleDistance(px, py, centreX, centreY, halfWidth, halfHeight, radius);

                // Body.
                float bodyCoverage = Math.Clamp(0.5f - distance, 0f, 1f);
                if (bodyCoverage > 0f)
                {
                    Blend(x, y, 22, 24, 31, (byte)(bodyCoverage * 244 * opacity));
                }

                // Sweep, kept a pixel inside the body so the rim stays dark all the way round.
                float inner = distance + 1.4f;
                if (inner < 0f)
                {
                    float alongSweep = MathF.Abs(px - sweepCentreX) / sweepHalfWidth;
                    if (alongSweep < 1f)
                    {
                        // Squared falloff gives a soft comet rather than a hard block, and the
                        // inner term feathers it against the capsule wall.
                        float profile = 1f - alongSweep;
                        profile *= profile;
                        float edge = Math.Clamp(-inner, 0f, 1f);
                        float sweepAlpha = profile * edge * sweepFade * opacity;
                        if (sweepAlpha > 0.002f)
                        {
                            // Hot core to cool edge: white-ish in the middle, periwinkle outside.
                            byte r = (byte)(150 + 90 * profile);
                            byte g = (byte)(162 + 84 * profile);
                            byte b = (byte)(255);
                            Blend(x, y, r, g, b, (byte)(sweepAlpha * 255));
                        }
                    }
                }

                // Hairline rim on top of everything, which is what keeps the capsule readable
                // against a dark background where the shadow does nothing.
                float rim = 1f - Math.Clamp(MathF.Abs(distance + 0.7f) * 1.6f, 0f, 1f);
                if (rim > 0f)
                {
                    Blend(x, y, 255, 255, 255, (byte)(rim * 54 * opacity));
                }
            }
        }
    }

    /// <summary>Signed distance to a capsule: negative inside, zero on the edge.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static float CapsuleDistance(
        float px, float py, float centreX, float centreY, float halfWidth, float halfHeight, float radius)
    {
        float dx = MathF.Max(MathF.Abs(px - centreX) - (halfWidth - radius), 0f);
        float dy = MathF.Max(MathF.Abs(py - centreY) - (halfHeight - radius), 0f);
        return MathF.Sqrt(dx * dx + dy * dy) - radius;
    }

    private static float EaseOut(float t) => 1f - (1f - t) * (1f - t);

    private static float EaseInOut(float t) => t < 0.5f ? 2f * t * t : 1f - 2f * (1f - t) * (1f - t);

    /// <summary>Source-over blend in premultiplied alpha, the format UpdateLayeredWindow consumes.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void Blend(int x, int y, byte red, byte green, byte blue, byte alpha)
    {
        if (alpha == 0) return;
        uint* pixel = _pixels + y * _width + x;
        uint existing = *pixel;
        int inverse = 255 - alpha;

        int outB = blue * alpha / 255 + (int)(existing & 0xFF) * inverse / 255;
        int outG = green * alpha / 255 + (int)((existing >> 8) & 0xFF) * inverse / 255;
        int outR = red * alpha / 255 + (int)((existing >> 16) & 0xFF) * inverse / 255;
        int outA = alpha + (int)((existing >> 24) & 0xFF) * inverse / 255;

        *pixel = ((uint)Math.Min(outA, 255) << 24)
            | ((uint)Math.Min(outR, 255) << 16)
            | ((uint)Math.Min(outG, 255) << 8)
            | (uint)Math.Min(outB, 255);
    }
}
