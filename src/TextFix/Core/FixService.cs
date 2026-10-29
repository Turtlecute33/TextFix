// SPDX-License-Identifier: GPL-3.0-only
using System.Net.NetworkInformation;
using TextFix.Ai;
using TextFix.Configuration;
using TextFix.Editing;
using TextFix.Interop;
using TextFix.Ui;

namespace TextFix.Core;

/// <summary>
/// Orchestrates one text fix: validate, read the text out of the focused app, run the request off
/// the message thread, then paste the result back. A second press while a request is in flight
/// cancels it rather than queuing another one.
///
/// Everything that touches the clipboard or synthesises keys runs on the message thread, so there
/// is exactly one writer and no lock needed around the target state.
///
/// The clipboard is the one piece of irreplaceable user data this code holds, so the rule around it
/// is absolute: a restore that has been armed is always settled before anything else is allowed to
/// touch the clipboard. <see cref="FlushPendingRestore"/> is that guarantee, and every path that
/// could otherwise drop a pending restore calls it - a second fix, a cancel, and shutdown.
/// </summary>
internal sealed class FixService
{
    internal enum State
    {
        Idle,
        Working,
    }

    internal const nuint RestoreTimerId = 21;

    /// <summary>Shown while the capture is running, before the request has gone out.</summary>
    private const string ReadingTooltip = "TextFix - reading text...";

    /// <summary>
    /// Shown while the request is in flight. It names the cancel gesture because a second press
    /// cancelling is otherwise undiscoverable - there is nowhere else the agent could say it.
    /// </summary>
    private const string WorkingTooltip = "TextFix - fixing text... (press the hotkey again to cancel)";

    private readonly nint _hwnd;
    private readonly TrayIcon _tray;
    private readonly Func<AppConfig> _config;

    private State _state = State.Idle;
    private long _token;
    private CancellationTokenSource? _cts;

    // Handed from the request thread to the message thread, read only after the completion
    // message for the matching token arrives.
    private TextCapture? _capture;
    private string _prompt = string.Empty;
    private volatile string? _resultText;
    private volatile string? _errorText;
    private volatile string? _zdrFallbackModel;
    private ClipboardSnapshot? _pendingRestore;

    /// <summary>True while an indicator is on screen, so every exit path can take it down again.</summary>
    private bool _indicatorShown;

    internal FixService(nint hwnd, TrayIcon tray, Func<AppConfig> config)
    {
        _hwnd = hwnd;
        _tray = tray;
        _config = config;
    }

