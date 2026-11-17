import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - 内存钥匙串兜底

/// 非 macOS 平台（Linux 验证/测试）的内存实现，与系统 Keychain 走同一接口。
/// 全平台编译：测试直接验证本实现的往返语义，macOS 正式路径走系统 Keychain，
/// 测试不触真实钥匙串（CI 上钥匙串可能上锁或弹授权窗）。
final class MemoryKeychain {
    private static var store: [String: String] = [:]
    private static let lock = NSLock()

    private static func key(service: String, account: String) -> String {
        service + "\n" + account
    }

    static func save(_ value: String, service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        store[key(service: service, account: account)] = value
        return true
    }

    static func load(service: String, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[key(service: service, account: account)]
    }

    static func delete(service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key(service: service, account: account))
    }
}

// MARK: - 系统钥匙串

/// API Key 的唯一存放处。macOS 走系统 Keychain（通用密码类），Key 绝不进
/// UserDefaults、明文文件或日志；非 macOS 平台走内存兜底（进程内有效）。
enum KeychainStore {

    static func save(_ value: String, service: String, account: String) -> Bool {
#if canImport(Security)
        return secSave(value, service: service, account: account)
#else
        return MemoryKeychain.save(value, service: service, account: account)
#endif
    }

    static func load(service: String, account: String) -> String? {
#if canImport(Security)
        return secLoad(service: service, account: account)
#else
        return MemoryKeychain.load(service: service, account: account)
#endif
    }

    static func delete(service: String, account: String) {
#if canImport(Security)
        secDelete(service: service, account: account)
#else
        MemoryKeychain.delete(service: service, account: account)
#endif
    }

#if canImport(Security)
    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func secSave(_ value: String, service: String, account: String) -> Bool {
        let q = query(service: service, account: account)
        // 先删后加：避免 SecItemUpdate 的属性组合差异；删除失败（不存在）可忽略。
        SecItemDelete(q as CFDictionary)
        var attrs = q
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    private static func secLoad(service: String, account: String) -> String? {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func secDelete(service: String, account: String) {
        let q = query(service: service, account: account)
        SecItemDelete(q as CFDictionary)
    }
#endif
}
