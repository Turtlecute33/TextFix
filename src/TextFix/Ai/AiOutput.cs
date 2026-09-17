// SPDX-License-Identifier: GPL-3.0-only
using System.Collections.Concurrent;
using System.Globalization;

namespace TextFix.Ai;

internal sealed class AiException : Exception
{
    internal AiException(string message, int statusCode = -1, long retryAfterMs = -1, string errorBody = "")
        : base(message)
    {
        StatusCode = statusCode;
        RetryAfterMs = retryAfterMs;
        ErrorBody = errorBody;
    }

    internal int StatusCode { get; }
    internal long RetryAfterMs { get; }
    internal string ErrorBody { get; }
}

internal static class AiStatus
{
    /// <summary>
    /// "HTTP 200 with a body we cannot use" - unparseable JSON, an {"error": ...} envelope served
    /// with a 200 (PayPerQ does this when its upstream fails), no choices, or an assistant message
    /// whose content is empty because the model spent the whole completion on reasoning tokens.
    /// Retryable, and deliberately not a real HTTP status so nothing can collide with it.
    /// </summary>
    internal const int UnusableResponse = -2;

    private static readonly int[] Retryable = [408, 425, 429, 500, 502, 503, 504, UnusableResponse];

    internal static bool IsRetryable(int statusCode) => Array.IndexOf(Retryable, statusCode) >= 0;
}

internal static class AiText
{
    /// <summary>
    /// Strips control characters and the narrow set of bidi/format marks that corrupt host
    /// editors, but keeps U+200D (ZWJ) so emoji sequences survive and keeps newline / carriage
    /// return / tab so the model's line breaks survive - otherwise "end.\nNext" collapses to
    /// "end.Next", losing both the break and the space after the punctuation.
    /// </summary>
    internal static string Sanitize(string raw, int maxLength)
    {
        var sb = new System.Text.StringBuilder(raw.Length);
        foreach (char c in raw)
        {
            if (IsStripped(c)) continue;
            sb.Append(c);
        }
        string cleaned = sb.ToString().Trim();
        if (cleaned.Length <= maxLength) return cleaned;

        // Cut on a grapheme cluster boundary so we never split a surrogate pair, a ZWJ emoji
        // sequence or a base+combining-mark cluster. .NET's text-element segmenter keeps ZWJ
        // sequences whole, so no extra repair pass is needed here.
        int end = 0;
        while (end < cleaned.Length)
        {
            int len = StringInfo.GetNextTextElementLength(cleaned.AsSpan(end));
            if (len <= 0 || end + len > maxLength) break;
            end += len;
        }
        return cleaned[..end];
    }

    /// <summary>
    /// Recognised placeholders for the captured text inside a prompt. {text} is the documented
    /// one; the other spellings are accepted because they are what people naturally type.
    /// </summary>
    private static readonly string[] Placeholders = ["{text}", "{paste here}", "{paste}"];

    /// <summary>The token a prompt uses to ask for the per-request fence nonce.</summary>
    private const string NonceToken = "{nonce}";

    /// <summary>
    /// A value the captured text cannot contain, because it did not exist when the text was
    /// captured.
    ///
    /// A prompt that fences its input in a fixed tag is only fencing it by convention: text that
    /// happens to contain the closing tag - pasted HTML, a quoted example, or something written
    /// to do exactly this - closes the fence early and everything after it reads as prompt rather
    /// than as input. Naming the fence with a fresh nonce on every request makes the boundary
    /// something the input cannot forge.
    /// </summary>
    internal static string NewNonce() => Guid.NewGuid().ToString("N")[..8];

