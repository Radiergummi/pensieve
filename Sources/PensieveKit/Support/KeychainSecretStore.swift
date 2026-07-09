import Foundation
import Security

/// Thin generic-password wrapper. App-only (the daemon can't answer a Keychain prompt). Errors are
/// best-effort/swallowed: a failed read ⇒ nil ⇒ the cloud provider falls back to local. Never logs
/// the secret.
public struct KeychainSecretStore: Sendable {
  private let service: String
  public init(service: String = "com.pensieve.cloud-llm") { self.service = service }

  public func read(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let secret = String(data: data, encoding: .utf8) else { return nil }
    return secret
  }

  /// Upserts the secret. An empty string deletes the item (so blanking the field clears the key).
  public func write(_ secret: String, account: String) {
    guard !secret.isEmpty else { delete(account: account); return }
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let data = Data(secret.utf8)
    let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = base
      add[kSecValueData as String] = data
      SecItemAdd(add as CFDictionary, nil)
    }
  }

  public func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
