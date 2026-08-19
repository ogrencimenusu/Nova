import Foundation
import Security

// MARK: - Shared Models for AppGroup Cache
struct CachedBank: Codable, Identifiable {
    let id: String
    let name: String
    let logo: String
    var order: Int = 999
}

struct CachedTransactionType: Codable, Identifiable {
    let id: String
    let name: String
    var order: Int = 999
}

struct CachedQuickAction: Codable, Identifiable {
    let id: String
    let name: String
    let color: String
    var order: Int = 999
}

// MARK: - KeychainHelper
struct KeychainHelper {
    static let service = "sakyol.Nova.shared"
    static let uidAccount = "nova_user_uid"
    static let tokenAccount = "nova_drive_token"
    
    static func getAccessGroup() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "probe_group_detect",
            kSecReturnAttributes as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &item)
        var detectedGroup = "A64NZ37MJD.group.sakyol.nova"
        if (status == errSecSuccess || status == errSecDuplicateItem),
           let itemDict = item as? [String: Any],
           let group = itemDict[kSecAttrAccessGroup as String] as? String {
            detectedGroup = group
        }
        SecItemDelete(query as CFDictionary)
        return detectedGroup
    }
    
    static func save(key: String, value: String) {
        guard !value.isEmpty else { return }
        let group = getAccessGroup()
        let data = value.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: group,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        SecItemDelete(query as CFDictionary)
        _ = SecItemAdd(query as CFDictionary, nil)
    }
    
    static func load(key: String) -> String? {
        let group = getAccessGroup()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess, let data = dataTypeRef as? Data, let str = String(data: data, encoding: .utf8) {
            return str
        }
        return nil
    }
}

// MARK: - AppGroupStorage
struct AppGroupStorage {
    static let possibleGroupIdentifiers: [String] = [
        "group.sakyol.nova",
        "A64NZ37MJD.group.sakyol.nova",
        "group.sakyol.Nova",
        "A64NZ37MJD.group.sakyol.Nova"
    ]
    
