import Foundation
import os

/// Concrete live boundaries, never injected model/session/transport state transitions.
final class ValidationEffects: Sendable {
    enum Operation: String, CaseIterable, Sendable {
        case keychain, network, modelScan, modelLoad, modelDownload, audioDevice, permissionRequest
        case clipboard, inputEvent, foregroundContext, sound, window, environment, pathMonitor
    }
    struct Counts: Sendable {
        var permitted: [Operation: Int] = [:]
        var blocked: [Operation: Int] = [:]
    }
    static let live: ValidationEffects = {
        let role = RuntimeEnvironment.current.role
        if role == .app { return ValidationEffects(role: role) }
        return ValidationEffects(role: role, external: { _ in })
    }()
    private let role: ProcessRole
    private let external: (@Sendable (Operation) -> Void)?
    private let counts = OSAllocatedUnfairLock(initialState: Counts())
    init(role: ProcessRole, external: (@Sendable (Operation) -> Void)? = nil) {
        self.role = role; self.external = external
    }
    var snapshot: Counts { counts.withLock { $0 } }
    func allow(_ operation: Operation) -> Bool {
        guard role == .app else {
            counts.withLock { $0.blocked[operation, default: 0] += 1 }
            return false
        }
        // Ordinary app has no observer/counter overhead. Explicit adapters can
        // account for admitted operations and independently observe downstream entry.
        if let external {
            counts.withLock { $0.permitted[operation, default: 0] += 1 }
            external(operation)
        }
        return true
    }
}

struct KeychainAccess: Sendable {
    var save: @Sendable (String, String) -> Bool
    var load: @Sendable (String) -> String?
    var delete: @Sendable (String) -> Void
    static let helper = KeychainAccess(save: { KeychainHelper.save(key: $0, value: $1) },
                                       load: { KeychainHelper.load(key: $0) }, delete: { KeychainHelper.delete(key: $0) })
    static func guarded(role: ProcessRole, system: KeychainAccess, effects: ValidationEffects) -> KeychainAccess {
        let memory = OSAllocatedUnfairLock(initialState: [String: String]())
        return KeychainAccess(save: { key, value in
            guard role == .app else { memory.withLock { $0[key] = value }; return true }
            guard effects.allow(.keychain) else { return false }
            return system.save(key, value)
        }, load: { key in
            guard role == .app else { return memory.withLock { $0[key] } }
            guard effects.allow(.keychain) else { return nil }
            return system.load(key)
        }, delete: { key in
            guard role == .app else { memory.withLock { _ = $0.removeValue(forKey: key) }; return }
            guard effects.allow(.keychain) else { return }
            system.delete(key)
        })
    }
}
