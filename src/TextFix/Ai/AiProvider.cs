// SPDX-License-Identifier: GPL-3.0-only
namespace TextFix.Ai;

/// <summary>
/// The two bring-your-own-key providers this talks to. Both speak an OpenAI-shaped chat API; what
/// differs is the endpoint, the model namespace, and how each one treats zero data retention.
/// </summary>
internal enum AiProvider
{
    OpenRouter,
    PayPerQ,
}

internal static class AiProviderExtensions
{
    internal const string OpenRouterPrefValue = "openrouter";
    internal const string PayPerQPrefValue = "payperq";

    internal static AiProvider FromPref(string? value) => value switch
    {
        PayPerQPrefValue => AiProvider.PayPerQ,
        _ => AiProvider.OpenRouter,
    };

    internal static string ToPref(this AiProvider provider) => provider switch
    {
        AiProvider.PayPerQ => PayPerQPrefValue,
        _ => OpenRouterPrefValue,
    };

    internal static string DisplayName(this AiProvider provider) => provider switch
    {
        AiProvider.PayPerQ => "PayPerQ",
        _ => "OpenRouter",
    };

    internal static string ChatEndpoint(this AiProvider provider) => provider switch
    {
        AiProvider.PayPerQ => Endpoints.PayPerQChat,
        _ => Endpoints.OpenRouterChat,
    };

    /// <summary>
    /// The URL used to open a pooled TLS connection ahead of a real request. Unauthenticated on
    /// purpose: a pre-warm must never carry anything that identifies the user.
    /// </summary>
    internal static string PrewarmEndpoint(this AiProvider provider) => provider switch
    {
        AiProvider.PayPerQ => Endpoints.PayPerQModels,
        _ => Endpoints.OpenRouterKey,
    };
}

internal static class Endpoints
{
    internal const string OpenRouterApiBase = "https://openrouter.ai/api/v1";
    internal const string OpenRouterChat = OpenRouterApiBase + "/chat/completions";
    internal const string OpenRouterKey = OpenRouterApiBase + "/key";
    internal const string PayPerQApiBase = "https://api.ppq.ai";
    internal const string PayPerQChat = PayPerQApiBase + "/chat/completions";
    internal const string PayPerQModels = PayPerQApiBase + "/v1/models";
}

internal enum PricingTier
{
    Free,
    Cheap,
    Medium,
    Expensive,
}

internal sealed record ModelEntry(string Slug, string DisplayName, PricingTier Tier, bool Zdr = false, bool Cache = false);

/// <summary>
/// The models offered in the picker, ordered fastest-first from timings measured against the live
/// APIs with reasoning suppressed. The zero-data-retention flags were reconciled against
/// OpenRouter's own /api/v1/endpoints/zdr list rather than left as hand-maintained guesses.
/// </summary>
internal static class ModelCatalog
{
    internal const string CustomSlug = "custom";

    internal static readonly ModelEntry[] OpenRouterTextFix =
    [
        new("~openai/gpt-mini-latest", "GPT Mini", PricingTier.Medium, Zdr: true, Cache: true),
        new("~anthropic/claude-haiku-latest", "Claude Haiku", PricingTier.Medium, Zdr: true, Cache: true),
        new("deepseek/deepseek-v4-flash", "DeepSeek V4 Flash", PricingTier.Cheap, Zdr: true, Cache: true),
        new("x-ai/grok-4.3", "Grok 4.3", PricingTier.Medium, Zdr: true, Cache: true),
        new("~google/gemini-flash-latest", "Gemini Flash", PricingTier.Cheap, Zdr: true, Cache: true),
    ];

    internal static readonly ModelEntry[] PayPerQTextFix =
    [
        new("~openai/gpt-mini-latest", "GPT Mini", PricingTier.Medium),
        new("x-ai/grok-4.3", "Grok 4.3", PricingTier.Medium),
        new("~anthropic/claude-haiku-latest", "Claude Haiku", PricingTier.Medium),
        new("~google/gemini-flash-latest", "Gemini Flash", PricingTier.Cheap),
        new("deepseek/deepseek-v4-flash", "DeepSeek V4 Flash", PricingTier.Cheap, Zdr: true, Cache: true),
    ];

    internal static ModelEntry[] For(AiProvider provider) =>
        provider == AiProvider.PayPerQ ? PayPerQTextFix : OpenRouterTextFix;

    internal static bool Supports(AiProvider provider, string slug) =>
        slug == CustomSlug || Array.Exists(For(provider), e => e.Slug == slug);

    /// <summary>
    /// Resolves the slug actually sent to the provider. "custom" defers to the user's own slug,
    /// and a blank custom slug resolves to nothing at all rather than to a silent fallback the
    /// user never chose.
    /// </summary>
    internal static string? Resolve(string selectedSlug, string customSlug)
    {
        if (selectedSlug != CustomSlug) return string.IsNullOrWhiteSpace(selectedSlug) ? null : selectedSlug;
        string trimmed = customSlug.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }

    // Accepts author/slug, author/slug:variant and ~author/model-latest; rejects whitespace and
    // bare names. Empty is allowed so the field can be cleared without a validation block.
    internal static bool IsValidCustomSlug(string raw)
    {
        string s = raw.Trim();
        if (s.Length == 0) return true;
        int slash = s.IndexOf('/');
        if (slash <= 0 || slash == s.Length - 1) return false;
        if (s.IndexOf('/', slash + 1) >= 0) return false;
        ReadOnlySpan<char> author = s.AsSpan(0, slash);
        ReadOnlySpan<char> model = s.AsSpan(slash + 1);
        if (author[0] == '~') author = author[1..];
        return IsSlugPart(author, allowColon: false) && IsSlugPart(model, allowColon: true);
    }

    private static bool IsSlugPart(ReadOnlySpan<char> part, bool allowColon)
    {
        if (part.Length == 0) return false;
        if (!char.IsAsciiLetterOrDigit(part[0]) || !char.IsAsciiLetterOrDigit(part[^1])) return false;
        foreach (char c in part)
        {
            bool ok = char.IsAsciiLetterOrDigit(c) || c == '.' || c == '_' || c == '-' || (allowColon && c == ':');
            if (!ok) return false;
        }
        return true;
    }
}
