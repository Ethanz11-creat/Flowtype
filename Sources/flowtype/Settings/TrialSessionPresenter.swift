import Foundation
import Combine

/// Owns only temporary trial state. Construction does not prepare services or UI.
@MainActor
final class TrialSessionPresenter: ObservableObject {
    private final class ResultReceiver: SessionObserver, @unchecked Sendable {
        weak var presenter: TrialSessionPresenter?
        func sessionDidTransition(from oldState: SessionState, to newState: SessionState, context: SessionContext) {
            guard case .notice(let message) = newState else { return }
            MainActor.assumeIsolated { presenter?.receiveNotice(sessionID: context.sessionID, message: message) }
        }
    }
    let controller: SessionController
    private let resources: SessionResourceCoordinator
    var isResourceBusy: Bool { resources.owner != nil && !controller.ownsRecordingResource }
    private var resultValue: String?
    var result: String? { resultValue }
    private(set) var terminalNotice: String?
    private var generation: UInt64 = 0
    private var acceptedSession: (generation: UInt64, sessionID: UInt64)?
    private let copy: @MainActor (String) -> Void
    private var observation: AnyCancellable?
    private var resourceObservation: AnyCancellable?

    convenience init(configuration: ConfigurationStore, resources: SessionResourceCoordinator,
                     refreshReadiness: @escaping @MainActor () -> ReadinessLevel,
                     readinessLevel: @escaping @MainActor @Sendable () -> ReadinessLevel,
                     copy: @escaping @MainActor (String) -> Void) {
        self.init(configuration: configuration, resources: resources, refreshReadiness: refreshReadiness,
                  readinessLevel: readinessLevel, copy: copy, makeStages: OnboardingPipeline.makeStages)
    }

    /// Explicit stage seam for tests; the production initializer always uses real stages.
    init(configuration: ConfigurationStore, resources: SessionResourceCoordinator,
         refreshReadiness: @escaping @MainActor () -> ReadinessLevel,
         readinessLevel: @escaping @MainActor @Sendable () -> ReadinessLevel,
         copy: @escaping @MainActor (String) -> Void,
         makeStages: (@escaping @MainActor @Sendable (UInt64, String) -> Void) -> [PipelineStage]) {
        self.copy = copy
        self.resources = resources
        let receiver = ResultReceiver()
        controller = SessionController(pipeline: makeStages { [receiver] sessionID, text in
            receiver.presenter?.receive(sessionID: sessionID, text: text)
        }, observers: [receiver], effects: .init(prepare: {}, showWindow: {}, hideWindow: {}),
        recoveryEffects: .init(openAccessibilitySettings: {}, openMicrophoneSettings: {},
            openSpeechRecognitionSettings: {}, openASRSettings: {}, openHistory: {}, copyText: { _ in }),
        configurationStore: configuration, refreshReadiness: refreshReadiness, readinessLevel: readinessLevel,
        purpose: .trial, resources: resources)
        receiver.presenter = self
        observation = controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        resourceObservation = resources.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func start() {
        cancel()
        let requestedGeneration = generation
        controller.startRecording()
        guard generation == requestedGeneration, let sessionID = controller.currentSessionIdentifier else { return }
        acceptedSession = (generation, sessionID)
    }
    func stop() { controller.endRecording() }
    func cancel() {
        generation &+= 1
        acceptedSession = nil
        resultValue = nil
        terminalNotice = nil
        controller.cancel()
        objectWillChange.send()
    }
    func copyResult() {
        guard let result, !result.isEmpty else { return }
        copy(result)
    }
    private func receiveNotice(sessionID: UInt64, message: String) {
        guard let acceptedSession, acceptedSession.generation == generation,
              acceptedSession.sessionID == sessionID, controller.currentSessionIdentifier == sessionID else { return }
        // The capsule auto-dismisses notices; the trial keeps its explanation until
        // the next explicit attempt/cancel, alongside any successfully delivered fallback.
        terminalNotice = message
        objectWillChange.send()
    }
    private func receive(sessionID: UInt64, text: String) {
        guard let acceptedSession, acceptedSession.generation == generation,
              acceptedSession.sessionID == sessionID, controller.currentSessionIdentifier == sessionID else { return }
        resultValue = text
        objectWillChange.send()
    }
}
