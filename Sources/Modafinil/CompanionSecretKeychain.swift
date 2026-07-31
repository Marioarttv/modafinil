import Foundation
import Security

/// Stores companion pairing secrets in the login keychain instead of
/// UserDefaults, so they are not readable from a plain preferences plist
/// or included in unencrypted backups.
struct CompanionSecretKeychain {
    private let service = "com.narcotic.modafinil.companion"

    func secret(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                NSLog("Modafinil could not read the %@ keychain item: %d", account, status)
            }
            return nil
        }
        return data
    }

    @discardableResult
    func setSecret(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            NSLog("Modafinil could not update the %@ keychain item: %d", account, updateStatus)
            return false
        }

        var insertion = query
        insertion[kSecValueData as String] = data
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            NSLog("Modafinil could not store the %@ keychain item: %d", account, addStatus)
            return false
        }
        return true
    }

    func deleteSecret(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("Modafinil could not delete the %@ keychain item: %d", account, status)
        }
    }
}
