// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The two bring-your-own-key providers this talks to. Both speak an OpenAI-shaped chat API; what
/// differs is the endpoint, the model namespace, and how each one treats zero data retention.
enum AiProvider: CaseIterable {
    case openRouter
    case payPerQ

    static let openRouterPref = "openrouter"
    static let payPerQPref = "payperq"

    static func fromPref(_ value: String?) -> AiProvider {
        value?.trimmingCharacters(in: .whitespaces).lowercased() == payPerQPref ? .payPerQ : .openRouter
    }

    var pref: String {
        switch self {
        case .payPerQ: return AiProvider.payPerQPref
        case .openRouter: return AiProvider.openRouterPref
        }
    }

    var displayName: String {
        switch self {
        case .payPerQ: return "PayPerQ"
        case .openRouter: return "OpenRouter"
        }
    }

    var chatEndpoint: URL {
        switch self {
        case .payPerQ: return Endpoints.payPerQChat
        case .openRouter: return Endpoints.openRouterChat
        }
    }

    /// The URL used to open a pooled TLS connection ahead of a real request. Unauthenticated on
    /// purpose: a pre-warm must never carry anything that identifies the user.
    var prewarmEndpoint: URL {
        switch self {
        case .payPerQ: return Endpoints.payPerQModels
        case .openRouter: return Endpoints.openRouterKey
        }
    }

    /// Where the user goes to get a key. Linked from the settings window, because "paste your API
    /// key" is useless advice if you do not already know where the page is.
    var keyPageURL: URL {
        switch self {
        case .payPerQ: return URL(string: "https://ppq.ai/api-keys")!
        case .openRouter: return URL(string: "https://openrouter.ai/keys")!
        }
    }
}

enum Endpoints {
    static let openRouterChat = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let openRouterKey = URL(string: "https://openrouter.ai/api/v1/key")!
    static let payPerQChat = URL(string: "https://api.ppq.ai/chat/completions")!
    static let payPerQModels = URL(string: "https://api.ppq.ai/v1/models")!
}

enum PricingTier: String {
    case free, cheap, medium, expensive

    var label: String {
        switch self {
        case .free: return "free"
        case .cheap: return "cheap"
        case .medium: return "medium"
        case .expensive: return "pricey"
        }
    }
}

struct ModelEntry {
    let slug: String
    let displayName: String
    let tier: PricingTier
    var zdr: Bool = false
    var cache: Bool = false
}

/// The models offered in the picker, ordered fastest-first from timings measured against the live
/// APIs with reasoning suppressed. The zero-data-retention flags were reconciled against
/// OpenRouter's own /api/v1/endpoints/zdr list rather than left as hand-maintained guesses.
///
/// Kept identical to the Windows agent's catalog so one config.json means the same thing on both.
enum ModelCatalog {
    static let customSlug = "custom"

    static let openRouter: [ModelEntry] = [
        ModelEntry(slug: "~openai/gpt-mini-latest", displayName: "GPT Mini", tier: .medium, zdr: true, cache: true),
        ModelEntry(slug: "~anthropic/claude-haiku-latest", displayName: "Claude Haiku", tier: .medium, zdr: true, cache: true),
        ModelEntry(slug: "deepseek/deepseek-v4-flash", displayName: "DeepSeek V4 Flash", tier: .cheap, zdr: true, cache: true),
        ModelEntry(slug: "x-ai/grok-4.3", displayName: "Grok 4.3", tier: .medium, zdr: true, cache: true),
        ModelEntry(slug: "~google/gemini-flash-latest", displayName: "Gemini Flash", tier: .cheap, zdr: true, cache: true),
    ]

    static let payPerQ: [ModelEntry] = [
        ModelEntry(slug: "~openai/gpt-mini-latest", displayName: "GPT Mini", tier: .medium),
        ModelEntry(slug: "x-ai/grok-4.3", displayName: "Grok 4.3", tier: .medium),
        ModelEntry(slug: "~anthropic/claude-haiku-latest", displayName: "Claude Haiku", tier: .medium),
        ModelEntry(slug: "~google/gemini-flash-latest", displayName: "Gemini Flash", tier: .cheap),
        ModelEntry(slug: "deepseek/deepseek-v4-flash", displayName: "DeepSeek V4 Flash", tier: .cheap, zdr: true, cache: true),
    ]

    static func entries(for provider: AiProvider) -> [ModelEntry] {
        provider == .payPerQ ? payPerQ : openRouter
    }

    static func supports(_ provider: AiProvider, _ slug: String) -> Bool {
        slug == customSlug || entries(for: provider).contains { $0.slug == slug }
    }

    /// Resolves the slug actually sent to the provider. "custom" defers to the user's own slug,
    /// and a blank custom slug resolves to nothing at all rather than to a silent fallback the
    /// user never chose.
    static func resolve(_ selectedSlug: String, _ customSlug: String) -> String? {
        if selectedSlug != ModelCatalog.customSlug {
            let trimmed = selectedSlug.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        let trimmed = customSlug.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Accepts author/slug, author/slug:variant and ~author/model-latest; rejects whitespace and
    /// bare names. Empty is allowed so the field can be cleared without a validation block.
    static func isValidCustomSlug(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return true }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        var author = Substring(parts[0])
        let model = Substring(parts[1])
        if author.first == "~" { author = author.dropFirst() }
        return isSlugPart(author, allowColon: false) && isSlugPart(model, allowColon: true)
    }

    private static func isSlugPart(_ part: Substring, allowColon: Bool) -> Bool {
        guard let first = part.first, let last = part.last else { return false }
        guard first.isASCIILetterOrDigit, last.isASCIILetterOrDigit else { return false }
        for c in part {
            let ok = c.isASCIILetterOrDigit || c == "." || c == "_" || c == "-" || (allowColon && c == ":")
            if !ok { return false }
        }
        return true
    }
}

extension Character {
    var isASCIILetterOrDigit: Bool { isASCII && (isLetter || isNumber) }
}