    internal void Start(int actionIndex)
    {
        // A second press is a cancel, not a second request: the first one still owns the caret.
        if (_state == State.Working)
        {
            Cancel();
            return;
        }

        // The previous fix may still have a clipboard restore sitting on the timer. Taking a
        // snapshot now would record our own output as "what the user was holding", and arming a
        // second restore would silently drop the first - so settle the old one before anything
        // here is allowed near the clipboard.
        FlushPendingRestore();

        AppConfig config = _config();
        if (actionIndex < 0 || actionIndex >= config.Actions.Count) return;
        FixActionConfig action = config.Actions[actionIndex];
        if (!action.Enabled)
        {
            Notify("Action disabled", "Enable it in TextFix settings.", isError: false);
            return;
        }

        AiProvider provider = config.ProviderValue;
        string apiKey = string.Empty;
        string model = string.Empty;
        if (!config.DryRun)
        {
            apiKey = SecretStore.GetApiKey(provider);
            if (apiKey.Length == 0)
            {
                Notify("No API key", "Add your " + provider.DisplayName() + " key in TextFix settings.", isError: true);
                return;
            }
            string? resolved = config.ResolveModel(action);
            if (resolved == null)
            {
                Notify("No model selected", "Pick a model in TextFix settings.", isError: true);
                return;
            }
            model = resolved;
            if (!IsNetworkAvailable())
            {
                Notify("Offline", "TextFix needs a connection to fix text.", isError: true);
                return;
            }

            // The request is committed from here on, so overlap the TLS handshake with the
            // clipboard round trip below instead of charging it to the user's wait.
            AiClient.Prewarm(provider);
        }

        // Feedback *before* the capture rather than after it. The whole-field path spends the
        // better part of a second in clipboard round trips, and a hotkey that changes nothing on
        // screen for that long reads as a dead key. The indicator starts in its quiet form -
        // present, not sweeping - and is promoted once the request is actually in flight, so the
        // two questions the user has at those two moments ("did my key register?" and "is it
        // stuck?") each get their own answer.
        nint foreground = Win32.GetForegroundWindow();
        ShowIndicator(config, TextTarget.GetCaretRect(foreground), foreground, sweeping: false);

        var options = new CaptureOptions(
            AllowSelectAll: action.WholeTextWhenNoSelection,
            SkipPasswordFields: config.SkipPasswordFields,
            TakeSnapshot: config.RestoreClipboard,
            SelectionProbeMs: config.SelectionProbeMs,
            CopyTimeoutMs: config.CopyTimeoutMs,
            // One character past the limit is all we ever need to read: the check below rejects
            // anything that long, and the cap is what stops a 200 MB clipboard being turned into
            // a string on the message thread just to discover it was never going to fit.
            MaxChars: config.MaxInputLength + 1);

        if (!TextTarget.TryCapture(_hwnd, options, out TextCapture? capture, out string captureError) || capture == null)
        {
            // TryCapture has already put the clipboard back; it is the only code that knows how
            // far the probe got.
            HideIndicator();
            Notify("Nothing fixed", captureError, isError: true);
            return;
        }

        if (capture.Text.Length > config.MaxInputLength)
        {
            HideIndicator();
            RestoreAfterCapture(capture);
            Notify("Too much text", "That is more than " + config.MaxInputLength + " characters.", isError: true);
            return;
        }

        _capture = capture;
        _prompt = string.IsNullOrWhiteSpace(action.Prompt) ? Defaults.FixPrompt : action.Prompt.Trim();
        _resultText = null;
        _errorText = null;
        _zdrFallbackModel = null;
        _state = State.Working;
        long token = ++_token;

        // Now that the real caret rectangle is known, settle the indicator onto it and promote it
        // to the sweeping form. Repositioning does not restart the entrance animation.
        ShowIndicator(config, capture.CaretRect, capture.Foreground, sweeping: true);

        if (config.DryRun)
        {
            // Nothing leaves the machine: an obviously-transformed result proves the capture and
            // paste halves work in this app, which is the part that varies between hosts.
            _resultText = capture.Text.ToUpperInvariant();
            Log.Info("Dry run: " + capture.Text.Length + " characters, mode " + capture.Mode);
            Win32.PostMessage(_hwnd, WM.FIX_COMPLETE, (nuint)token, 0);
            return;
        }

        var request = new AiRequest(
            ApiKey: apiKey,
            Model: model,
            SystemPrompt: _prompt,
            Provider: provider,
            UseZeroDataRetention: config.ZeroDataRetention,
            DisableReasoning: !config.AllowReasoning,
            TotalBudgetMs: config.RequestBudgetMs);

        var cts = new CancellationTokenSource();
        _cts = cts;
        string input = capture.Text;

        _ = Task.Run(async () =>
        {
            try
            {
                AiResult result = await AiClient.FixTextAsync(input, request, cts.Token).ConfigureAwait(false);
                _resultText = result.Text;
                if (result.FellBackFromZdr) _zdrFallbackModel = request.Model;
            }
            catch (OperationCanceledException)
            {
                _errorText = null; // the user asked for it; nothing to report
            }
            catch (Exception e)
            {
                Log.Warn("Text fix failed: " + AiErrors.Scrub(e.GetType().Name + ": " + e.Message));
                _errorText = AiErrors.UserFacing(e, "Could not fix that text.");
            }
            finally
            {
                // Hand control back to the message thread; it owns the clipboard and the caret.
                Win32.PostMessage(_hwnd, WM.FIX_COMPLETE, (nuint)token, 0);
            }
        });
    }

