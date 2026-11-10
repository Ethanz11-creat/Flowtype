import Foundation
import Combine

enum SessionPurpose: Sendable { case dictation, trial }

/// One recording/pipeline owner across ordinary entry points and trial presenters.
/// Authority is committed before notifications; published owner is presentation only.
@MainActor
final class SessionResourceCoordinator: ObservableObject {
    static let shared = SessionResourceCoordinator()
    @Published private(set) var owner: UUID?
    private var reservation: (owner: UUID, token: UUID)?
    private var publishing = false

    func acquire(owner: UUID) -> UUID? {
        guard reservation == nil else { return nil }
        let token = UUID()
        reservation = (owner, token)
        publishOwner()
        return owns(token: token) ? token : nil
    }

    func release(token: UUID) {
        guard owns(token: token) else { return }
        reservation = nil
        publishOwner()
    }

    var isReserved: Bool { reservation != nil }

    func owns(token: UUID) -> Bool { reservation?.token == token }

    private func publishOwner() {
        guard !publishing else { return }
        publishing = true
        // @Published sends in willSet. Reentrant changes are authoritative now,
        // but their presentation waits until this assignment has completed.
        repeat { owner = reservation?.owner } while owner != reservation?.owner
        publishing = false
    }
}

/// A cancelled task may still be stopping capture. Retain the exact reservation
/// until every entered stage has returned, independently of currentTask/UI state.
@MainActor
final class SessionResourceLease {
    let token: UUID
    private let resources: SessionResourceCoordinator
    private var stages = 0
    private var ended = false
    var isActive: Bool { !ended && resources.owns(token: token) }

    init(token: UUID, resources: SessionResourceCoordinator) {
        self.token = token
        self.resources = resources
    }
    func enterStage() -> Bool {
        guard isActive else { return false }
        stages += 1
        return true
    }
    func leaveStage() {
        stages -= 1
        releaseIfDrained()
    }
    func end() {
        ended = true
        releaseIfDrained()
    }
    private func releaseIfDrained() {
        if ended && stages == 0 { resources.release(token: token) }
    }
}
