// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct AiRequest {
    let apiKey: String
    let model: String
    let systemPrompt: String
    let provider: AiProvider
    let useZeroDataRetention: Bool
    let disableReasoning: Bool
    let totalBudgetMs: Int
}

struct AiResult {
    let text: String
    let fellBackFromZdr: Bool
}

/// One chat completion, with the policy that took a while to get right: three attempts with
/// backoff and an honoured Retry-After, zero-data-retention-first routing with a single downgrade,
/// reasoning suppression with a per-model fallback for routes that refuse it, and a prompt-cache
/// breakpoint on the system message. Nothing about the user is sent beyond the text they asked to
/// have fixed.
///
/// A port of the Windows agent's AiClient, which is itself a port of the OpenRouterClient in the
/// WisprBoard Android keyboard (GPL-3.0-only), which is where this project's licence comes from.
enum AiClient {
    private static let maxAttempts = 3
    private static let readTimeout: TimeInterval = 90
    private static let minBudgetedReadTimeout: TimeInterval = 1
    private static let maxRetryAfterMs = 30_000
    private static let maxResponseBytes = 1_000_000
    private static let maxErrorBytes = 64 * 1024

    private static let appReferer = "https://github.com/Turtlecute33/TextFix"
    private static let appTitle = "TextFix"
    private static let appCategories = "writing-assistant"

    private static let prewarmMinGapMs = 90_000
    private static let prewarmTimeout: TimeInterval = 5

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Per-attempt deadlines are set on each request instead, so a retry budget can shorten
        // later attempts without shortening the first one.
        configuration.timeoutIntervalForRequest = readTimeout
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpShouldUsePipelining = false
        // A captive portal or a dead network must fail fast and say so, not park the user's fix in
        // a queue until the Wi-Fi comes back.
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// Small shared state: the last time we touched the provider (so a pre-warm does not fire on
    /// every hotkey press) and the set of models we have already warned about a ZDR downgrade for.
    private final class State {
        private let lock = NSLock()
        private var lastContact = Date.distantPast
        private var prewarmInFlight = false
        private var zdrWarned: Set<String> = []

        func beginPrewarmIfDue(gapMs: Int) -> Bool {
            lock.locked {
                if prewarmInFlight { return false }
                if Date().timeIntervalSince(lastContact) * 1000 < Double(gapMs) { return false }
                prewarmInFlight = true
                return true
            }
        }

        func endPrewarm() { lock.locked { prewarmInFlight = false } }

        func touch() { lock.locked { lastContact = Date() } }

        func shouldWarnAboutZdr(_ model: String) -> Bool {
            lock.locked { zdrWarned.insert(model).inserted }
        }
    }

    private static let state = State()

    static func shouldWarnAboutZdrFallback(_ model: String) -> Bool { state.shouldWarnAboutZdr(model) }

