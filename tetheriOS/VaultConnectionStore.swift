import Foundation
import Security

@MainActor
struct VaultConnectionStore {
    private let userDefaults: UserDefaults
    private let service = "com.daksh.tetheriOS.vault"
    private let account = "github-token"
    private let configKey = "vaultConnectionConfig"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func saveConnection(_ connection: GitHubVaultConfiguration, token: String) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(connection)
        userDefaults.set(data, forKey: configKey)
        try saveToken(token)
    }

    func loadConnection() -> GitHubVaultConfiguration? {
        guard let data = userDefaults.data(forKey: configKey) else {
            return nil
        }

        return try? JSONDecoder().decode(GitHubVaultConfiguration.self, from: data)
    }

    func loadToken() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }

        return token
    }

    func clearConnection() {
        userDefaults.removeObject(forKey: configKey)
        deleteToken()
    }

    private func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        deleteToken()

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func deleteToken() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}
