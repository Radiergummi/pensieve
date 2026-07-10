import Foundation
import Security

/// Thin generic-password wrapper. App-only (the daemon can't answer a Keychain prompt). Errors are
/// best-effort/swallowed: a failed read ⇒ nil ⇒ the cloud provider falls back to local. Never logs
/// the secret.
public struct KeychainSecretStore: Sendable {
  private let service: String
  public init(service: String = "me.mazetti.pensieve") { self.service = service }

  /// One-shot migration from the old `com.pensieve.cloud-llm` service. Copies any existing items
  /// to the new service and deletes the old ones. Call once on app launch.
  public static func migrateFromLegacyService() {
    let legacy = KeychainSecretStore(service: "com.pensieve.cloud-llm")
    let current = KeychainSecretStore()
    // The legacy scheme keyed accounts by `CloudFlavor.rawValue`; the current scheme keys per-vendor
    // via `CloudPresets.keychainAccount`. A verbatim copy would strand the "openAICompatible" key in
    // a slot no reader ever queries. Re-slot each legacy key into the account today's readers derive
    // from the persisted (flavor, baseURL).
    let storedBaseURL = PensieveDefaults.shared().string(forKey: PensieveDefaults.cloudBaseURLKey) ?? ""
    for flavor in CloudFlavor.allCases {
      guard let secret = legacy.read(account: flavor.rawValue) else { continue }
      let account = CloudPresets.keychainAccount(flavor: flavor, baseURL: storedBaseURL)
      if current.read(account: account) == nil { current.write(secret, account: account) }
      legacy.delete(account: flavor.rawValue)
    }
  }

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