    /// <summary>
    /// Substitutes the captured text into a prompt that asks for it by placeholder, or returns
    /// null when the prompt has no placeholder. A prompt with one describes the entire request -
    /// including how the input is delimited - so the caller sends it as a single message instead
    /// of a system prompt plus a separate text message.
    ///
    /// The nonce is expanded into the prompt first and the text second, so a captured text that
    /// itself contains "{nonce}" is left alone rather than being handed the real value.
    /// </summary>
    internal static string? Substitute(string prompt, string text, string nonce)
    {
        foreach (string token in Placeholders)
        {
            if (prompt.Contains(token, StringComparison.OrdinalIgnoreCase))
            {
                string fenced = prompt.Replace(NonceToken, nonce, StringComparison.OrdinalIgnoreCase);
                return fenced.Replace(token, text, StringComparison.OrdinalIgnoreCase);
            }
        }
        return null;
    }

    /// <summary>
    /// Strips a wrapping tag pair that a model echoed back, which happens when the prompt uses
    /// tags to delimit the input. Only strips when a matching pair sits at both ends, so text that
    /// legitimately contains a tag survives untouched.
    /// </summary>
    internal static string Unwrap(string raw)
    {
        string text = raw.Trim();
        if (text.Length < 7 || text[0] != '<') return raw;
        int close = text.IndexOf('>');
        if (close < 2) return raw;

        // Digits and hyphens are allowed after the first letter so a nonce-named fence
        // (<text-a3f9c1b2>) is recognised the same way a plain <text> is.
        string name = text[1..close];
        if (!char.IsAsciiLetter(name[0])) return raw;
        foreach (char c in name)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c != '-') return raw;
        }
        string closingTag = "</" + name + ">";
        if (!text.EndsWith(closingTag, StringComparison.OrdinalIgnoreCase)) return raw;
        return text[(close + 1)..^closingTag.Length].Trim();
    }

    private static bool IsStripped(char c)
    {
        // Written as code points rather than escapes so the intent survives a copy-paste: 9 tab,
        // 10 line feed, 13 carriage return are the three controls the model is allowed to use.
        if (c is (char)9 or (char)10 or (char)13) return false;
        if (char.IsControl(c)) return true;
        return (int)c switch
        {
            0x200B => true,             // zero width space
            0x200C => true,             // zero width non-joiner (U+200D ZWJ is deliberately kept)
            0x200E => true,             // left-to-right mark
            0x200F => true,             // right-to-left mark
            >= 0x202A and <= 0x202E => true, // bidi embedding / override
            >= 0x2066 and <= 0x2069 => true, // bidi isolates
            0xFEFF => true,             // byte order mark
            _ => false,
        };
    }
}

internal static class AiErrors
{
    /// <summary>
    /// Turns the handful of provider statuses that mean something specific into an instruction the
    /// user can act on. Deliberately narrow: 403 is not mapped, because on OpenRouter it means the
    /// request was refused by moderation rather than that the credentials are bad, and confidently
    /// sending the user to check their API key would be worse than an opaque number.
    /// </summary>
    internal static string? Actionable(int statusCode) => statusCode switch
    {
        401 => "API key refused. Check it in TextFix settings.",
        402 => "Your provider account is out of credit.",
        404 => "That model was not found on this provider.",
        _ => null,
    };

    internal static string UserFacing(Exception e, string fallback)
    {
        if (e is AiException ai)
        {
            if (ai.StatusCode is 429 or 503) return "Provider is rate limiting. Try again in a moment.";
            string? actionable = Actionable(ai.StatusCode);
            if (actionable != null) return actionable;
            string raw = ai.Message;
            if (!string.IsNullOrWhiteSpace(raw)) return Scrub(raw);
        }
        if (e is OperationCanceledException) return "Cancelled.";
        return fallback;
    }

    /// <summary>
    /// Removes anything key-shaped from a message before it can reach the screen or the log. The
    /// underlying exception text is never surfaced raw for exactly this reason.
    /// </summary>
    internal static string Scrub(string message)
    {
        string result = ReplaceAfter(message, "Bearer ", "Bearer ***");
        result = ReplaceAfter(result, "sk-or-v1-", "sk-or-v1-***");
        result = ReplaceAfter(result, "api_key", "api_key ***");
        result = ReplaceAfter(result, "api-key", "api-key ***");
        return result;
    }

