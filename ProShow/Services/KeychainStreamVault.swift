import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif
#if canImport(IOKit)
import IOKit
#endif

/// Stream keys and OAuth tokens. Never stored as raw JSON, and never written
/// to the login or data-protection keychain. Secrets live in an AES-GCM box
/// in Application Support, wrapped with a device-bound key. Older keychain
/// copies are migrated into the box once, then deleted.
enum KeychainStreamVault {
    static let service = "com.kaleel.proshow.stream"
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private static let queueToken: UInt8 = 1
    private static let keychainQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.kaleel.proshow.keychain")
        queue.setSpecific(key: queueKey, value: queueToken)
        return queue
    }()

    @discardableResult
    static func save(identifier: String, secret: String) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        remember(identifier, trimmed)
        return onKeychainQueue {
            let wrote = writeBox(identifier: identifier, secret: trimmed)
            #if canImport(Security)
            _ = deleteKeychain(identifier: identifier, dataProtection: true)
            _ = deleteKeychain(identifier: identifier, dataProtection: false)
            #endif
            return wrote
        }
    }

    static func load(identifier: String) -> String? {
        if let cached = recalled(identifier) { return cached }
        let value: String? = onKeychainQueue {
            if let boxed = readBox(identifier: identifier) {
                #if canImport(Security)
                _ = deleteKeychain(identifier: identifier, dataProtection: true)
                _ = deleteKeychain(identifier: identifier, dataProtection: false)
                #endif
                return boxed
            }
            #if canImport(Security)
            if let migrated = migrateFromKeychain(identifier: identifier) {
                return migrated
            }
            #endif
            return nil
        }
        if let value {
            remember(identifier, value)
        }
        return value
    }

    @discardableResult
    static func delete(identifier: String) -> Bool {
        forget(identifier)
        return onKeychainQueue {
            #if canImport(Security)
            let protected = deleteKeychain(identifier: identifier, dataProtection: true)
            let legacy = deleteKeychain(identifier: identifier, dataProtection: false)
            #else
            let protected = false
            let legacy = false
            #endif
            let boxed = deleteBox(identifier: identifier)
            return protected || legacy || boxed
        }
    }

    private static func remember(_ identifier: String, _ secret: String) {
        lock.lock()
        cache[identifier] = secret
        lock.unlock()
    }

    private static func recalled(_ identifier: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[identifier]
    }

    private static func forget(_ identifier: String) {
        lock.lock()
        cache.removeValue(forKey: identifier)
        lock.unlock()
    }

    private static func onKeychainQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return work()
        }
        return keychainQueue.sync(execute: work)
    }

    #if canImport(Security)
    private static func migrateFromKeychain(identifier: String) -> String? {
        let value = readKeychain(identifier: identifier, dataProtection: true)
            ?? readKeychain(identifier: identifier, dataProtection: false)
        guard let value, !value.isEmpty else { return nil }
        _ = writeBox(identifier: identifier, secret: value)
        _ = deleteKeychain(identifier: identifier, dataProtection: true)
        _ = deleteKeychain(identifier: identifier, dataProtection: false)
        return value
    }

    private static func readKeychain(identifier: String, dataProtection: Bool) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            baseQuery(identifier: identifier, dataProtection: dataProtection, extra: [
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            ]),
            &item
        )
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychain(identifier: String, dataProtection: Bool) -> Bool {
        let status = SecItemDelete(baseQuery(identifier: identifier, dataProtection: dataProtection, extra: [
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]))
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(
        identifier: String,
        dataProtection: Bool,
        extra: [String: Any] = [:]
    ) -> CFDictionary {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        extra.forEach { query[$0.key] = $0.value }
        return query as CFDictionary
    }
    #endif

    private static func writeBox(identifier: String, secret: String) -> Bool {
        var items = boxItems()
        items[identifier] = secret
        return persistBox(items)
    }

    private static func readBox(identifier: String) -> String? {
        boxItems()[identifier]
    }

    private static func deleteBox(identifier: String) -> Bool {
        var items = boxItems()
        if items.removeValue(forKey: identifier) == nil {
            return FileManager.default.fileExists(atPath: boxURL.path) == false
        }
        return persistBox(items)
    }

    private static func boxItems() -> [String: String] {
        guard let data = try? Data(contentsOf: boxURL),
              let opened = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(opened, using: deviceKey()),
              let object = try? JSONSerialization.jsonObject(with: plain) as? [String: String]
        else { return [:] }
        return object
    }

    private static func persistBox(_ items: [String: String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: boxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if items.isEmpty {
                try? FileManager.default.removeItem(at: boxURL)
                return true
            }
            let json = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
            let sealed = try AES.GCM.seal(json, using: deviceKey())
            guard let combined = sealed.combined else { return false }
            try combined.write(to: boxURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: boxURL.path)
            return true
        } catch {
            return false
        }
    }

    private static var boxURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return root.appendingPathComponent("ProShow", isDirectory: true)
            .appendingPathComponent("stream-vault.box")
    }

    private static func deviceKey() -> SymmetricKey {
        let seed = Data("com.kaleel.proshow.stream.v1.\(platformIdentifier())".utf8)
        return SymmetricKey(data: Data(SHA256.hash(data: seed)))
    }

    private static func platformIdentifier() -> String {
        #if canImport(IOKit)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let value = IORegistryEntryCreateCFProperty(
                service,
                "IOPlatformUUID" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String, !value.isEmpty {
                return value
            }
        }
        #endif
        return NSUserName()
    }
}
