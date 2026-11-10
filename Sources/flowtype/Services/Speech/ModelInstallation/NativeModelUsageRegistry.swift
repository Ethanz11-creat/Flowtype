import Foundation
import os

enum NativeModelUsageError: LocalizedError, Equatable {
    case inUse, deletionReserved, external, invalidOwnership, selected
    var errorDescription: String? {
        switch self {
        case .inUse, .deletionReserved: "模型仍在使用或正在移除，请结束相关会话后重试。"
        case .external: "旧模型目录属于用户文件，不能通过删除下载移除。可仅移除模型记录。"
        case .invalidOwnership: "无法确认下载文件归属，请检查模型安装记录。"
        case .selected: "请先解除该模型的主选或备选选择，再移除。"
        }
    }
}

/// The reservation itself is retained across tasks; checking and reserving share one lock.
final class NativeModelUsageRegistry: Sendable {
    static let shared = NativeModelUsageRegistry()
    private struct Entry: Sendable { var users = 0; var captures = 0; var deleting = false }
    private struct Drain: Sendable { let modelID: UUID; let task: Task<Void, Never> }
    private struct State: Sendable { var entries: [UUID: Entry] = [:]; var drains: [UUID: Drain] = [:] }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    func acquire(modelID: UUID) throws -> ModelUsageToken { try acquire(modelID: modelID, capture: false, externalSource: false) }
    fileprivate func acquire(modelID: UUID, capture: Bool, externalSource: Bool) throws -> ModelUsageToken {
        try lock.withLock { state in
            var entry = state.entries[modelID] ?? Entry()
            guard !entry.deleting else { throw NativeModelUsageError.deletionReserved }
            entry.users += 1
            if capture { entry.captures += 1 }
            state.entries[modelID] = entry
        }
        return ModelUsageToken(modelID: modelID, registry: self, capture: capture, externalSource: externalSource)
    }
    /// Legacy/native boundary registration grants usage only, never file ownership.
    func registerExternalCapture(modelID: UUID) throws -> ModelUsageToken {
        try acquire(modelID: modelID, capture: true, externalSource: true)
    }
    func reserveDeletion(modelID: UUID) throws -> ModelDeletionPermit {
        try lock.withLock { state in
            var entry = state.entries[modelID] ?? Entry()
            guard !entry.deleting else { throw NativeModelUsageError.deletionReserved }
            guard entry.users == 0 else { throw NativeModelUsageError.inUse }
            entry.deleting = true; state.entries[modelID] = entry
        }
        return ModelDeletionPermit(modelID: modelID, registry: self)
    }
    /// C4 must also check its live recording state in Qwen's synchronous unload gate.
    func hasNoCapturedUsage(modelID: UUID) -> Bool {
        lock.withLock { ($0.entries[modelID]?.captures ?? 0) == 0 && !$0.drains.values.contains { $0.modelID == modelID } }
    }
    func pendingDrains(modelID: UUID) -> Int { lock.withLock { $0.drains.values.filter { $0.modelID == modelID }.count } }

    /// Register the keeper while the exact caller token is still alive. The registry
    /// owns it until the existing native queue barrier completes; no native work is started.
    fileprivate func retainUntilDrained(_ token: ModelUsageToken, provider: any ASRProvider,
                                       drain: @escaping @Sendable () async -> Void) {
        let id = UUID()
        lock.withLock { state in
            let task = Task { [token, provider] in
                await drain()
                self.finishDrain(id)
                withExtendedLifetime((token, provider)) {}
            }
            state.drains[id] = Drain(modelID: token.modelID, task: task)
        }
    }
    private func finishDrain(_ id: UUID) { lock.withLock { $0.drains[id] = nil } }
    fileprivate func release(_ id: UUID, capture: Bool) {
        lock.withLock { state in
            guard var entry = state.entries[id] else { return }
            entry.users -= 1; if capture { entry.captures -= 1 }
            if entry.users == 0 && !entry.deleting { state.entries[id] = nil } else { state.entries[id] = entry }
        }
    }
    fileprivate func releaseDeletion(_ id: UUID) { lock.withLock { $0.entries[id] = nil } }
}

final class ModelUsageToken: Sendable {
    let modelID: UUID
    fileprivate let registry: NativeModelUsageRegistry
    private let capture: Bool
    let isExternalSource: Bool
    fileprivate init(modelID: UUID, registry: NativeModelUsageRegistry, capture: Bool, externalSource: Bool) {
        self.modelID = modelID; self.registry = registry; self.capture = capture; self.isExternalSource = externalSource
    }
    func captured() throws -> ModelUsageToken { try registry.acquire(modelID: modelID, capture: true, externalSource: isExternalSource) }
    deinit { registry.release(modelID, capture: capture) }
}

final class ModelDeletionPermit: Sendable {
    let modelID: UUID
    private let registry: NativeModelUsageRegistry
    fileprivate init(modelID: UUID, registry: NativeModelUsageRegistry) { self.modelID = modelID; self.registry = registry }
    deinit { registry.releaseDeletion(modelID) }
}

/// Native cancellation may resume its caller before compute exits. Keep the token until
/// the real queue barrier returns, even if the route/session has already released its lease.
struct NativeUsageProvider: ASRProvider {
    let base: any ASRProvider
    let token: ModelUsageToken
    let drain: @Sendable () async -> Void
    var id: String { base.id }
    var displayName: String { base.displayName }
    var capabilities: ASRCapabilities { base.capabilities }
    var isAvailable: Bool { get async { await base.isAvailable } }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        let outcome: Result<ASRResult, Error>
        do { outcome = .success(try await base.transcribe(request)) } catch { outcome = .failure(error) }
        token.registry.retainUntilDrained(token, provider: base, drain: drain)
        return try outcome.get()
    }
}
