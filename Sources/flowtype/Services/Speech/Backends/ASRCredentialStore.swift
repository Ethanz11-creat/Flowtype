import Foundation
import Security
import os

struct ASRCredentialSnapshot: Equatable, Sendable {
    let value: String?
    let generation: UUID
}

protocol ASRCredentialStore: Sendable {
    func read(id: String) throws -> String?
    func generation(id: String) -> UUID
    func snapshot(id: String) throws -> ASRCredentialSnapshot
    func write(_ value: String, id: String) throws
    func remove(id: String) throws
}

enum ASRCredentialError: LocalizedError {
    case unavailable, invalidData, persistence
    var errorDescription: String? {
        switch self {
        case .unavailable: "无法访问识别凭据，请解锁钥匙串后重试。"
        case .invalidData: "识别凭据无法读取，请重新保存。"
        case .persistence: "识别配置未能保存，请重试；原凭据已保留。"
        }
    }
}

/// SecItem is the only replaceable boundary; access errors never become a missing item.
struct ASRCredentialAccess: Sendable {
    var read: @Sendable (String) throws -> String?
    var update: @Sendable (String, String) throws -> Bool
    var add: @Sendable (String, String) throws -> Void
    var remove: @Sendable (String) throws -> Void

    static func memory() -> Self {
        let values = OSAllocatedUnfairLock(initialState: [String: String]())
        return .init(read: { id in values.withLock { $0[id] } }, update: { id, value in
            values.withLock { guard $0[id] != nil else { return false }; $0[id] = value; return true }
        }, add: { id, value in values.withLock { $0[id] = value } },
        remove: { id in values.withLock { _ = $0.removeValue(forKey: id) } })
    }

    static func guarded(role: ProcessRole, system: Self, effects: ValidationEffects) -> Self {
        guard role == .app else { return .memory() }
        return .init(read: { id in
            guard effects.allow(.keychain) else { throw ASRCredentialError.unavailable }
            return try system.read(id)
        }, update: { id, value in
            guard effects.allow(.keychain) else { throw ASRCredentialError.unavailable }
            return try system.update(id, value)
        }, add: { id, value in
            guard effects.allow(.keychain) else { throw ASRCredentialError.unavailable }
            try system.add(id, value)
        }, remove: { id in
            guard effects.allow(.keychain) else { throw ASRCredentialError.unavailable }
            try system.remove(id)
        })
    }

    /// Traditional login Keychain, deliberately without data-protection entitlement.
    static var system: Self {
        @Sendable func query(_ id: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.flowtype.app",
             kSecAttrAccount as String: id]
        }
        return .init(read: { id in
            var q = query(id)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw ASRCredentialError.unavailable }
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw ASRCredentialError.invalidData
            }
            return value
        }, update: { id, value in
            let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
            if status == errSecItemNotFound { return false }
            guard status == errSecSuccess else { throw ASRCredentialError.unavailable }
            return true
        }, add: { id, value in
            var q = query(id)
            q[kSecValueData as String] = Data(value.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            q[kSecAttrSynchronizable as String] = false
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ASRCredentialError.unavailable }
        }, remove: { id in
            let status = SecItemDelete(query(id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ASRCredentialError.unavailable }
        })
    }
}

/// One process-wide production owner keeps generations stable across consumers.
final class KeychainASRCredentialStore: ASRCredentialStore, @unchecked Sendable {
    static let shared = KeychainASRCredentialStore(access: .guarded(role: RuntimeEnvironment.current.role,
        system: .system, effects: .live))
    private let access: ASRCredentialAccess
    private let lock = NSLock()
    private var generations: [String: UUID] = [:]
    init(access: ASRCredentialAccess) { self.access = access }

    private func generationLocked(_ id: String) -> UUID {
        if let existing = generations[id] { return existing }
        let value = UUID(); generations[id] = value; return value
    }
    func read(id: String) throws -> String? { try snapshot(id: id).value }
    func generation(id: String) -> UUID {
        lock.lock(); defer { lock.unlock() }
        return generationLocked(id)
    }
    func snapshot(id: String) throws -> ASRCredentialSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(value: try access.read(id), generation: generationLocked(id))
    }
    func write(_ value: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard try access.read(id) != value else { return }
        if try !access.update(id, value) { try access.add(id, value) }
        generations[id] = UUID()
    }
    func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard try access.read(id) != nil else { return }
        try access.remove(id)
        generations[id] = UUID()
    }
}

extension CloudASRProviderConfig {
    var credentialID: String { "asr.cloud." + id.uuidString }
    /// Display/activation edits do not change the call revision.
    func hasSameCallConfiguration(as other: Self) -> Bool {
        baseURL == other.baseURL && model == other.model && protocolKind == other.protocolKind
            && vendorID == other.vendorID && customFieldCapabilities == other.customFieldCapabilities
            && provider == other.provider
    }
}

struct ASRCredentialMigrationResult {
    let configuration: Configuration
    let pendingIDs: [String]
}

enum ASRCredentialMigration {
    /// The caller must persist the result before replacing its recoverable source configuration.
    /// A conflicting Keychain value may be a newer committed edit: never overwrite it on retry.
    static func migrate(configuration: Configuration, store: any ASRCredentialStore) -> ASRCredentialMigrationResult {
        var next = configuration
        var pending: [String] = []
        for (legacyID, value) in configuration.cloudASRConfig.providerAPIKeys.sorted(by: { $0.key < $1.key }) {
            guard let uuid = UUID(uuidString: legacyID) else { pending.append("asr.cloud." + legacyID); continue }
            let id = "asr.cloud." + uuid.uuidString
            do {
                let existing = try store.read(id: id)
                guard existing == nil || existing == value else { pending.append(id); continue }
                if existing == nil { try store.write(value, id: id) }
                guard try store.read(id: id) == value else { pending.append(id); continue }
                next.cloudASRConfig.providerAPIKeys.removeValue(forKey: legacyID)
            } catch { pending.append(id) }
        }
        return .init(configuration: next, pendingIDs: pending)
    }
}
