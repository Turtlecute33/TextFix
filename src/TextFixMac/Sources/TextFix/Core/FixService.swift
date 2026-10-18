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
    private var prompt = ""
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
            restoreAfterCapture(captured)
            notify("Too much text", "That is more than \(config.maxInputLength) characters.", isError: true)
            return
        }

        capture = captured
        let trimmedPrompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = trimmedPrompt.isEmpty ? Defaults.fixPrompt : trimmedPrompt
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
            systemPrompt: prompt,
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
        restoreAfterCapture(capture)
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
                "No zero-retention route for \(zdrFallbackModel). TextFix used a provider that does not keep your text for training.",
                isError: false)
        }

        if let error {
            restoreAfterCapture(capture)
            notify("Text fix failed", error, isError: true)
            return
        }
        guard let text, let capture else {
            // Cancelled between the request finishing and here.
            restoreAfterCapture(capture)
            return
        }

        // Unwrap first: a prompt that fences its input in tags sometimes gets tags back.
        let answer = AiText.sanitize(AiText.unwrap(text, prompt: prompt))
        guard !answer.isEmpty else {
            restoreAfterCapture(capture)
            notify("Text fix failed", "The model returned nothing usable.", isError: true)
            return
        }
        guard answer.utf16.count <= AiText.outputLimit(inputLength: capture.text.utf16.count) else {
            // Refused, never cut: a shortened answer pasted over the field deletes its end.
            restoreAfterCapture(capture)
            notify("Text fix failed", "The answer was much longer than your text, so nothing was changed.", isError: true)
            return
        }
        let proposed = AiText.keepEdgeWhitespace(original: capture.text, answer: answer)
        guard proposed != capture.text else {
            // Nothing to change. Writing identical text would still cost the user an undo step and
            // a scroll jump, so leave the field alone - but say so, or the hotkey looks dead.
            restoreAfterCapture(capture)
            notify("No changes needed", "The text is already fine as it is.", isError: false)
            return
        }

        // What comes back after a paste. Normally the snapshot from the capture; but the
        // Accessibility path took none, and on either path something new on the pasteboard since
        // the capture is most likely the user copying while the request was out - that is what
        // they are holding now, so that is what is snapshotted, at the last moment.
        var restoreTo = capture.saved
        let outcome = TextTarget.replace(
            capture: capture,
            with: proposed,
            requireSameFocus: config.replaceOnlyIfFocusUnchanged,
            mode: config.replaceModeValue,
            beforePaste: {
                guard config.restorePasteboard else { return }
                if restoreTo == nil || PasteboardBridge.changeCount != capture.pasteboardCount {
                    restoreTo = PasteboardBridge.snapshot()
                }
            })

        switch outcome {
        case .replaced:
            // Whether the pasteboard was borrowed is a fact, not something to infer from the
            // configured mode: an Accessibility write that was refused falls back to a paste, and
            // a paste that happened needs the delay whatever asked for it.
            if let restoreTo, restoreTo.changeCount != PasteboardBridge.changeCount {
                // The paste needs the pasteboard to stay put for a moment: some hosts read it
                // asynchronously after Cmd+V returns.
                schedulePasteboardRestore(restoreTo, afterMs: config.pasteboardRestoreDelayMs)
                if !restoreTo.complete {
                    notify(
                        "Clipboard partly restored",
                        "Some clipboard content could not be copied back.",
                        isError: false)
                }
            }

        case .focusChanged, .unconfirmed:
            // Never write into a window the user switched to, or on top of a write that may still
            // land. Hand them the text instead - flagged transient, because a rewrite they never
            // asked to keep has no business being archived by a clipboard manager.
            let replacing = capture.saved.map { !$0.isEmpty } ?? PasteboardBridge.hasContent
            PasteboardBridge.setText(proposed, transient: true)
            let reason = outcome == .unconfirmed
                ? "The app did not confirm the change."
                : "Focus or the text changed while TextFix worked."
            notify(
                "Text not replaced",
                replacing
                    ? "\(reason) The fixed text is on your clipboard, replacing what was there."
                    : "\(reason) The fixed text is on your clipboard.",
                isError: false)

        case .blocked:
            restorePasteboardNow(restoreTo)
            Permissions.promptForAccessibility()

        case .failed:
            restorePasteboardNow(restoreTo)
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

    /// Puts the pasteboard back after a capture that ended without a paste - unless something new
    /// landed on it while the request was out. That is most likely the user copying something,
    /// and it is now what they are holding; the older snapshot would overwrite it.
    private func restoreAfterCapture(_ capture: TextCapture?) {
        guard let capture, let saved = capture.saved else { return }
        guard PasteboardBridge.changeCount == capture.pasteboardCount else {
            Log.debug("The pasteboard changed during the request; left as it is")
            return
        }
        PasteboardBridge.restoreOrClear(saved)
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
        // A request still in flight is cancelled through the usual path, which puts back the
        // pasteboard its capture borrowed.
        cancel()
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
