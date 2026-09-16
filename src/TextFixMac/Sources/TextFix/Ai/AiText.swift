// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct AiError: Error {
    let message: String
    var statusCode: Int = -1
    var retryAfterMs: Int = -1
    var errorBody: String = ""
}

enum AiStatus {
    /// "HTTP 200 with a body we cannot use" - unparseable JSON, an {"error": ...} envelope served
    /// with a 200 (PayPerQ does this when its upstream fails), no choices, or an assistant message
    /// whose content is empty because the model spent the whole completion on reasoning tokens.
    /// Retryable, and deliberately not a real HTTP status so nothing can collide with it.
    static let unusableResponse = -2

    private static let retryable: Set<Int> = [408, 425, 429, 500, 502, 503, 504, unusableResponse]

    static func isRetryable(_ statusCode: Int) -> Bool { retryable.contains(statusCode) }
}

enum AiText {
    /// Strips control characters and the narrow set of bidi/format marks that corrupt host
    /// editors, but keeps U+200D (ZWJ) so emoji sequences survive and keeps newline / carriage
    /// return / tab so the model's line breaks survive - otherwise "end.\nNext" collapses to
    /// "end.Next", losing both the break and the space after the punctuation.
    static func sanitize(_ raw: String, maxLength: Int) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars where !isStripped(scalar) {
            out.append(scalar)
        }
        let cleaned = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        // Swift counts Characters as grapheme clusters, so truncating here can never split a
        // surrogate pair, a ZWJ emoji sequence or a base plus combining mark.
        if cleaned.count <= maxLength { return cleaned }
        return String(cleaned.prefix(maxLength))
    }

    /// Recognised placeholders for the captured text inside a prompt. {text} is the documented
    /// one; the other spellings are accepted because they are what people naturally type.
    private static let placeholders = ["{text}", "{paste here}", "{paste}"]

    /// Substitutes the captured text into a prompt that asks for it by placeholder, or returns nil
    /// when the prompt has no placeholder. A prompt with one describes the entire request -
    /// including how the input is delimited - so the caller sends it as a single message instead
    /// of a system prompt plus a separate text message.
    static func substitute(_ prompt: String, _ text: String) -> String? {
        for token in placeholders where prompt.range(of: token, options: .caseInsensitive) != nil {
            return prompt.replacingOccurrences(of: token, with: text, options: .caseInsensitive)
        }
        return nil
    }

    /// Strips a wrapping tag pair that a model echoed back, which happens when the prompt uses
    /// tags to delimit the input. Only strips when a matching pair sits at both ends, so text that
    /// legitimately contains a tag survives untouched.
    static func unwrap(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 7, text.first == "<" else { return raw }
        guard let close = text.firstIndex(of: ">") else { return raw }
        let name = text[text.index(after: text.startIndex)..<close]
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isLetter }) else { return raw }
        let closingTag = "</\(name)>"
        guard text.lowercased().hasSuffix(closingTag.lowercased()) else { return raw }
        let body = text[text.index(after: close)..<text.index(text.endIndex, offsetBy: -closingTag.count)]
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        // Written as code points rather than escapes so the intent survives a copy-paste: 9 tab,
        // 10 line feed, 13 carriage return are the three controls the model is allowed to use.
        switch scalar.value {
        case 9, 10, 13: return false
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x200B, 0x200C: return true   // zero width space / non-joiner (U+200D ZWJ is kept)
        case 0x200E, 0x200F: return true   // left-to-right / right-to-left mark
        case 0x202A...0x202E: return true  // bidi embedding / override
        case 0x2066...0x2069: return true  // bidi isolates
        case 0xFEFF: return true           // byte order mark
        default: return false
        }
    }
}

enum AiErrors {
    /// Turns the handful of provider statuses that mean something specific into an instruction the
    /// user can act on. Deliberately narrow: 403 is not mapped, because on OpenRouter it means the
    /// request was refused by moderation rather than that the credentials are bad, and confidently
    /// sending the user to check their API key would be worse than an opaque number.
    static func actionable(_ statusCode: Int) -> String? {
        switch statusCode {
        case 401: return "API key refused. Check it in TextFix settings."
        case 402: return "Your provider account is out of credit."
        case 404: return "That model was not found on this provider."
        default: return nil
        }
    }

