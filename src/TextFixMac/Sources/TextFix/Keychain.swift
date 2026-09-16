// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// Stores provider API keys in the login keychain rather than anywhere this app controls.
///
/// The Windows agent encrypts its keys with DPAPI into a file next to config.json; the macOS
/// equivalent is simply the keychain, which is already bound to the user's login, already
/// encrypted at rest, and already the place the user knows to look if they want to revoke a key.
/// Either way the point is the same: the key never goes into config.json, which is a plain-text
/// file people paste into bug reports.
enum SecretStore {
    private static let service = "com.turtlecute33.textfix"

    private static func account(for provider: AiProvider) -> String { provider.pref }

    private static func baseQuery(_ provider: AiProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
        ]
    }

    static func apiKey(for provider: AiProvider) -> String {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                // A keychain that refuses to answer must read as "no key" rather than taking the
                // whole feature down: re-entering it in settings overwrites the item and
                // self-heals.
                Log.warn("Could not read the stored API key (OSStatus \(status))")
            }
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func hasApiKey(for provider: AiProvider) -> Bool { !apiKey(for: provider).isEmpty }

    static func setApiKey(_ key: String, for provider: AiProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = baseQuery(provider)

        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                Log.warn("Could not remove the stored API key (OSStatus \(status))")
            }
            return
        }

        guard let data = trimmed.data(using: .utf8) else { return }
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            // The agent only ever needs the key while the user is logged in and the screen is
            // unlocked, so this is the narrowest class that still works.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            insert[kSecAttrLabel as String] = "TextFix - \(provider.displayName) API key"
            insert[kSecAttrDescription as String] = "API key"
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Log.warn("Could not save the API key (OSStatus \(status))")
        }
    }
}