    static var activeContainer: (url: URL, group: String)? {
        for group in possibleGroupIdentifiers {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return (url, group)
            }
        }
        return nil
    }
    
    // MARK: - UID
    static func saveUID(_ uid: String) {
        guard !uid.isEmpty else { return }
        KeychainHelper.save(key: KeychainHelper.uidAccount, value: uid)
        if let container = activeContainer {
            let url = container.url.appendingPathComponent("current_user_uid.txt")
            try? uid.write(to: url, atomically: true, encoding: .utf8)
        }
        for group in possibleGroupIdentifiers {
            UserDefaults(suiteName: group)?.set(uid, forKey: "current_user_uid")
        }
        UserDefaults.standard.set(uid, forKey: "current_user_uid")
    }
    
    static func getUID() -> (uid: String?, source: String) {
        if let v = KeychainHelper.load(key: KeychainHelper.uidAccount), !v.isEmpty { return (v, "Keychain") }
        if let container = activeContainer {
            let url = container.url.appendingPathComponent("current_user_uid.txt")
            if let v = try? String(contentsOf: url, encoding: .utf8), !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (v.trimmingCharacters(in: .whitespacesAndNewlines), "AppGroup Disk")
            }
        }
        for group in possibleGroupIdentifiers {
            if let v = UserDefaults(suiteName: group)?.string(forKey: "current_user_uid"), !v.isEmpty { return (v, "UserDefaults(\(group))") }
        }
        if let v = UserDefaults.standard.string(forKey: "current_user_uid"), !v.isEmpty { return (v, "UserDefaults.standard") }
        return (nil, "Bulunamadı")
    }
    
    // MARK: - Banks Cache (JSON)
    static func saveBanks(_ banks: [CachedBank]) {
        guard let data = try? JSONEncoder().encode(banks) else { return }
        if let container = activeContainer {
            let url = container.url.appendingPathComponent("cached_banks.json")
            try? data.write(to: url, options: .atomic)
        }
        for group in possibleGroupIdentifiers {
            UserDefaults(suiteName: group)?.set(data, forKey: "cached_banks")
        }
    }
    
    static func getBanks() -> [CachedBank] {
        if let container = activeContainer {
            let url = container.url.appendingPathComponent("cached_banks.json")
            if let data = try? Data(contentsOf: url), let banks = try? JSONDecoder().decode([CachedBank].self, from: data) {
                return banks
            }
        }
        for group in possibleGroupIdentifiers {
            if let data = UserDefaults(suiteName: group)?.data(forKey: "cached_banks"),
               let banks = try? JSONDecoder().decode([CachedBank].self, from: data) {
                return banks
            }
        }
        return []
    }
    
    // MARK: - Transaction Types Cache (JSON)
    static func saveTransactionTypes(_ types: [CachedTransactionType]) {
        guard let data = try? JSONEncoder().encode(types) else { return }
        if let container = activeContainer {
            let url = container.url.appendingPathComponent("cached_transaction_types.json")
            try? data.write(to: url, options: .atomic)
        }
        for group in possibleGroupIdentifiers {
            UserDefaults(suiteName: group)?.set(data, forKey: "cached_transaction_types")
        }
    }
    
    static func getTransactionTypes() -> [CachedTransactionType] {
        if let container = activeContainer {
            let url = container.url.appendingPathComponent("cached_transaction_types.json")
            if let data = try? Data(contentsOf: url), let types = try? JSONDecoder().decode([CachedTransactionType].self, from: data) {
                return types
            }
        }
        for group in possibleGroupIdentifiers {
            if let data = UserDefaults(suiteName: group)?.data(forKey: "cached_transaction_types"),
               let types = try? JSONDecoder().decode([CachedTransactionType].self, from: data) {
                return types
            }
        }
        return []
    }
    
    // MARK: - Quick Actions Cache (JSON)
    static func saveQuickActions(_ actions: [CachedQuickAction]) {
        guard let data = try? JSONEncoder().encode(actions) else { return }
        if let container = activeContainer {
            let url = container.url.appendingPathComponent("cached_quick_actions.json")
            try? data.write(to: url, options: .atomic)
        }
        for group in possibleGroupIdentifiers {
            UserDefaults(suiteName: group)?.set(data, forKey: "cached_quick_actions")
        }
    }
    
    static func getQuickActions() -> [CachedQuickAction] {
        if let container = activeContainer {
            let url = container.url.appendingPathComponent("cached_quick_actions.json")
            if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([CachedQuickAction].self, from: data) {
                return list
            }
        }
        for group in possibleGroupIdentifiers {
            if let data = UserDefaults(suiteName: group)?.data(forKey: "cached_quick_actions"),
               let list = try? JSONDecoder().decode([CachedQuickAction].self, from: data) {
                return list
            }
        }
        return []
    }
    
    // MARK: - Drive Token
    static func saveDriveToken(_ token: String) {
        guard !token.isEmpty else { return }
        KeychainHelper.save(key: KeychainHelper.tokenAccount, value: token)
        if let container = activeContainer {
            let url = container.url.appendingPathComponent("google_drive_token.txt")
            try? token.write(to: url, atomically: true, encoding: .utf8)
        }
        for group in possibleGroupIdentifiers {
            UserDefaults(suiteName: group)?.set(token, forKey: "google_drive_access_token")
        }
        UserDefaults.standard.set(token, forKey: "google_drive_access_token")
    }
    
    static func getDriveToken() -> (token: String?, source: String) {
        if let v = KeychainHelper.load(key: KeychainHelper.tokenAccount), !v.isEmpty { return (v, "Keychain") }
        if let container = activeContainer {
            let url = container.url.appendingPathComponent("google_drive_token.txt")
            if let v = try? String(contentsOf: url, encoding: .utf8), !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (v.trimmingCharacters(in: .whitespacesAndNewlines), "AppGroup Disk")
            }
        }
        for group in possibleGroupIdentifiers {
            if let v = UserDefaults(suiteName: group)?.string(forKey: "google_drive_access_token"), !v.isEmpty { return (v, "UserDefaults(\(group))") }
        }
        return (nil, "Bulunamadı")
    }
}
