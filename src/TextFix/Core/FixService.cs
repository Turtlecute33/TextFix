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
/// </summary>
internal sealed class FixService
{
    internal enum State
    {
        Idle,
        Working,
    }

    internal const nuint RestoreTimerId = 21;

    private readonly nint _hwnd;
    private readonly TrayIcon _tray;
    private readonly Func<AppConfig> _config;

    private State _state = State.Idle;
    private long _token;
    private CancellationTokenSource? _cts;

    // Handed from the request thread to the message thread, read only after the completion
    // message for the matching token arrives.
    private TextCapture? _capture;
    private volatile string? _resultText;
    private volatile string? _errorText;
    private volatile string? _zdrFallbackModel;
    private ClipboardSnapshot? _pendingRestore;

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

        var options = new CaptureOptions(
            AllowSelectAll: action.WholeTextWhenNoSelection,
            SkipPasswordFields: config.SkipPasswordFields,
            TakeSnapshot: config.RestoreClipboard,
            SelectionProbeMs: config.SelectionProbeMs,
            CopyTimeoutMs: config.CopyTimeoutMs);

        if (!TextTarget.TryCapture(_hwnd, options, out TextCapture? capture, out string captureError) || capture == null)
        {
            // TryCapture has already put the clipboard back; it is the only code that knows how
            // far the probe got.
            Notify("Nothing fixed", captureError, isError: true);
            return;
        }

        if (capture.Text.Length > config.MaxInputLength)
        {
            RestoreClipboardNow(capture.Saved);
            Notify("Too much text", "That is more than " + config.MaxInputLength + " characters.", isError: true);
            return;
        }

        _capture = capture;
        _resultText = null;
        _errorText = null;
        _zdrFallbackModel = null;
        _state = State.Working;
        long token = ++_token;

        if (config.Indicator == "caret") CaretPulse.Show(capture.CaretRect, capture.Foreground);
        _tray.SetTooltip("TextFix - fixing text...");

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
            SystemPrompt: string.IsNullOrWhiteSpace(action.Prompt) ? Defaults.FixPrompt : action.Prompt.Trim(),
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
        CaretPulse.Hide();
        _tray.SetTooltip(AgentWindow.IdleTooltip);
        RestoreClipboardNow(_capture?.Saved);
        _capture = null;
    }

    /// <summary>Runs on the message thread once the request thread has posted its result.</summary>
    internal void Complete(long token)
    {
        if (token != _token || _state != State.Working) return; // stale or cancelled

        _state = State.Idle;
        _cts = null;
        CaretPulse.Hide();
        _tray.SetTooltip(AgentWindow.IdleTooltip);

        TextCapture? capture = _capture;
        _capture = null;
        AppConfig config = _config();

        if (_zdrFallbackModel is string fallbackModel && AiClient.ShouldWarnAboutZdrFallback(fallbackModel))
        {
            Notify(
                "Zero data retention unavailable",
                "This request used standard routing for " + fallbackModel + ".",
                isError: false);
        }

        if (_errorText is string error)
        {
            RestoreClipboardNow(capture?.Saved);
            Notify("Text fix failed", error, isError: true);
            return;
        }
        if (_resultText == null || capture == null)
        {
            // Cancelled between the post and here.
            RestoreClipboardNow(capture?.Saved);
            return;
        }

        // Unwrap first: a prompt that fences its input in tags sometimes gets tags back.
        string proposed = AiText.Sanitize(AiText.Unwrap(_resultText), Defaults.MaxOutputLength);
        _resultText = null;
        if (proposed.Length == 0)
        {
            RestoreClipboardNow(capture.Saved);
            Notify("Text fix failed", "The model returned nothing usable.", isError: true);
            return;
        }
        if (string.Equals(proposed, capture.Text, StringComparison.Ordinal))
        {
            // Nothing to change. Pasting identical text would still cost the user an undo step
            // and a scroll jump, so leave the field alone.
            RestoreClipboardNow(capture.Saved);
            Log.Debug("Model returned the input unchanged; field left untouched");
            return;
        }

        ReplaceOutcome outcome = TextTarget.Replace(_hwnd, capture, proposed, config.PasteOnlyIfFocusUnchanged);
        switch (outcome)
        {
            case ReplaceOutcome.Pasted:
                if (capture.Saved != null)
                {
                    // The paste needs the clipboard to stay put for a moment: some hosts read it
                    // asynchronously after Ctrl+V returns. Restoring on a timer keeps the message
                    // thread free in the meantime.
                    _pendingRestore = capture.Saved;
                    Win32.SetTimer(_hwnd, RestoreTimerId, (uint)Math.Max(config.ClipboardRestoreDelayMs, 1), 0);
                }
                if (capture.Saved is { Complete: false })
                {
                    Notify(
                        "Clipboard partly restored",
                        "Some clipboard content could not be copied back.",
                        isError: false);
                }
                break;

            case ReplaceOutcome.FocusChanged:
                // Never paste into a window the user switched to. Hand them the text instead.
                ClipboardBridge.SetText(proposed, _hwnd, transient: false);
                Notify("Focus changed", "The fixed text is on your clipboard.", isError: false);
                break;

            case ReplaceOutcome.Blocked:
                RestoreClipboardNow(capture.Saved);
                Notify(
                    "Windows blocked the paste",
                    "That window is running as administrator, so TextFix cannot type into it.",
                    isError: true);
                break;

            default:
                RestoreClipboardNow(capture.Saved);
                Notify("Text fix failed", "Could not paste the fixed text.", isError: true);
                break;
        }
    }

    internal void OnRestoreTimer()
    {
        Win32.KillTimer(_hwnd, RestoreTimerId);
        ClipboardSnapshot? snapshot = _pendingRestore;
        _pendingRestore = null;
        if (snapshot != null) ClipboardBridge.RestoreOrClear(snapshot, _hwnd);
    }

    private void RestoreClipboardNow(ClipboardSnapshot? snapshot)
    {
        if (snapshot != null) ClipboardBridge.RestoreOrClear(snapshot, _hwnd);
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