    private static string ReplaceAfter(string haystack, string needle, string replacement)
    {
        int at = haystack.IndexOf(needle, StringComparison.OrdinalIgnoreCase);
        if (at < 0) return haystack;
        int end = at + needle.Length;
        while (end < haystack.Length && !char.IsWhiteSpace(haystack[end]) && haystack[end] is not (',' or '}' or '"'))
        {
            end++;
        }
        return string.Concat(haystack.AsSpan(0, at), replacement, haystack.AsSpan(end));
    }
}

/// <summary>
/// Routing facts learned the expensive way, remembered briefly so the next request does not repeat
/// a doomed attempt. Deliberately short-lived rather than process-lifetime: the agent runs for
/// days, and both conditions recover - a ZDR route that was momentarily down comes back, and a
/// floating ~author/model-latest alias can resolve to a different endpoint tomorrow. Caching
/// either verdict forever would silently and permanently downgrade the request.
/// </summary>
internal static class RouteFacts
{
    private const long TtlMs = 30 * 60 * 1000L;
    private static readonly ConcurrentDictionary<string, long> ZdrUnavailableSince = new();
    private static readonly ConcurrentDictionary<string, long> ReasoningRejectedSince = new();

    internal static void MarkZdrUnavailable(string model) => ZdrUnavailableSince[model] = Environment.TickCount64;

    internal static bool IsZdrKnownUnavailable(string model) => IsFresh(ZdrUnavailableSince, model);

    internal static void MarkReasoningControlRejected(string model) => ReasoningRejectedSince[model] = Environment.TickCount64;

    internal static bool IsReasoningControlKnownRejected(string model) => IsFresh(ReasoningRejectedSince, model);

    private static bool IsFresh(ConcurrentDictionary<string, long> map, string model)
    {
        if (!map.TryGetValue(model, out long since)) return false;
        if (Environment.TickCount64 - since < TtlMs) return true;
        map.TryRemove(model, out _);
        return false;
    }

    /// <summary>
    /// True when the provider refused the request *because* we asked it not to reason. A few
    /// routes treat reasoning as mandatory and answer 400 instead of ignoring the field. Narrow on
    /// purpose: a generic 400 must not be read as a reasoning complaint, or a malformed request
    /// would be retried untuned forever and the real error hidden.
    /// </summary>
    internal static bool IsReasoningControlRejected(int statusCode, string errorBody)
    {
        if (statusCode is not (400 or 422)) return false;
        string body = errorBody.ToLowerInvariant();
        if (!body.Contains("reasoning") && !body.Contains("thinking")) return false;
        return body.Contains("cannot be disabled")
            || body.Contains("can't be disabled")
            || body.Contains("must be enabled")
            || body.Contains("is mandatory")
            || body.Contains("does not support")
            || body.Contains("not supported")
            || body.Contains("unsupported");
    }

    internal static bool IsZdrRouteUnavailable(int statusCode, string errorBody)
    {
        if (statusCode is not (400 or 404 or 409 or 422)) return false;
        string body = errorBody.ToLowerInvariant();
        return body.Contains("zdr")
            || body.Contains("zero data")
            || body.Contains("data retention")
            || body.Contains("no endpoint");
    }

    /// <summary>
    /// Whether a ZDR refusal is specific enough to *remember*. IsZdrRouteUnavailable deliberately
    /// also matches a bare "no endpoint", because that is what OpenRouter answers when a model has
    /// no route satisfying the constraint - but it is equally what it answers when a provider is
    /// momentarily down. Caching the latter for half an hour would silently take a user off
    /// zero data retention because of a transient outage, so only a body that actually mentions
    /// retention may set the cache. The fallback for this request happens either way; only the
    /// memory of it is gated.
    /// </summary>
    internal static bool IsZdrVerdictCacheable(int statusCode, string errorBody)
    {
        if (!IsZdrRouteUnavailable(statusCode, errorBody)) return false;
        string body = errorBody.ToLowerInvariant();
        return body.Contains("zdr")
            || body.Contains("zero data")
            || body.Contains("data retention")
            || body.Contains("data policy");
    }
}
