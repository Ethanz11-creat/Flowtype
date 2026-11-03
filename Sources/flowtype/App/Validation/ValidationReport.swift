import Foundation

enum ValidationFailureCode: String, Codable, Sendable {
    case startupFailed, timerDeadline, windowServerUnavailable, invalidBuildInfo
    case resourceMissing, resourceMalformed, resourceOutsideBundle, metalUnavailable, metalLibraryInvalid, mlxOperationFailed, unexpectedFailure
}
enum ValidationReadiness: String, Codable, Sendable { case ready, degraded, blocked }
enum ValidationPermission: String, Codable, Sendable { case granted, denied, notDetermined, unknown }
enum ValidationAction: String, CaseIterable, Sendable {
    case tapInstall, tapRepair, hotkey, dictation, menuWindow, repair, permission, configuration, quit
}
struct ValidationActionGate: Sendable {
    let role: ProcessRole
    var downstream: (@Sendable (ValidationAction) -> Void)? = nil
    static var live: ValidationActionGate { ValidationActionGate(role: RuntimeEnvironment.current.role) }
    var isApp: Bool { role == .app }
    func allow(_ action: ValidationAction) -> Bool { guard isApp else { return false }; downstream?(action); return true }
}
struct SmokeReport: Codable, Sendable {
    let schemaVersion: Int
    let mode: String
    let ok: Bool
    let role: ProcessRole
    let runID: String
    let buildInfo: BuildIdentity
    let durationMs: Int
    let failureCode: ValidationFailureCode?
    let readiness: ValidationReadiness
    let ax: ValidationPermission
    let mic: ValidationPermission
    let speech: ValidationPermission
    let probeTimerTicks: Int
    let windowHealthTicks: Int
    let tap: String
    var exitCode: Int32 { ok ? 0 : failureCode == .windowServerUnavailable ? 69 : 1 }

    static func evaluate(context: RuntimeContext, buildInfo: BuildIdentity, durationMs: Int,
                         snapshot: ReadinessSnapshot, probeTimerTicks: Int, windowHealthTicks: Int,
                         failure: ValidationFailureCode? = nil) -> SmokeReport {
        let problem = failure ?? (durationMs < 6000 || probeTimerTicks < 1 || windowHealthTicks < 1 ? .timerDeadline : nil)
        let readiness: ValidationReadiness
        switch classifyReadiness(snapshot) { case .ready: readiness = .ready; case .blocked: readiness = .blocked; case .degraded: readiness = .degraded }
        func permission(_ state: PermissionState) -> ValidationPermission {
            switch state { case .granted: .granted; case .denied: .denied; case .notDetermined: .notDetermined; case .unknown: .unknown }
        }
        return SmokeReport(schemaVersion: 1, mode: "smoke", ok: problem == nil, role: context.role, runID: context.runID.uuidString,
            buildInfo: buildInfo, durationMs: durationMs, failureCode: problem, readiness: readiness,
            ax: permission(snapshot.accessibility), mic: permission(snapshot.microphone), speech: permission(snapshot.speechRecognition),
            probeTimerTicks: probeTimerTicks, windowHealthTicks: windowHealthTicks, tap: "disabledForValidation")
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mode, ok, role, runID, buildInfo, durationMs, failureCode, readiness, ax, mic, speech, probeTimerTicks, windowHealthTicks, tap
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(mode, forKey: .mode); try c.encode(ok, forKey: .ok)
        try c.encode(role, forKey: .role); try c.encode(runID, forKey: .runID); try c.encode(buildInfo, forKey: .buildInfo)
        try c.encode(durationMs, forKey: .durationMs); try c.encode(failureCode, forKey: .failureCode)
        try c.encode(readiness, forKey: .readiness); try c.encode(ax, forKey: .ax); try c.encode(mic, forKey: .mic)
        try c.encode(speech, forKey: .speech); try c.encode(probeTimerTicks, forKey: .probeTimerTicks)
        try c.encode(windowHealthTicks, forKey: .windowHealthTicks); try c.encode(tap, forKey: .tap)
    }
}