    internal void Cancel()
    {
        if (_state != State.Working) return;
        _token++; // invalidates the in-flight completion message
        _cts?.Cancel();
        _cts = null;
        _state = State.Idle;
        HideIndicator();
        // Belt and braces: Start already settles any pending restore before it reaches Working,
        // so this should find nothing. It is here so the invariant survives a future edit that
        // reorders the two.
        FlushPendingRestore();
        RestoreAfterCapture(_capture);
        _capture = null;
    }

    /// <summary>Runs on the message thread once the request thread has posted its result.</summary>
    internal void Complete(long token)
    {
        if (token != _token || _state != State.Working) return; // stale or cancelled

        _state = State.Idle;
        _cts = null;
        HideIndicator();

        TextCapture? capture = _capture;
        _capture = null;
        AppConfig config = _config();

        if (_zdrFallbackModel is string fallbackModel && AiClient.ShouldWarnAboutZdrFallback(fallbackModel))
        {
            Notify(
                "Zero data retention unavailable",
                "No zero-retention route for " + fallbackModel + ". TextFix used a provider that does not keep your text for training.",
                isError: false);
        }

        if (_errorText is string error)
        {
            RestoreAfterCapture(capture);
            Notify("Text fix failed", error, isError: true);
            return;
        }
        if (_resultText == null || capture == null)
        {
            // Cancelled between the post and here.
            RestoreAfterCapture(capture);
            return;
        }

        // Unwrap first: a prompt that fences its input in tags sometimes gets tags back.
        string answer = AiText.Sanitize(AiText.Unwrap(_resultText, _prompt));
        _resultText = null;
        if (answer.Length == 0)
        {
            RestoreAfterCapture(capture);
            Notify("Text fix failed", "The model returned nothing usable.", isError: true);
            return;
        }
        if (answer.Length > AiText.OutputLimit(capture.Text.Length))
        {
            // Refused, never cut: a shortened answer pasted over the field deletes its end.
            RestoreAfterCapture(capture);
            Notify("Text fix failed", "The answer was much longer than your text, so nothing was changed.", isError: true);
            return;
        }
        // CF_UNICODETEXT is CRLF by convention, and classic edit controls show a bare LF as
        // nothing at all, running the paragraphs together. A capture that itself came back with
        // bare LFs is from a host that uses them, and gets them back.
        bool lfOnly = capture.Text.Contains('\n') && !capture.Text.Contains("\r\n", StringComparison.Ordinal);
        if (!lfOnly) answer = answer.ReplaceLineEndings("\r\n");
        string proposed = AiText.KeepEdgeWhitespace(capture.Text, answer);
        if (string.Equals(proposed, capture.Text, StringComparison.Ordinal))
        {
            // Nothing to change. Pasting identical text would still cost the user an undo step
            // and a scroll jump, so leave the field alone - but say so, or the hotkey looks dead.
            RestoreAfterCapture(capture);
            Notify("No changes needed", "The text is already fine as it is.", isError: false);
            return;
        }

        // Something new on the clipboard since the capture is most likely the user copying while
        // the request was out. That is what they are holding now, so that is what comes back
        // after the paste, not the older snapshot.
        ClipboardSnapshot? restoreTo = capture.Saved;
        if (restoreTo != null && ClipboardBridge.SequenceNumber() != capture.ClipboardSequence)
        {
            restoreTo = ClipboardBridge.Snapshot(_hwnd) ?? restoreTo;
        }

        ReplaceOutcome outcome = TextTarget.Replace(_hwnd, capture, proposed, config.PasteOnlyIfFocusUnchanged);
        switch (outcome)
        {
            case ReplaceOutcome.Pasted:
                if (restoreTo != null)
                {
                    // The paste needs the clipboard to stay put for a moment: some hosts read it
                    // asynchronously after Ctrl+V returns. Restoring on a timer keeps the message
                    // thread free in the meantime.
                    _pendingRestore = restoreTo;
                    Win32.SetTimer(_hwnd, RestoreTimerId, (uint)Math.Max(config.ClipboardRestoreDelayMs, 1), 0);
                }
                if (restoreTo is { Complete: false })
                {
                    Notify(
                        "Clipboard partly restored",
                        "Some clipboard content could not be copied back.",
                        isError: false);
                }
                break;

            case ReplaceOutcome.FocusChanged:
                // Never paste into a window the user switched to. Hand them the text instead -
                // flagged transient, because a rewrite they never asked to keep has no business
                // being archived in Win+V history or synced to their other devices.
                bool handedOver = ClipboardBridge.SetText(proposed, _hwnd, transient: true);
                Notify(
                    "Text not replaced",
                    !handedOver
                        ? "Focus changed while TextFix worked, and the clipboard was busy. Nothing was changed."
                        : capture.Saved is { IsEmpty: false }
                            ? "Focus changed while TextFix worked. The fixed text is on your clipboard, replacing what was there."
                            : "Focus changed while TextFix worked. The fixed text is on your clipboard.",
                    isError: !handedOver);
                break;

            case ReplaceOutcome.Blocked:
                // Replace can put the fixed text on the clipboard before it fails. Then
                // RestoreAfterCapture sees a new sequence number and does not restore.
                if (restoreTo != null) ClipboardBridge.RestoreOrClear(restoreTo, _hwnd);
                Notify(
                    "Windows blocked the paste",
                    "That window is running as administrator, so TextFix cannot type into it.",
                    isError: true);
                break;

            default:
                if (restoreTo != null) ClipboardBridge.RestoreOrClear(restoreTo, _hwnd);
                Notify("Text fix failed", "Could not paste the fixed text.", isError: true);
                break;
        }
    }

