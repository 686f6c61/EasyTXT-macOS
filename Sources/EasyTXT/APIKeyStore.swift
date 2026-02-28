import Foundation
import Security

final class APIKeyStore {
    private let service = "com.686f6c61.easytxt.apikeys"

    func key(for provider: AIProvider) -> String? {
        if let data = keychainData(for: provider),
           let keychainValue = String(data: data, encoding: .utf8),
           !keychainValue.isEmpty
        {
            return keychainValue
        }
        if let env = environmentKey(for: provider), !env.isEmpty {
            return env
        }
        return nil
    }

    func save(_ key: String, for provider: AIProvider) {
        let data = Data(key.utf8)
        let query = baseQuery(for: provider)

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(create as CFDictionary, nil)
    }

    func deleteKey(for provider: AIProvider) {
        SecItemDelete(baseQuery(for: provider) as CFDictionary)
    }

    private func keychainData(for provider: AIProvider) -> Data? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    private func baseQuery(for provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func environmentKey(for provider: AIProvider) -> String? {
        let env = ProcessInfo.processInfo.environment
        switch provider {
        case .anthropic:
            return env["ANTHROPIC_API_KEY"]
        case .openAI:
            return env["OPENAI_API_KEY"]
        }
    }
}
