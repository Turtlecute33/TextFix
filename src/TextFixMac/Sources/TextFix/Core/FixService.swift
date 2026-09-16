// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Orchestrates one text fix: validate, read the text out of the focused app, run the request off
/// the main thread, then write the result back. A second press while a request is in flight cancels
/// it rather than queuing another one.
///
/// Everything that touches the pasteboard, the Accessibility API or the keyboard runs on the main
/// thread, so there is exactly one writer and no lock around the target state.
final class FixService {
    private enum State {
        case idle
        case working
    }

    private let config: () -> AppConfig
    private weak var statusItem: StatusItem?

    private var state = State.idle
    private var token = 0
    private var currentTask: Task<Void, Never>?
    private var capture: TextCapture?
    private var pendingRestore: PasteboardSnapshot?

    init(config: @escaping () -> AppConfig, statusItem: StatusItem) {
        self.config = config
        self.statusItem = statusItem
    }

    // ---- start ----

    func start(actionIndex: Int) {
        // A second press is a cancel, not a second request: the first one still owns the caret.
        if state == .working {
            cancel()
            return
        }

        let config = self.config()
        guard actionIndex >= 0, actionIndex < config.actions.count else { return }
        let action = config.actions[actionIndex]
        guard action.enabled else {
            notify("Action disabled", "Enable it in TextFix settings.", isError: false)
            return
        }

        guard TextTarget.isTrusted else {
            // The one failure worth interrupting the user for, because it is the only one they can
            // fix and the only one that makes every hotkey press do nothing.
            Permissions.promptForAccessibility()
            return
        }

        let provider = config.providerValue
        var apiKey = ""
        var model = ""
        if !config.dryRun {
            apiKey = SecretStore.apiKey(for: provider)
            guard !apiKey.isEmpty else {
                notify("No API key", "Add your \(provider.displayName) key in TextFix settings.", isError: true)
                return
            }
            guard let resolved = config.resolveModel(action) else {
                notify("No model selected", "Pick a model in TextFix settings.", isError: true)
                return
            }
            model = resolved

            // The request is committed from here on, so overlap the TLS handshake with the capture
            // below instead of charging it to the user's wait.
            AiClient.prewarm(provider)
        }

        let options = CaptureOptions(
            allowSelectAll: action.wholeTextWhenNoSelection,
            skipPasswordFields: config.skipPasswordFields,
            takeSnapshot: config.restorePasteboard,
            useAccessibilityRead: config.useAccessibilityRead,
            selectionProbeMs: config.selectionProbeMs,
            copyTimeoutMs: config.copyTimeoutMs)

        let captured: TextCapture
        switch TextTarget.capture(options: options) {
        case .failed(let message):
            // capture() has already put the pasteboard back; it is the only code that knows how far
            // the probe got.
            notify("Nothing fixed", message, isError: true)
            return
        case .captured(let result):
            captured = result
        }

        guard captured.text.count <= config.maxInputLength else {
            restorePasteboardNow(captured.saved)
            notify("Too much text", "That is more than \(config.maxInputLength) characters.", isError: true)
            return
        }

        capture = captured
        state = .working
        token += 1
        let token = self.token

        showIndicator(config: config, capture: captured)

        if config.dryRun {
            // Nothing leaves the machine: an obviously-transformed result proves the capture and
            // replace halves work in this app, which is the part that varies between hosts.
            Log.info("Dry run: \(captured.text.count) characters, mode \(captured.mode)")
            complete(token: token, text: captured.text.uppercased(), zdrFallbackModel: nil, error: nil)
            return
        }

        let request = AiRequest(
            apiKey: apiKey,
            model: model,
            systemPrompt: action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Defaults.fixPrompt
                : action.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider,
            useZeroDataRetention: config.zeroDataRetention,
            disableReasoning: !config.allowReasoning,
            totalBudgetMs: config.requestBudgetMs)

        let input = captured.text
        currentTask = Task {
            do {
                let result = try await AiClient.fixText(input, request)
                DispatchQueue.main.async { [weak self] in
                    self?.complete(
                        token: token,
                        text: result.text,
                        zdrFallbackModel: result.fellBackFromZdr ? request.model : nil,
                        error: nil)
                }
            } catch is CancellationError {
                // The user asked for it; nothing to report.
            } catch {
                Log.warn("Text fix failed: " + AiErrors.scrub("\(type(of: error)): \(error)"))
                let message = AiErrors.userFacing(error, fallback: "Could not fix that text.")
                DispatchQueue.main.async { [weak self] in
                    self?.complete(token: token, text: nil, zdrFallbackModel: nil, error: message)
                }
            }
        }
    }

