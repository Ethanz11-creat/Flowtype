import Foundation
import SwiftUI

/// Exercises navigation through the real controller's card/session ownership gate.
enum NativeRecoveryNavigationSelfTests {
    private struct FailureStage: PipelineStage {
        let name = "ASR"
        let recovery: ErrorRecoveryContext
        func execute(payload: StagePayload, context: SessionContext) async -> StageResult { .suspend(recovery) }
    }

    private struct FailedProvider: ASRProvider {
        let id: String
        let displayName = "Synthetic"
        var isAvailable: Bool { true }
        let capabilities = ASRCapabilities(supportsLanguageHint: true, supportsContextHint: true,
            requiresNetwork: false, location: .onDevice)
        func transcribe(_ request: ASRRequest) async throws -> ASRResult {
            if id == ASRProviderID.local { throw ModelProvisionError.incompleteLocal() }
            throw CloudASRError.noAPIKey
        }
    }

    @MainActor static func failedCandidateDestinations(_ r: SelfTest.Reporter) async {
        let profile = CloudASRVendor.makeProfile(.openAI, isActive: true)
        for first in [ASRProviderID.cloud, ASRProviderID.local] {
            let context = SessionContext(sessionID: 1101)
            context.captureRoute = .init(policy: .auto, selectedProviderID: first, localAvailable: true,
                cloudAvailable: true, cloudConfiguration: .init(provider: profile, apiKey: "synthetic", sendContext: false))
            let stage = FixtureASRStage(healthRecorder: { _, _, _ in }, providerForID: { FailedProvider(id: $0) },
                speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
            if case .suspend(let recovery) = await stage.execute(payload: .audio(samples: [0.2, -0.1], previewText: ""), context: context) {
                r.eq(recovery.destination, .settings(.speech, .asrBackend(.init(rawValue: first))),
                    "ASR destination follows represented first cause through later fallback failure")
                r.eq(recovery.failureKind, first == ASRProviderID.cloud ? .configuration(.credentials) : .configuration(.endpointOrModel),
                    "ASR destination and reported failure share the same candidate")
            } else { r.check(false, "ASR candidate failure suspends") }
        }
        let noIdentity = SessionContext(sessionID: 1102)
        noIdentity.captureRoute = .init(policy: .cloudOnly, selectedProviderID: ASRProviderID.cloud, localAvailable: false,
            cloudAvailable: true, cloudConfiguration: nil)
        let stage = FixtureASRStage(healthRecorder: { _, _, _ in }, providerForID: { FailedProvider(id: $0) },
            speechPreflight: { _, _ in .possiblySpeech }, phrases: { [] })
        if case .suspend(let recovery) = await stage.execute(payload: .audio(samples: [0.2], previewText: ""), context: noIdentity) {
            r.eq(recovery.destination, .settings(.speech, .asrBackend(.init(rawValue: ASRProviderID.cloud))), "ASR unknown profile retains safe identity target")
        } else { r.check(false, "ASR unknown profile suspends") }
    }

    @MainActor static func run(_ r: SelfTest.Reporter) async {
        print("--- NativeRecoveryNavigationSelfTests.recoveryOpensCurrentDestinationWithoutRepeatingDelivery ---")
        await recoveryOpensCurrentDestinationWithoutRepeatingDelivery(r)
    }

    @MainActor static func recoveryOpensCurrentDestinationWithoutRepeatingDelivery(_ r: SelfTest.Reporter) async {
        await failedCandidateDestinations(r)
        let suite = "flowtype.native-recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: "flowtype.migrationVersion")
        let store = ConfigurationStore(defaults: defaults)
        let navigation = SettingsNavigation(initialTab: .history)
        r.eq(MainWindowView(navigation: navigation, page: { _ in AnyView(EmptyView()) }).selectedTab,
             .history, "injected navigator initial selection matches existing tab")
        let provider = UUID()
        for destination: ClientDestination in [.settings(.speech), .settings(.speech, .localModels),
                                               .settings(.speech, .provider(provider)),
                                               .settings(.speech, .asrBackend(.init(rawValue: "service:fixture"))),
                                               .settings(.speech, .asrBackend(.init(rawValue: "future:unknown")))] {
            var recovery = ErrorRecoveryContext(failedStage: "ASR", error: CloudASRError.noAPIKey,
                rawText: nil, retryable: false, failureKind: .configuration(.credentials))
            recovery.destination = destination
            var requests: [ClientDestination] = []
            var legacyCalls = 0
            let effects = RecoveryEffects(openAccessibilitySettings: {}, openMicrophoneSettings: {},
                openSpeechRecognitionSettings: {}, openASRSettings: { legacyCalls += 1 }, openHistory: {},
                copyText: { _ in }, openDestination: { requests.append($0); navigation.navigate(to: $0) })
            let controller = SessionController(pipeline: [FailureStage(recovery: recovery)], observers: [],
                effects: .init(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in }),
                recoveryEffects: effects, configurationStore: store, refreshReadiness: { .ready },
                readinessLevel: { .ready }, resources: SessionResourceCoordinator())
            controller.startRecording()
            for _ in 0..<100 where controller.recoveryCard == nil { try? await Task.sleep(for: .milliseconds(2)) }
            guard let card = controller.recoveryCard else { r.check(false, "recovery card available"); continue }
            var changed = store.current
            changed.cloudASRConfig.providers = [CloudASRVendor.makeProfile(.openAI, isActive: true)]
            store.save(changed)
            controller.performRecoveryAction(.openASRSettings, cardID: card.id)
            let firstID = navigation.request?.id
            controller.performRecoveryAction(.openASRSettings, cardID: card.id)
            r.eq(requests, [destination, destination], "recovery opens captured destination twice despite later provider edit")
            r.check(navigation.request?.id != firstID, "recovery repeated destination publishes new request identity")
            r.eq(legacyCalls, 0, "recovery uses precise navigation when supplied")
            r.check(!controller.errorActions.contains(.retry(stage: "ASR")), "configuration error never retries audio")
            controller.startRecording()
            for _ in 0..<100 where controller.recoveryCard?.id == card.id || controller.recoveryCard == nil {
                try? await Task.sleep(for: .milliseconds(2))
            }
            let newCard = controller.recoveryCard
            controller.performRecoveryAction(.openASRSettings, cardID: card.id)
            r.eq(requests.count, 2, "old recovery card cannot navigate a newer session")
            r.eq(controller.recoveryCard, newCard, "old recovery card leaves newer session untouched")
            controller.cancel()
            controller.performRecoveryAction(.openASRSettings, cardID: card.id)
            r.eq(requests.count, 2, "cleared recovery card cannot navigate")
        }
        var permissionActions: [String] = []
        let explicitEffects = RecoveryEffects(openAccessibilitySettings: { permissionActions.append("AX") },
            openMicrophoneSettings: { permissionActions.append("mic") },
            openSpeechRecognitionSettings: { permissionActions.append("speech") },
            openASRSettings: {}, openHistory: {}, copyText: { _ in }, openDestination: { _ in permissionActions.append("internal") })
        for (permission, action): (PermissionKind, RecoveryAction) in [(.accessibility, .openAccessibilitySettings),
            (.microphone, .openMicrophoneSettings), (.speechRecognition, .openSpeechRecognitionSettings)] {
            let recovery = ErrorRecoveryContext(failedStage: "Recording", error: CloudASRError.noAPIKey,
                rawText: nil, retryable: false, failureKind: .permission(permission))
            let controller = SessionController(pipeline: [FailureStage(recovery: recovery)], observers: [],
                effects: .init(prepare: {}, showWindow: {}, hideWindow: {}, saveHistory: { _ in }),
                recoveryEffects: explicitEffects, configurationStore: store, refreshReadiness: { .ready },
                readinessLevel: { .ready }, resources: SessionResourceCoordinator())
            controller.startRecording()
            for _ in 0..<100 where controller.recoveryCard == nil { try? await Task.sleep(for: .milliseconds(2)) }
            if let card = controller.recoveryCard { controller.performRecoveryAction(action, cardID: card.id) }
            else { r.check(false, "permission recovery card available") }
            controller.cancel()
        }
        r.eq(permissionActions, ["AX", "mic", "speech"], "explicit permission recovery retains actual OS action closures")
        let uncertain = RecoveryPolicy.presentation(kind: .deliveryUncertain, resources: .init(stage: "Injection",
            hasAudio: true, textKind: .result, deliveryEventStarted: true, routingPolicy: .auto, hasHistory: true))
        r.eq(uncertain.actions, [.copyResult, .viewHistory, .dismiss], "uncertain delivery exposes history and never another send")
        for (audio, delivered, expected) in [(true, false, true), (false, false, false), (true, true, false)] {
            let transient = RecoveryPolicy.presentation(kind: .transientASR, resources: .init(stage: "ASR",
                hasAudio: audio, textKind: .none, deliveryEventStarted: delivered, routingPolicy: .auto, hasHistory: false))
            r.eq(transient.actions.contains(.retry(stage: "ASR")), expected, "retry remains gated by retained audio and delivery latch")
        }
        for maximum in [0, 1, 3, 4] {
            let label = HourDistributionChart.midpointLabel(maximum: maximum)
            r.eq(label, [0: "0", 1: "0.5", 3: "1.5", 4: "2"][maximum]!, "hour chart midpoint represents real odd maximum")
        }
        let profile = LLMProvider.defaultSiliconFlow(isActive: true)
        var draft = LLMProviderDraft(target: .new(profile.id), profile: profile)
        draft.profile.baseURL = "  https://example.invalid/v1/  \n"
        draft.profile.model = "  synthetic-model \n"
        draft.profile.name = "  Synthetic \n"
        let normalized = ProviderDraftCommit.normalizedLLMProfile(draft.profile)
        r.eq(normalized.baseURL, "https://example.invalid/v1", "LLM test trims and normalizes endpoint like Save")
        r.eq(normalized.model, "synthetic-model", "LLM test trims model like Save")
        var saved = Configuration(); saved.llmProviders = []
        do {
            try ProviderDraftCommit.apply(draft, to: &saved)
            r.eq(saved.llmProviders.first?.model, normalized.model, "LLM Test and Save use same normalized model")
            r.eq(saved.llmProviders.first?.baseURL, normalized.baseURL, "LLM Test and Save use same normalized endpoint")
        } catch { r.check(false, "normalized LLM draft saves: \(error)") }
    }
}
