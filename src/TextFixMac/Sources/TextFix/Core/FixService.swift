// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Orchestrates one text fix: validate, read the text out of the focused app, run the request off
/// the main thread, then write the result back. A second press while a request is in flight cancels
/// it rather than queuing another one.
///
/// Everything that touches the pasteboard, the Accessibility API or the keyboard runs on the main
/// thread, so there is exactly one writer and no lock around the target state. That confinement is
/// what `@unchecked Sendable` below asserts: the request task hops back through the main queue
/// before it touches anything here, and the compiler cannot see that for itself.
///
/// The pasteboard is the one piece of irreplaceable user data this code holds, so the rule around
/// it is absolute: a restore that has been scheduled is always settled before anything else is
/// allowed to touch the pasteboard. `flushPendingRestore` is that guarantee, and every path that
/// could otherwise drop one calls it - a second fix, a cancel, and the app quitting.
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
    private var pendingRestoreWork: DispatchWorkItem?

    /// True while an indicator is on screen, so every exit path can take it down again.
    private var indicatorShown = false

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

        // The previous fix may still have a pasteboard restore waiting on its timer. Taking a
        // snapshot now would record our own output as "what the user was holding", and scheduling
        // a second restore would silently drop the first - so settle the old one before anything
        // here is allowed near the pasteboard.
        flushPendingRestore()

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
            copyTimeoutMs: config.copyTimeoutMs,
            // One code unit past the limit is all that is ever worth reading: the check below
            // rejects anything that long, and the cap is what stops a 200 MB pasteboard being
            // turned into a String on the main thread just to discover it was never going to fit.
            maxUTF16: config.maxInputLength + 1)

        let captured: TextCapture
        // Feedback goes up as soon as the target is known, rather than after the capture. The
        // pasteboard path spends the better part of a second in round trips, and a hotkey that
        // changes nothing on screen for that long reads as a dead key. It starts in its quiet form
        // - present, not sweeping - and is promoted once the request is actually in flight.
        switch TextTarget.capture(options: options, onTargetResolved: { [weak self] caretRect in
            self?.showIndicator(config: config, caretRect: caretRect, sweeping: false)
        }) {
        case .failed(let message):
            // capture() has already put the pasteboard back; it is the only code that knows how far
            // the probe got.
            hideIndicator()
            notify("Nothing fixed", message, isError: true)
            return
        case .captured(let result):
            captured = result
        }

        // Counted in UTF-16 code units, which is what the Windows agent counts, so one
        // maxInputLength in config.json means the same thing on both platforms.
        guard captured.text.utf16.count <= config.maxInputLength else {
            hideIndicator()
            restorePasteboardNow(captured.saved)
            notify("Too much text", "That is more than \(config.maxInputLength) characters.", isError: true)
            return
        }

        capture = captured
        state = .working
        token += 1
        let token = self.token

        // Now that the real caret rectangle is known, settle the indicator onto it and promote it
        // to the sweeping form. Repositioning does not restart the entrance animation.
        showIndicator(config: config, caretRect: captured.caretRect, sweeping: true)

        if config.dryRun {
            // Nothing leaves the machine: an obviously-transformed result proves the capture and
            // replace halves work in this app, which is the part that varies between hosts.
            Log.info("Dry run: \(captured.text.utf16.count) characters, mode \(captured.mode)")
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
        currentTask = Task { [weak self] in
            do {
                let result = try await AiClient.fixText(input, request)
                DispatchQueue.main.async {
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
                DispatchQueue.main.async {
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
        // Belt and braces: start already settles any pending restore before it reaches .working,
        // so this should find nothing. It is here so the invariant survives a future edit that
        // reorders the two.
        flushPendingRestore()
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
                schedulePasteboardRestore(saved, afterMs: config.pasteboardRestoreDelayMs)
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
            // Never write into a window the user switched to. Hand them the text instead - flagged
            // transient, because a rewrite they never asked to keep has no business being archived
            // by a clipboard manager or synced to their other devices.
            PasteboardBridge.setText(proposed, transient: true)
            notify(
                "Focus changed",
                capture.saved.map { !$0.isEmpty } == true
                    ? "The fixed text is on your clipboard, replacing what was there."
                    : "The fixed text is on your clipboard.",
                isError: false)

        case .blocked:
            restorePasteboardNow(capture.saved)
            Permissions.promptForAccessibility()

        case .failed:
            restorePasteboardNow(capture.saved)
            notify("Text fix failed", "Could not put the fixed text back.", isError: true)
        }
    }

    // ---- pasteboard ----

    private func schedulePasteboardRestore(_ snapshot: PasteboardSnapshot, afterMs: Int) {
        flushPendingRestore()
        pendingRestore = snapshot
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestoreWork = nil
            self.flushPendingRestore()
        }
        pendingRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(max(afterMs, 1)) / 1000, execute: work)
    }

    /// Runs a pasteboard restore that is still waiting on its timer, right now.
    ///
    /// Every caller exists because the restore would otherwise be lost. A second fix would
    /// overwrite the snapshot; quitting would cancel the queued block outright. Either way the
    /// user's clipboard would be gone and our own output left sitting in its place.
    func flushPendingRestore() {
        pendingRestoreWork?.cancel()
        pendingRestoreWork = nil
        guard let snapshot = pendingRestore else { return }
        pendingRestore = nil
        PasteboardBridge.restoreOrClear(snapshot)
    }

    private func restorePasteboardNow(_ snapshot: PasteboardSnapshot?) {
        guard let snapshot else { return }
        PasteboardBridge.restoreOrClear(snapshot)
    }

    // ---- shared ----

    private func showIndicator(config: AppConfig, caretRect: CGRect?, sweeping: Bool) {
        switch config.indicatorValue {
        case .caret:
            CaretPulse.shared.show(caretRect: caretRect, sweeping: sweeping)
        case .menubar:
            statusItem?.setWorking(true)
        case .none:
            break
        }
        indicatorShown = true
        // The tooltip is the only place the agent can say that a second press cancels, which is
        // otherwise completely undiscoverable.
        statusItem?.setTooltip(sweeping
            ? "TextFix - fixing text… (press the hotkey again to cancel)"
            : "TextFix - reading text…")
    }

    private func hideIndicator() {
        guard indicatorShown else { return }
        indicatorShown = false
        CaretPulse.shared.hide()
        statusItem?.setWorking(false)
        statusItem?.setTooltip(StatusItem.idleTooltip)
    }

    private func notify(_ title: String, _ message: String, isError: Bool) {
        if isError { Log.warn("\(title): \(message)") } else { Log.info("\(title): \(message)") }
        guard config().notifyOnError else { return }
        Toast.shared.show(title: title, message: message, isError: isError)
    }

    func shutdown() {
        currentTask?.cancel()
        currentTask = nil
        // Settled rather than discarded: a quit inside the restore delay would otherwise leave the
        // user holding our output instead of whatever they had copied.
        flushPendingRestore()
    }
}

/// Main-thread-confined by construction - see the type comment. The request task captures it only
/// to hop back through the main queue, which is the one thing the compiler cannot verify for
/// itself, so the guarantee is asserted here rather than re-established with a lock.
extension FixService: @unchecked Sendable {}