    static func userFacing(_ error: Error, fallback: String) -> String {
        if error is CancellationError { return "Cancelled." }
        if let ai = error as? AiError {
            if ai.statusCode == 429 || ai.statusCode == 503 {
                return "Provider is rate limiting. Try again in a moment."
            }
            if let actionable = actionable(ai.statusCode) { return actionable }
            if !ai.message.trimmingCharacters(in: .whitespaces).isEmpty { return scrub(ai.message) }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No connection."
            case .timedOut: return "Request timed out."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Could not reach the provider."
            case .cancelled: return "Cancelled."
            default: break
            }
        }
        return fallback
    }

    /// Removes anything key-shaped from a message before it can reach the screen or the log. The
    /// underlying error text is never surfaced raw for exactly this reason.
    static func scrub(_ message: String) -> String {
        var result = replaceAfter(message, "Bearer ", "Bearer ***")
        result = replaceAfter(result, "sk-or-v1-", "sk-or-v1-***")
        result = replaceAfter(result, "api_key", "api_key ***")
        result = replaceAfter(result, "api-key", "api-key ***")
        return result
    }

    private static func replaceAfter(_ haystack: String, _ needle: String, _ replacement: String) -> String {
        guard let range = haystack.range(of: needle, options: .caseInsensitive) else { return haystack }
        var end = range.upperBound
        while end < haystack.endIndex {
            let c = haystack[end]
            if c.isWhitespace || c == "," || c == "}" || c == "\"" { break }
            end = haystack.index(after: end)
        }
        return String(haystack[haystack.startIndex..<range.lowerBound]) + replacement + String(haystack[end...])
    }
}

/// Routing facts learned the expensive way, remembered briefly so the next request does not repeat
/// a doomed attempt. Deliberately short-lived rather than process-lifetime: the agent runs for
/// days, and both conditions recover - a ZDR route that was momentarily down comes back, and a
/// floating ~author/model-latest alias can resolve to a different endpoint tomorrow. Caching
/// either verdict forever would silently and permanently downgrade the request.
final class RouteFacts {
    static let shared = RouteFacts()

    private let ttl: TimeInterval = 30 * 60
    private let lock = NSLock()
    private var zdrUnavailableSince: [String: Date] = [:]
    private var reasoningRejectedSince: [String: Date] = [:]

    func markZdrUnavailable(_ model: String) {
        lock.locked { zdrUnavailableSince[model] = Date() }
    }

    func isZdrKnownUnavailable(_ model: String) -> Bool {
        lock.locked {
            guard let since = zdrUnavailableSince[model] else { return false }
            if Date().timeIntervalSince(since) < ttl { return true }
            zdrUnavailableSince.removeValue(forKey: model)
            return false
        }
    }

    func markReasoningControlRejected(_ model: String) {
        lock.locked { reasoningRejectedSince[model] = Date() }
    }

    func isReasoningControlKnownRejected(_ model: String) -> Bool {
        lock.locked {
            guard let since = reasoningRejectedSince[model] else { return false }
            if Date().timeIntervalSince(since) < ttl { return true }
            reasoningRejectedSince.removeValue(forKey: model)
            return false
        }
    }

    /// True when the provider refused the request *because* we asked it not to reason. A few
    /// routes treat reasoning as mandatory and answer 400 instead of ignoring the field. Narrow on
    /// purpose: a generic 400 must not be read as a reasoning complaint, or a malformed request
    /// would be retried untuned forever and the real error hidden.
    static func isReasoningControlRejected(_ statusCode: Int, _ errorBody: String) -> Bool {
        guard statusCode == 400 || statusCode == 422 else { return false }
        let body = errorBody.lowercased()
        guard body.contains("reasoning") || body.contains("thinking") else { return false }
        return body.contains("cannot be disabled")
            || body.contains("can't be disabled")
            || body.contains("must be enabled")
            || body.contains("is mandatory")
            || body.contains("does not support")
            || body.contains("not supported")
            || body.contains("unsupported")
    }

    static func isZdrRouteUnavailable(_ statusCode: Int, _ errorBody: String) -> Bool {
        guard [400, 404, 409, 422].contains(statusCode) else { return false }
        let body = errorBody.lowercased()
        return body.contains("zdr")
            || body.contains("zero data")
            || body.contains("data retention")
            || body.contains("no endpoint")
    }

    /// Whether a ZDR refusal is specific enough to *remember*. isZdrRouteUnavailable deliberately
    /// also matches a bare "no endpoint", because that is what OpenRouter answers when a model has
    /// no route satisfying the constraint - but it is equally what it answers when a provider is
    /// momentarily down. Caching the latter for half an hour would silently take a user off zero
    /// data retention because of a transient outage, so only a body that actually mentions
    /// retention may set the cache. The fallback for this request happens either way; only the
    /// memory of it is gated.
    static func isZdrVerdictCacheable(_ statusCode: Int, _ errorBody: String) -> Bool {
        guard isZdrRouteUnavailable(statusCode, errorBody) else { return false }
        let body = errorBody.lowercased()
        return body.contains("zdr")
            || body.contains("zero data")
            || body.contains("data retention")
            || body.contains("data policy")
    }
}
