// SPDX-License-Identifier: GPL-3.0-only
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace TextFix.Ai;

internal sealed record AiRequest(
    string ApiKey,
    string Model,
    string SystemPrompt,
    AiProvider Provider,
    bool UseZeroDataRetention,
    bool DisableReasoning,
    int TotalBudgetMs);

internal sealed record AiResult(string Text, bool FellBackFromZdr);

/// <summary>
/// One chat completion, with the policy that took a while to get right: three attempts with
/// backoff and an honoured Retry-After, zero-data-retention-first routing with a single downgrade,
/// reasoning suppression with a per-model fallback for routes that refuse it, and a prompt-cache
/// breakpoint on the system message. Nothing about the user is sent beyond the text they asked to
/// have fixed.
///
/// Ported from the OpenRouterClient in the WisprBoard Android keyboard (GPL-3.0-only), which is
/// where this project's licence comes from.
/// </summary>
internal static class AiClient
{
    private const int MaxAttempts = 3;
    private const int ConnectTimeoutMs = 8_000;
    private const int ReadTimeoutMs = 90_000;
    private const int MinBudgetedReadTimeoutMs = 1_000;
    private const long MaxRetryAfterMs = 30_000;
    private const int MaxResponseBytes = 1_000_000;
    private const int MaxErrorBytes = 64 * 1024;

    private const string AppReferer = "https://github.com/Turtlecute33/TextFix";
    private const string AppTitle = "TextFix";
    private const string AppCategories = "writing-assistant";

    private const long PrewarmMinGapMs = 90_000;
    private const int PrewarmTimeoutMs = 5_000;

    private static readonly HttpClient Http = CreateClient();
    private static long _lastContactTicks;
    private static int _prewarmInFlight;

    private static HttpClient CreateClient()
    {
        var handler = new SocketsHttpHandler
        {
            // A TCP+TLS handshake that has not completed in 8 s on a working network will not
            // complete; waiting longer only makes a captive portal cost the user more dead time.
            ConnectTimeout = TimeSpan.FromMilliseconds(ConnectTimeoutMs),
            // Long enough that a second fix a few minutes later still reuses the warm socket.
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(5),
            PooledConnectionLifetime = TimeSpan.FromMinutes(30),
            AutomaticDecompression = DecompressionMethods.All,
            MaxConnectionsPerServer = 4,
            AllowAutoRedirect = false,
        };
        return new HttpClient(handler)
        {
            // Per-attempt deadlines are enforced with linked tokens instead, so that a retry
            // budget can shorten later attempts without shortening the first one.
            Timeout = Timeout.InfiniteTimeSpan,
            DefaultRequestVersion = HttpVersion.Version20,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrLower,
        };
    }