    /// Opens a pooled TCP+TLS connection to the provider ahead of the real request, so the
    /// handshake overlaps with the user's own think time instead of being charged to the wait.
    /// Worth 30-200 ms on OpenRouter and 300-500 ms on PayPerQ. Sends no Authorization header and
    /// no payload: nothing that identifies the user leaves the machine, only a handshake to a host
    /// they have already chosen to use.
    static func prewarm(_ provider: AiProvider) {
        guard state.beginPrewarmIfDue(gapMs: prewarmMinGapMs) else { return }
        Task.detached(priority: .utility) {
            defer { state.endPrewarm() }
            var request = URLRequest(url: provider.prewarmEndpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = prewarmTimeout
            // Reading the body is what returns the socket to the pool; without it the whole
            // exercise is a no-op. Unauthenticated, so a 401 body is the expected answer.
            if (try? await session.data(for: request)) != nil {
                state.touch()
            }
            // Speculative by definition. Never surfaced, and never logged with the URL.
        }
    }

    static func fixText(_ userText: String, _ req: AiRequest) async throws -> AiResult {
        // Stamped once, not per attempt: the ZDR downgrade below enters the retry loop a second
        // time and must not be handed a fresh full budget.
        let deadline = Date().addingTimeInterval(Double(req.totalBudgetMs) / 1000)

        var suppressReasoning = req.disableReasoning
            && RouteFacts.shared.isReasoningControlKnownRejected(req.model)
        let zdrWanted = req.provider == .openRouter && req.useZeroDataRetention
        // A model whose ZDR route we already found missing would otherwise pay for a doomed
        // attempt on every single fix just to rediscover it.
        let zdrSuppressed = zdrWanted && RouteFacts.shared.isZdrKnownUnavailable(req.model)
        // Report the downgrade even when it comes from the cache rather than a live refusal, so
        // the user is told on every affected request and not only the first one in 30 minutes.
        var fellBack = zdrSuppressed
        let requestZdr = zdrWanted && !zdrSuppressed

        func chatTuningApplies() -> Bool {
            req.provider == .openRouter && req.disableReasoning && !suppressReasoning
        }

        func withRetries(zdr: Bool) async throws -> String {
            var lastError: AiError?
            var delayOverrideMs = -1
            var skipBackoff = false

            for attempt in 0..<maxAttempts {
                try Task.checkCancellation()
                do {
                    return try await perform(
                        userText: userText, req: req, enforceZdr: zdr,
                        disableReasoning: chatTuningApplies(), deadline: deadline)
                } catch let error as AiError {
                    if zdr, req.provider == .openRouter,
                       RouteFacts.isZdrRouteUnavailable(error.statusCode, error.errorBody) {
                        throw AiError(
                            message: "No zero data retention route is available for this model",
                            statusCode: error.statusCode,
                            retryAfterMs: error.retryAfterMs,
                            errorBody: error.errorBody)
                    }
                    if !AiStatus.isRetryable(error.statusCode) || attempt == maxAttempts - 1 { throw error }
                    lastError = error
                    delayOverrideMs = (error.statusCode == 429 || error.statusCode == 503) && error.retryAfterMs > 0
                        ? error.retryAfterMs : -1
                    // A 200 with an unusable body is an upstream hiccup, not congestion. Backing
                    // off before repeating it is dead time the user spends watching a spinner.
                    skipBackoff = error.statusCode == AiStatus.unusableResponse
                } catch let error as URLError {
                    if error.code == .cancelled { throw CancellationError() }
                    // Connect phase: the route is black-holed or behind a captive portal. Two more
                    // handshakes will not find a path, they just make the user wait for the same
                    // error.
                    if isUnreachable(error) {
                        throw AiError(message: AiErrors.userFacing(error, fallback: "Could not reach the provider"))
                    }
                    // Never propagate the underlying error text: on some stacks it carries the
                    // full request URL and headers, Authorization included.
                    let wrapped = AiError(message: AiErrors.userFacing(error, fallback: "Network error"))
                    if attempt == maxAttempts - 1 { throw wrapped }
                    lastError = wrapped
                    delayOverrideMs = -1
                }

                var delayMs = skipBackoff ? 0
                    : delayOverrideMs > 0 ? delayOverrideMs
                    : min(500 << attempt, 4_000)
                skipBackoff = false
                // Sleeping past the budget would burn the remaining wait doing nothing, and a
                // Retry-After longer than the budget can never be honoured anyway.
                if Date().addingTimeInterval(Double(delayMs) / 1000) >= deadline {
                    throw lastError ?? AiError(message: "Request timed out")
                }
                if delayMs > 0 {
                    if delayMs > maxRetryAfterMs { delayMs = maxRetryAfterMs }
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
            }
            throw lastError ?? AiError(message: "Request failed")
        }

        // A handful of routes reject reasoning:{enabled:false} outright rather than ignoring it.
        // That answer is a non-retryable 400, so this costs at most one attempt, and the verdict
        // is remembered per model so the next request does not relearn it.
        func attemptWithReasoningFallback(zdr: Bool) async throws -> String {
            do {
                return try await withRetries(zdr: zdr)
            } catch let error as AiError
                where chatTuningApplies() && RouteFacts.isReasoningControlRejected(error.statusCode, error.errorBody) {
                suppressReasoning = true
                RouteFacts.shared.markReasoningControlRejected(req.model)
                return try await withRetries(zdr: zdr)
            }
        }

        let text: String
        do {
            text = try await attemptWithReasoningFallback(zdr: requestZdr)
        } catch let error as AiError
            where requestZdr && RouteFacts.isZdrRouteUnavailable(error.statusCode, error.errorBody) {
            // ZDR is a preference, not a hard requirement. Retry once through normal routing so
            // unsupported, custom or temporarily unavailable ZDR routes do not break the feature.
            if RouteFacts.isZdrVerdictCacheable(error.statusCode, error.errorBody) {
                RouteFacts.shared.markZdrUnavailable(req.model)
            }
            fellBack = true
            text = try await attemptWithReasoningFallback(zdr: false)
        }
        return AiResult(text: text, fellBackFromZdr: fellBack)
    }

    // ---- one attempt ----

    private static func perform(
        userText: String, req: AiRequest, enforceZdr: Bool, disableReasoning: Bool, deadline: Date
    ) async throws -> String {
        var request = URLRequest(url: req.provider.chatEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = effectiveReadTimeout(deadline)
        request.setValue("Bearer \(req.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if req.provider == .openRouter {
            request.setValue(appReferer, forHTTPHeaderField: "HTTP-Referer")
            request.setValue(appTitle, forHTTPHeaderField: "X-OpenRouter-Title")
            request.setValue(appCategories, forHTTPHeaderField: "X-OpenRouter-Categories")
        }
        request.httpBody = buildRequestBody(
            userText: userText, req: req, enforceZdr: enforceZdr, disableReasoning: disableReasoning)

        defer { state.touch() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AiError(message: "Malformed API response", statusCode: AiStatus.unusableResponse)
        }

        if !(200...299).contains(http.statusCode) {
            let body = String(decoding: data.prefix(maxErrorBytes), as: UTF8.self)
            throw AiError(
                message: "API error: \(http.statusCode)",
                statusCode: http.statusCode,
                retryAfterMs: parseRetryAfterMs(http),
                errorBody: body)
        }
        return try parseContent(String(decoding: data.prefix(maxResponseBytes), as: UTF8.self))
    }

    /// Remaining read budget, or the configured timeout when the budget is not binding.
    private static func effectiveReadTimeout(_ deadline: Date) -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        if remaining >= readTimeout { return readTimeout }
        return max(remaining, minBudgetedReadTimeout)
    }

    private static func buildRequestBody(
        userText: String, req: AiRequest, enforceZdr: Bool, disableReasoning: Bool
    ) -> Data? {
        // A prompt carrying a {text} placeholder describes the whole request, so the captured text
        // is substituted into it and sent as a single user message. That is the only way a prompt
        // can say where the input sits and how it is fenced off, and fencing it is what stops
        // dictation containing something instruction-shaped from being obeyed. A prompt without a
        // placeholder keeps the other shape: a stable system message, cache breakpoint attached,
        // plus the text as its own message.
        let inlined = AiText.substitute(req.systemPrompt, userText)

        var messages: [[String: Any]] = []
        if let inlined {
            messages.append(textMessage(role: "user", text: inlined))
        } else {
            messages.append(systemMessage(req.systemPrompt))
            messages.append(textMessage(role: "user", text: userText))
        }

        var body: [String: Any] = ["model": req.model, "messages": messages]
        if enforceZdr && req.provider == .openRouter {
            // Best-effort preference: every enabled OpenRouter request asks for it first, and the
            // caller retries without it when routing cannot satisfy the constraint.
            body["provider"] = ["zdr": true]
        }
        if disableReasoning {
            // temperature is deliberately absent: the shipped default text model answers a
            // non-default temperature with a non-retryable 400.
            body["reasoning"] = ["enabled": false]
        }
        return try? JSONSerialization.data(withJSONObject: body, options: [])
    }

    private static func systemMessage(_ prompt: String) -> [String: Any] {
        // Prompt-cache breakpoint on the (stable) system prompt. Providers that need an explicit
        // breakpoint get one; providers that cache implicitly ignore it harmlessly.
        [
            "role": "system",
            "content": [["type": "text", "text": prompt, "cache_control": ["type": "ephemeral"]]],
        ]
    }

    private static func textMessage(role: String, text: String) -> [String: Any] {
        ["role": role, "content": [["type": "text", "text": text]]]
    }

    // ---- response ----

    static func parseContent(_ responseBody: String) throws -> String {
        guard let data = responseBody.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw unusable("Malformed API response")
        }
        guard let choices = root["choices"] as? [Any], !choices.isEmpty else {
            // PayPerQ serves {"error": ...} with a 200 when its upstream fails, so an absent
            // choices array is an upstream fault rather than a malformed reply. Either way it is
            // the same transient, retryable condition.
            throw unusable("API response missing choices")
        }
        let content = extractMessageText(choices[0])
        if content.isEmpty {
            // Reasoning models sometimes answer with content:null and everything they produced in
            // `reasoning` instead; repeating the request clears it. We deliberately do not read
            // `reasoning` as a substitute - the same field carries the model's scratchpad as often
            // as the finished answer, and typing a scratchpad into the user's text field is worse
            // than one retry.
            throw unusable("API response missing content")
        }
        return content
    }

    private static func extractMessageText(_ choice: Any) -> String {
        guard let choice = choice as? [String: Any],
              let message = choice["message"] as? [String: Any] else { return "" }

        if let text = message["content"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parts = message["content"] as? [Any] {
            let texts = parts.compactMap { part -> String? in
                guard let part = part as? [String: Any], let text = part["text"] as? String else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // content:null arrives as NSNull and must not stringify to "null" - a reply that would
        // read as success and type the word "null" into the user's field.
        return ""
    }

    private static func unusable(_ message: String) -> AiError {
        AiError(message: message, statusCode: AiStatus.unusableResponse)
    }

    static func parseRetryAfterMs(_ response: HTTPURLResponse) -> Int {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return -1 }

        if let seconds = Int(raw) {
            if seconds < 0 { return -1 }
            return min(seconds * 1000, maxRetryAfterMs)
        }
        if let when = httpDateFormatter.date(from: raw) {
            let ms = Int(when.timeIntervalSinceNow * 1000)
            if ms <= 0 { return -1 }
            return min(ms, maxRetryAfterMs)
        }
        return -1
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static func isUnreachable(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