    // ---- cancel ----

    func cancel() {
        guard state == .working else { return }
        token += 1 // invalidates the in-flight completion
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        hideIndicator()
        restorePasteboardNow(capture?.saved)
        capture = nil
    }

    // ---- finish ----

    private func complete(token: Int, text: String?, zdrFallbackModel: String?, error: String?) {
        guard token == self.token, state == .working else { return } // stale or cancelled

        state = .idle
        currentTask = nil
        hideIndicator()

        let capture = self.capture
        self.capture = nil
        let config = self.config()

        if let zdrFallbackModel, AiClient.shouldWarnAboutZdrFallback(zdrFallbackModel) {
            notify(
                "Zero data retention unavailable",
                "This request used standard routing for \(zdrFallbackModel).",
                isError: false)
        }

        if let error {
            restorePasteboardNow(capture?.saved)
            notify("Text fix failed", error, isError: true)
            return
        }
        guard let text, let capture else {
            // Cancelled between the request finishing and here.
            restorePasteboardNow(capture?.saved)
            return
        }

        // Unwrap first: a prompt that fences its input in tags sometimes gets tags back.
        let proposed = AiText.sanitize(AiText.unwrap(text), maxLength: Defaults.maxOutputLength)
        guard !proposed.isEmpty else {
            restorePasteboardNow(capture.saved)
            notify("Text fix failed", "The model returned nothing usable.", isError: true)
            return
        }
        guard proposed != capture.text else {
            // Nothing to change. Writing identical text would still cost the user an undo step and
            // a scroll jump, so leave the field alone.
            restorePasteboardNow(capture.saved)
            Log.debug("Model returned the input unchanged; field left untouched")
            return
        }

        let outcome = TextTarget.replace(
            capture: capture,
            with: proposed,
            requireSameFocus: config.replaceOnlyIfFocusUnchanged,
            mode: config.replaceModeValue)

        switch outcome {
        case .replaced:
            // Whether the pasteboard was borrowed is a fact, not something to infer from the
            // configured mode: an Accessibility write that was refused falls back to a paste, and
            // a paste that happened needs the delay whatever asked for it.
            let pasteboardMoved = capture.saved.map { $0.changeCount != PasteboardBridge.changeCount } ?? false
            if let saved = capture.saved, pasteboardMoved {
                // The paste needs the pasteboard to stay put for a moment: some hosts read it
                // asynchronously after Cmd+V returns.
                pendingRestore = saved
                let delay = Double(max(config.pasteboardRestoreDelayMs, 1)) / 1000
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let snapshot = self.pendingRestore else { return }
                    self.pendingRestore = nil
                    PasteboardBridge.restoreOrClear(snapshot)
                }
            } else {
                restorePasteboardNow(capture.saved)
            }
            if capture.saved?.complete == false {
                notify(
                    "Clipboard partly restored",
                    "Some clipboard content could not be copied back.",
                    isError: false)
            }

        case .focusChanged:
            // Never write into a window the user switched to. Hand them the text instead.
            PasteboardBridge.setText(proposed, transient: false)
            notify("Focus changed", "The fixed text is on your clipboard.", isError: false)

        case .blocked:
            restorePasteboardNow(capture.saved)
            Permissions.promptForAccessibility()

        case .failed:
            restorePasteboardNow(capture.saved)
            notify("Text fix failed", "Could not put the fixed text back.", isError: true)
        }
    }

    // ---- shared ----

    private func showIndicator(config: AppConfig, capture: TextCapture) {
        switch config.indicatorValue {
        case .caret:
            CaretPulse.shared.show(caretRect: capture.caretRect)
        case .menubar:
            statusItem?.setWorking(true)
        case .none:
            break
        }
        statusItem?.setTooltip("TextFix - fixing text…")
    }

    private func hideIndicator() {
        CaretPulse.shared.hide()
        statusItem?.setWorking(false)
        statusItem?.setTooltip(StatusItem.idleTooltip)
    }

    private func restorePasteboardNow(_ snapshot: PasteboardSnapshot?) {
        guard let snapshot else { return }
        PasteboardBridge.restoreOrClear(snapshot)
    }

    private func notify(_ title: String, _ message: String, isError: Bool) {
        if isError { Log.warn("\(title): \(message)") } else { Log.info("\(title): \(message)") }
        guard config().notifyOnError else { return }
        Toast.shared.show(title: title, message: message, isError: isError)
    }

    func shutdown() {
        currentTask?.cancel()
        currentTask = nil
        pendingRestore = nil
    }
}