    /// <summary>
    /// Opens a pooled TCP+TLS connection to the provider ahead of the real request, so the
    /// handshake overlaps with the user's own think time instead of being charged to the wait.
    /// Worth 30-200 ms on OpenRouter and 300-500 ms on PayPerQ. Sends no Authorization header and
    /// no payload: nothing that identifies the user leaves the machine, only a handshake to a host
    /// they have already chosen to use.
    /// </summary>
    internal static void Prewarm(AiProvider provider)
    {
        if (Environment.TickCount64 - Volatile.Read(ref _lastContactTicks) < PrewarmMinGapMs) return;
        if (Interlocked.CompareExchange(ref _prewarmInFlight, 1, 0) != 0) return;
        _ = Task.Run(async () =>
        {
            try
            {
                using var cts = new CancellationTokenSource(PrewarmTimeoutMs);
                using var request = new HttpRequestMessage(HttpMethod.Get, provider.PrewarmEndpoint());
                using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseContentRead, cts.Token)
                    .ConfigureAwait(false);
                // Draining the body is what returns the socket to the pool; without it the whole
                // exercise is a no-op. Unauthenticated, so a 401 body is the expected answer.
                _ = await response.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
                Volatile.Write(ref _lastContactTicks, Environment.TickCount64);
            }
            catch
            {
                // Speculative by definition. Never surfaced, and never logged with the URL.
            }
            finally
            {
                Volatile.Write(ref _prewarmInFlight, 0);
            }
        });
    }

    internal static async Task<AiResult> FixTextAsync(string userText, AiRequest req, CancellationToken ct)
    {
        // Stamped once, not per attempt: the ZDR downgrade below enters the retry loop a second
        // time and must not be handed a fresh full budget.
        long deadline = Environment.TickCount64 + req.TotalBudgetMs;

        bool suppressReasoning = req.DisableReasoning && RouteFacts.IsReasoningControlKnownRejected(req.Model);
        bool zdrWanted = req.Provider == AiProvider.OpenRouter && req.UseZeroDataRetention;
        // A model whose ZDR route we already found missing would otherwise pay for a doomed
        // attempt on every single fix just to rediscover it.
        bool zdrSuppressed = zdrWanted && RouteFacts.IsZdrKnownUnavailable(req.Model);
        // Report the downgrade even when it comes from the cache rather than a live refusal, so
        // the user is told on every affected request and not only the first one in 30 minutes.
        bool fellBack = zdrSuppressed;
        bool requestZdr = zdrWanted && !zdrSuppressed;

        string text;
        try
        {
            text = await AttemptWithReasoningFallback(requestZdr).ConfigureAwait(false);
        }
        catch (AiException e) when (requestZdr && RouteFacts.IsZdrRouteUnavailable(e.StatusCode, e.ErrorBody))
        {
            // ZDR is a preference, not a hard requirement. Retry once through normal routing so
            // unsupported, custom or temporarily unavailable ZDR routes do not break the feature.
            if (RouteFacts.IsZdrVerdictCacheable(e.StatusCode, e.ErrorBody)) RouteFacts.MarkZdrUnavailable(req.Model);
            fellBack = true;
            text = await AttemptWithReasoningFallback(false).ConfigureAwait(false);
        }
        return new AiResult(text, fellBack);

        // A handful of routes reject reasoning:{enabled:false} outright rather than ignoring it.
        // That answer is a non-retryable 400, so this costs at most one attempt, and the verdict
        // is remembered per model so the next request does not relearn it.
        async Task<string> AttemptWithReasoningFallback(bool zdr)
        {
            try
            {
                return await WithRetries(zdr).ConfigureAwait(false);
            }
            catch (AiException e) when (ChatTuningApplies() && RouteFacts.IsReasoningControlRejected(e.StatusCode, e.ErrorBody))
            {
                suppressReasoning = true;
                RouteFacts.MarkReasoningControlRejected(req.Model);
                return await WithRetries(zdr).ConfigureAwait(false);
            }
        }

        bool ChatTuningApplies() =>
            req.Provider == AiProvider.OpenRouter && req.DisableReasoning && !suppressReasoning;

        async Task<string> WithRetries(bool zdr)
        {
            AiException? lastError = null;
            long delayOverrideMs = -1;
            bool skipBackoff = false;

            for (int attempt = 0; attempt < MaxAttempts; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    return await PerformAsync(userText, req, zdr, ChatTuningApplies(), deadline, ct).ConfigureAwait(false);
                }
                catch (AiException e)
                {
                    if (zdr && req.Provider == AiProvider.OpenRouter && RouteFacts.IsZdrRouteUnavailable(e.StatusCode, e.ErrorBody))
                    {
                        throw new AiException(
                            "No zero data retention route is available for this model",
                            e.StatusCode, e.RetryAfterMs, e.ErrorBody);
                    }
                    if (!AiStatus.IsRetryable(e.StatusCode) || attempt == MaxAttempts - 1) throw;
                    lastError = e;
                    delayOverrideMs = e.StatusCode is 429 or 503 && e.RetryAfterMs > 0 ? e.RetryAfterMs : -1;
                    // A 200 with an unusable body is an upstream hiccup, not congestion. Backing
                    // off before repeating it is dead time the user spends watching a spinner.
                    skipBackoff = e.StatusCode == AiStatus.UnusableResponse;
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    // Our own per-attempt read deadline. Text bodies are cheap to resend, so
                    // unlike the audio path this is worth one more try inside the budget.
                    if (attempt == MaxAttempts - 1) throw new AiException("Request timed out");
                    lastError = new AiException("Request timed out");
                    delayOverrideMs = -1;
                }
                catch (HttpRequestException e)
                {
                    // Connect phase: the route is black-holed or behind a captive portal. Two more
                    // 8 s handshakes will not find a path, they just make the user wait 24 s for
                    // the same error.
                    if (IsConnectTimeout(e)) throw new AiException("Could not reach the provider");
                    // Never propagate the underlying exception text: on some stacks it carries the
                    // full request URL and headers, Authorization included.
                    if (attempt == MaxAttempts - 1) throw new AiException("Network error");
                    lastError = new AiException("Network error");
                    delayOverrideMs = -1;
                }

                long delayMs = skipBackoff ? 0
                    : delayOverrideMs > 0 ? delayOverrideMs
                    : Math.Min(500L << attempt, 4_000L);
                skipBackoff = false;
                // Sleeping past the budget would burn the remaining wait doing nothing, and a
                // Retry-After longer than the budget can never be honoured anyway.
                if (Environment.TickCount64 + delayMs >= deadline) throw lastError ?? new AiException("Request timed out");
                if (delayMs > 0) await Task.Delay((int)delayMs, ct).ConfigureAwait(false);
            }
            throw lastError ?? new AiException("Request failed");
        }
    }

    private static async Task<string> PerformAsync(
        string userText, AiRequest req, bool enforceZdr, bool disableReasoning, long deadline, CancellationToken ct)
    {
        byte[] body = BuildRequestBody(userText, req, enforceZdr, disableReasoning);

        using var message = new HttpRequestMessage(HttpMethod.Post, req.Provider.ChatEndpoint());
        message.Headers.TryAddWithoutValidation("Authorization", "Bearer " + req.ApiKey);
        if (req.Provider == AiProvider.OpenRouter)
        {
            message.Headers.TryAddWithoutValidation("HTTP-Referer", AppReferer);
            message.Headers.TryAddWithoutValidation("X-OpenRouter-Title", AppTitle);
            message.Headers.TryAddWithoutValidation("X-OpenRouter-Categories", AppCategories);
        }
        message.Content = new ByteArrayContent(body);
        message.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");

        using var attemptCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        attemptCts.CancelAfter(EffectiveReadTimeoutMs(deadline));

        try
        {
            using var response = await Http
                .SendAsync(message, HttpCompletionOption.ResponseHeadersRead, attemptCts.Token)
                .ConfigureAwait(false);

            if (!response.IsSuccessStatusCode)
            {
                string errorBody = await ReadCappedAsync(response, MaxErrorBytes, attemptCts.Token).ConfigureAwait(false);
                int status = (int)response.StatusCode;
                throw new AiException("API error: " + status, status, ParseRetryAfterMs(response.Headers), errorBody);
            }

            string payload = await ReadCappedAsync(response, MaxResponseBytes, attemptCts.Token).ConfigureAwait(false);
            return ParseContent(payload);
        }
        finally
        {
            Volatile.Write(ref _lastContactTicks, Environment.TickCount64);
        }
    }

    /// <summary>Remaining read budget, or the configured timeout when the budget is not binding.</summary>
    private static int EffectiveReadTimeoutMs(long deadline)
    {
        long remaining = deadline - Environment.TickCount64;
        if (remaining >= ReadTimeoutMs) return ReadTimeoutMs;
        return (int)Math.Max(remaining, MinBudgetedReadTimeoutMs);
    }

    private static byte[] BuildRequestBody(string userText, AiRequest req, bool enforceZdr, bool disableReasoning)
    {
        // A prompt carrying a {text} placeholder describes the whole request, so the captured text
        // is substituted into it and sent as a single user message. That is the only way a prompt
        // can say where the input sits and how it is fenced off, and fencing it is what stops
        // dictation containing something instruction-shaped from being obeyed. A prompt without a
        // placeholder keeps the other shape: a stable system message, cache breakpoint attached,
        // plus the text as its own message.
        //
        // The nonce is fresh per request, so a prompt fencing its input as <text-{nonce}> gets a
        // delimiter the captured text cannot close early.
        string? inlined = AiText.Substitute(req.SystemPrompt, userText, AiText.NewNonce());

        var buffer = new System.Buffers.ArrayBufferWriter<byte>(userText.Length + req.SystemPrompt.Length + 512);
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("model", req.Model);

            writer.WriteStartArray("messages");
            if (inlined == null)
            {
                WriteSystemMessage(writer, req.SystemPrompt);
                WriteTextMessage(writer, "user", userText);
            }
            else
            {
                WriteTextMessage(writer, "user", inlined);
            }
            writer.WriteEndArray();

            if (enforceZdr && req.Provider == AiProvider.OpenRouter)
            {
                // Best-effort preference: every enabled OpenRouter request asks for it first, and
                // the caller retries without it when routing cannot satisfy the constraint.
                writer.WriteStartObject("provider");
                writer.WriteBoolean("zdr", true);
                writer.WriteEndObject();
            }

            if (disableReasoning)
            {
                // temperature is deliberately absent: the shipped default text model answers a
                // non-default temperature with a non-retryable 400.
                writer.WriteStartObject("reasoning");
                writer.WriteBoolean("enabled", false);
                writer.WriteEndObject();
            }

            writer.WriteEndObject();
        }
        return buffer.WrittenSpan.ToArray();
    }

    private static void WriteSystemMessage(Utf8JsonWriter writer, string prompt)
    {
        writer.WriteStartObject();
        writer.WriteString("role", "system");
        writer.WriteStartArray("content");
        writer.WriteStartObject();
        writer.WriteString("type", "text");
        writer.WriteString("text", prompt);
        // Prompt-cache breakpoint on the (stable) system prompt. Providers that need an explicit
        // breakpoint get one; providers that cache implicitly ignore it harmlessly.
        writer.WriteStartObject("cache_control");
        writer.WriteString("type", "ephemeral");
        writer.WriteEndObject();
        writer.WriteEndObject();
        writer.WriteEndArray();
        writer.WriteEndObject();
    }

    private static void WriteTextMessage(Utf8JsonWriter writer, string role, string text)
    {
        writer.WriteStartObject();
        writer.WriteString("role", role);
        writer.WriteStartArray("content");
        writer.WriteStartObject();
        writer.WriteString("type", "text");
        writer.WriteString("text", text);
        writer.WriteEndObject();
        writer.WriteEndArray();
        writer.WriteEndObject();
    }

    internal static string ParseContent(string responseBody)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(responseBody);
        }
        catch (JsonException)
        {
            throw Unusable("Malformed API response");
        }

        using (document)
        {
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw Unusable("Malformed API response");
            if (!root.TryGetProperty("choices", out JsonElement choices)
                || choices.ValueKind != JsonValueKind.Array
                || choices.GetArrayLength() == 0)
            {
                // PayPerQ serves {"error": ...} with a 200 when its upstream fails, so an absent
                // choices array is an upstream fault rather than a malformed reply. Either way it
                // is the same transient, retryable condition.
                throw Unusable("API response missing choices");
            }

            string content = ExtractMessageText(choices[0]);
            if (content.Length == 0)
            {
                // Reasoning models sometimes answer with content:null and everything they produced
                // in `reasoning` instead; repeating the request clears it. We deliberately do not
                // read `reasoning` as a substitute - the same field carries the model's scratchpad
                // as often as the finished answer, and typing a scratchpad into the user's text
                // field is worse than one retry.
                throw Unusable("API response missing content");
            }
            return content;
        }
    }

    private static string ExtractMessageText(JsonElement choice)
    {
        if (choice.ValueKind != JsonValueKind.Object) return string.Empty;
        if (!choice.TryGetProperty("message", out JsonElement message) || message.ValueKind != JsonValueKind.Object)
        {
            return string.Empty;
        }

        if (message.TryGetProperty("content", out JsonElement content))
        {
            if (content.ValueKind == JsonValueKind.String)
            {
                return (content.GetString() ?? string.Empty).Trim();
            }
            if (content.ValueKind == JsonValueKind.Array)
            {
                var parts = new List<string>();
                foreach (JsonElement item in content.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object) continue;
                    if (item.TryGetProperty("text", out JsonElement text) && text.ValueKind == JsonValueKind.String)
                    {
                        string value = (text.GetString() ?? string.Empty).Trim();
                        if (value.Length > 0) parts.Add(value);
                    }
                }
                return string.Join("\n", parts).Trim();
            }
            // content:null arrives as JsonValueKind.Null and must not stringify to "null" - a
            // reply that would read as success and type the word "null" into the user's field.
        }
        return string.Empty;
    }

    private static AiException Unusable(string message) => new(message, AiStatus.UnusableResponse);

    private static async Task<string> ReadCappedAsync(HttpResponseMessage response, int maxBytes, CancellationToken ct)
    {
        try
        {
            await using Stream stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            byte[] buffer = new byte[Math.Min(maxBytes, 64 * 1024)];
            using var accumulated = new MemoryStream();
            int read;
            while ((read = await stream.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
            {
                int room = maxBytes - (int)accumulated.Length;
                if (room <= 0) break;
                accumulated.Write(buffer, 0, Math.Min(read, room));
            }
            return System.Text.Encoding.UTF8.GetString(accumulated.GetBuffer(), 0, (int)accumulated.Length);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            return string.Empty;
        }
    }

    internal static long ParseRetryAfterMs(HttpResponseHeaders headers)
    {
        if (!headers.TryGetValues("Retry-After", out IEnumerable<string>? values)) return -1;
        string? raw = null;
        foreach (string value in values)
        {
            raw = value;
            break;
        }
        if (string.IsNullOrWhiteSpace(raw)) return -1;
        raw = raw.Trim();

        if (long.TryParse(raw, out long seconds))
        {
            if (seconds < 0) return -1;
            return Math.Min(seconds * 1000, MaxRetryAfterMs);
        }
        if (DateTimeOffset.TryParse(raw, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AdjustToUniversal, out DateTimeOffset when))
        {
            long ms = (long)(when - DateTimeOffset.UtcNow).TotalMilliseconds;
            if (ms <= 0) return -1;
            return Math.Min(ms, MaxRetryAfterMs);
        }
        return -1;
    }

    private static bool IsConnectTimeout(HttpRequestException e)
    {
        for (Exception? inner = e.InnerException; inner != null; inner = inner.InnerException)
        {
            if (inner is TimeoutException) return true;
        }
        return false;
    }

    /// <summary>
    /// A one-line warning shown once per model when zero data retention could not be enforced, so
    /// a silent downgrade never happens behind the user's back.
    /// </summary>
    private static readonly HashSet<string> ZdrWarned = [];

    internal static bool ShouldWarnAboutZdrFallback(string model)
    {
        lock (ZdrWarned)
        {
            return ZdrWarned.Add(model);
        }
    }
}