    internal void OnRestoreTimer() => FlushPendingRestore();

    /// <summary>
    /// Runs a clipboard restore that is still sitting on the timer, right now.
    ///
    /// Every caller exists because the restore would otherwise be lost. A second fix would
    /// overwrite the snapshot and reset the timer; a quit would drop the WM_TIMER entirely, since
    /// GetMessage retrieves WM_QUIT well ahead of WM_TIMER in the queue's priority order. Either
    /// way the user's clipboard would be gone and our own output left sitting in its place.
    /// </summary>
    internal void FlushPendingRestore()
    {
        ClipboardSnapshot? snapshot = _pendingRestore;
        if (snapshot == null) return;
        _pendingRestore = null;
        Win32.KillTimer(_hwnd, RestoreTimerId);
        ClipboardBridge.RestoreOrClear(snapshot, _hwnd);
    }

    /// <summary>
    /// Puts the clipboard back after a capture that ended without a paste - unless something new
    /// landed on it while the request was out. That is most likely the user copying something,
    /// and it is now what they are holding; the older snapshot would overwrite it.
    /// </summary>
    private void RestoreAfterCapture(TextCapture? capture)
    {
        if (capture?.Saved == null) return;
        if (ClipboardBridge.SequenceNumber() != capture.ClipboardSequence)
        {
            Log.Debug("The clipboard changed during the request; left as it is");
            return;
        }
        ClipboardBridge.RestoreOrClear(capture.Saved, _hwnd);
    }

    private void ShowIndicator(AppConfig config, RECT caret, nint foreground, bool sweeping)
    {
        if (config.Indicator == "caret") CaretPulse.Show(caret, foreground, sweeping);
        _indicatorShown = true;
        _tray.SetTooltip(sweeping ? WorkingTooltip : ReadingTooltip);
    }

    private void HideIndicator()
    {
        if (!_indicatorShown) return;
        _indicatorShown = false;
        CaretPulse.Hide();
        _tray.SetTooltip(AgentWindow.IdleTooltip);
    }

    private void Notify(string title, string message, bool isError)
    {
        if (isError) Log.Warn(title + ": " + message);
        else Log.Info(title + ": " + message);
        if (_config().NotifyOnError) _tray.ShowBalloon(title, message, isError);
    }

    private static bool IsNetworkAvailable()
    {
        try
        {
            return NetworkInterface.GetIsNetworkAvailable();
        }
        catch
        {
            // If the check itself fails, let the request decide rather than blocking the feature.
            return true;
        }
    }

    internal void Dispose()
    {
        _cts?.Cancel();
        _cts = null;
    }
}
