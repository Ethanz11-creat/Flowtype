import Foundation

@MainActor
enum ProviderDraftCheckSelfTests {
    /// Deliberately ignores cancellation until released, like a slow transport teardown.
    @MainActor private final class Transport {
        var snapshots: [(CloudASRProviderConfig, String)] = []
        var pending: [CheckedContinuation<Result<String, CloudASRError>, Never>] = []
        func send(_ profile: CloudASRProviderConfig, _ key: String) async -> Result<String, CloudASRError> {
            snapshots.append((profile, key))
            return await withCheckedContinuation { pending.append($0) }
        }
        func finish() { pending.removeFirst().resume(returning: .success("fixture")) }
    }

    static func run(_ r: SelfTest.Reporter) async {
        let effects = ValidationEffects.live.snapshot
        print("--- ProviderDraftCheckSelfTests.lateDraftCheckCannotPublish ---")
        await lateDraftCheckCannotPublish(r)
        print("--- ProviderDraftCheckSelfTests.checkDoesNotCommitOrActivate ---")
        await checkDoesNotCommitOrActivate(r)
        print("--- ProviderDraftCheckSelfTests.deletedDraftCheckCannotPublish ---")
        await deletedDraftCheckCannotPublish(r)
        print("--- ProviderDraftCheckSelfTests.wssHasConfigurationCheckOnly ---")
        wssHasConfigurationCheckOnly(r)
        print("--- ProviderDraftCheckSelfTests.draftNavigationRequiresDecision ---")
        draftNavigationRequiresDecision(r)
        r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "draftChecks: no attempted live effects")
        r.eq(ValidationEffects.live.snapshot.permitted, effects.permitted, "draftChecks: no live effects")
    }

    private static func draft(_ vendor: CloudASRVendorID = .openAI) -> ASRProviderDraft {
        let profile = CloudASRVendor.makeProfile(vendor, isActive: false)
        return ASRProviderDraft(target: .existing(profile.id), profile: profile)
    }

    private static func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private static func lateDraftCheckCannotPublish(_ r: SelfTest.Reporter) async {
        let transport = Transport()
        let checks = CloudASRConnectionCheck(recognitionTest: { profile, key in await transport.send(profile, key) })
        let original = draft()
        let first = ASRProviderDraftSession(draft: original, checks: checks)
        let a = first.testRecognition(storedKey: "fixture-key")
        await settle()
        r.eq(transport.snapshots.count, 1, "lateDraftCheck: A reached fake transport")
        first.draft.profile.model = "edited"
        r.eq(checks.state(for: original.target.id), .idle, "lateDraftCheck: editing invalidates immediately")
        first.discard()
        let reopened = ASRProviderDraftSession(draft: original, checks: checks)
        r.check(reopened.testRecognition(storedKey: "fixture-key") == nil, "lateDraftCheck: reopening retains old transport slot")
        r.check(checks.isTesting(original.target.id), "lateDraftCheck: cancellation keeps ownership until exit")
        transport.finish()
        await a?.value
        r.eq(checks.state(for: original.target.id), .idle, "lateDraftCheck: late A cannot publish into reopened sheet")
        let b = reopened.testRecognition(storedKey: "fixture-key")
        await settle()
        r.eq(transport.snapshots.count, 2, "lateDraftCheck: B starts after A exits")
        r.check(checks.isTesting(original.target.id), "lateDraftCheck: B owns slot")
        // Re-awaiting A cannot release B's slot.
        await a?.value
        r.check(checks.isTesting(original.target.id), "lateDraftCheck: old completion cannot release B")
        transport.finish()
        await b?.value
        r.eq(checks.state(for: original.target.id), .connected, "lateDraftCheck: current B publishes")
        reopened.detach()
        r.eq(checks.state(for: original.target.id), .idle, "lateDraftCheck: page dismissal clears result")
    }

    private static func checkDoesNotCommitOrActivate(_ r: SelfTest.Reporter) async {
        let transport = Transport()
        let checks = CloudASRConnectionCheck(recognitionTest: { profile, key in await transport.send(profile, key) })
        let live = CloudASRConnectionCheck(recognitionTest: { profile, key in await transport.send(profile, key) })
        var value = draft()
        value.profile.name = "  Draft service \n"
        value.profile.model = "  normalized-model \n"
        value.profile.baseURL = " https://example.invalid/v1 \n"
        var config = Configuration.default
        config.cloudASRConfig.providers = [value.profile]
        config.cloudASRConfig.providerAPIKeys = [value.target.id.uuidString: "current-key"]
        let original = config
        let session = ASRProviderDraftSession(draft: value, checks: checks)
        session.checkConfiguration(storedKey: "current-key")
        r.eq(checks.state(for: value.target.id), .configurationValid, "checkDoesNotCommit: local validation uses normalized values")
        r.eq(transport.snapshots.count, 0, "checkDoesNotCommit: configuration check performs zero transport calls")
        let task = session.testRecognition(storedKey: "current-key")
        await settle()
        r.eq(config, original, "checkDoesNotCommit: testing does not save or activate")
        r.eq(transport.snapshots.first?.1, "current-key", "checkDoesNotCommit: preserve captures current key")
        transport.finish()
        await task?.value
        r.eq(live.state(for: value.target.id), .idle, "checkDoesNotCommit: draft success never becomes live success")
        try? ProviderDraftCommit.apply(session.draft, to: &config)
        r.eq(transport.snapshots.first?.0, config.cloudASRConfig.providers.first, "checkDoesNotCommit: tested normalized snapshot matches saved profile")
        session.detach()
        r.eq(checks.state(for: value.target.id), .idle, "checkDoesNotCommit: save cleanup invalidates success")
        session.draft.keyEdit = .replace("replacement")
        let replacement = session.testRecognition(storedKey: "current-key")
        await settle()
        r.eq(transport.snapshots.last?.1, "replacement", "checkDoesNotCommit: replacement key tested without commit")
        session.draft.keyEdit = .remove
        transport.finish()
        await replacement?.value
        session.checkConfiguration(storedKey: "current-key")
        if case .failure = checks.state(for: value.target.id) {
            r.check(true, "checkDoesNotCommit: explicit key removal fails local validation")
        } else { r.check(false, "checkDoesNotCommit: explicit key removal fails local validation") }
        r.eq(original.cloudASRConfig.providerAPIKeys[value.target.id.uuidString], "current-key", "checkDoesNotCommit: checks leave stored key untouched")
    }

    private static func wssHasConfigurationCheckOnly(_ r: SelfTest.Reporter) {
        let transport = Transport()
        let checks = CloudASRConnectionCheck(recognitionTest: { profile, key in await transport.send(profile, key) })
        let session = ASRProviderDraftSession(draft: draft(.dashScope), checks: checks)
        r.check(!session.canTestRecognition, "wssCheck: no HTTP recognition action")
        r.check(session.testRecognition(storedKey: "fixture-key") == nil, "wssCheck: direct test is local only")
        r.eq(checks.state(for: session.draft.target.id), .configurationValid, "wssCheck: valid is distinct from connected")
        r.eq(transport.snapshots.count, 0, "wssCheck: no HTTP or WSS calls")
    }

    private static func deletedDraftCheckCannotPublish(_ r: SelfTest.Reporter) async {
        let transport = Transport()
        let checks = CloudASRConnectionCheck(recognitionTest: { profile, key in await transport.send(profile, key) })
        let live = CloudASRConnectionCheck(recognitionTest: { profile, key in await transport.send(profile, key) })
        let value = draft()
        var config = Configuration.default
        config.cloudASRConfig = CloudASRConfig(providers: [value.profile])
        live.checkConfiguration(provider: value.profile, apiKey: "fixture-key")
        let session = ASRProviderDraftSession(draft: value, checks: checks)
        let task = session.testRecognition(storedKey: "fixture-key")
        await settle()
        r.eq(live.state(for: value.target.id), .configurationValid, "deletedDraftCheck: draft test leaves live validation independent")
        let before = config.cloudASRConfig
        live.deleteProfile(value.target.id, in: &config.cloudASRConfig)
        checks.synchronize(old: before, new: config.cloudASRConfig)
        r.eq(live.state(for: value.target.id), .idle, "deletedDraftCheck: deletion invalidates live result")
        r.eq(checks.state(for: value.target.id), .idle, "deletedDraftCheck: deletion invalidates draft result")
        r.check(checks.isTesting(value.target.id), "deletedDraftCheck: deleted request retains its slot until exit")
        transport.finish()
        await task?.value
        r.eq(checks.state(for: value.target.id), .idle, "deletedDraftCheck: deleted request cannot publish late success")
        r.check(!checks.isTesting(value.target.id), "deletedDraftCheck: exiting owner releases slot")
        let deletedConfig = config
        do {
            try ProviderDraftCommit.apply(session.draft, to: &config)
            r.check(false, "deletedDraftCheck: deleted draft cannot be saved")
        } catch {
            r.eq(error as? ProviderDraftCommitError, .deleted, "deletedDraftCheck: deleted draft cannot be saved")
        }
        r.eq(config, deletedConfig, "deletedDraftCheck: late save cannot resurrect deleted service")
    }

    private static func draftNavigationRequiresDecision(_ r: SelfTest.Reporter) {
        let checks = CloudASRConnectionCheck(recognitionTest: { _, _ in .success("fixture") })
        let session = ASRProviderDraftSession(draft: draft(), checks: checks)
        let navigation = SettingsNavigation(initialTab: .settings)
        var closes = 0
        session.attach(to: navigation) { closes += 1 }
        session.draft.profile.model = "modified"
        session.requestCancel()
        r.check(session.isConfirmingDiscard, "asrNavigation: Cancel/Escape asks before discarding")
        session.keepEditing()
        navigation.navigate(to: .history("record"))
        let request = session.pendingNavigation
        r.eq(navigation.requestedTab, .settings, "asrNavigation: external navigation deferred")
        r.eq(closes, 0, "asrNavigation: deferred navigation keeps editor")
        session.discard()
        r.eq(navigation.request?.id, request?.id, "asrNavigation: discard resumes exact request")
        r.eq(closes, 1, "asrNavigation: discard closes once")
        let newer = ASRProviderDraftSession(draft: draft(), checks: checks)
        newer.attach(to: navigation) { closes += 1 }
        newer.draft.profile.model = "newer edit"
        session.detach()
        navigation.requestedTab = .style
        r.check(newer.isConfirmingDiscard, "asrNavigation: stale detach cannot remove new guard")
        r.eq(navigation.requestedTab, .history, "asrNavigation: legacy tab setter respects new guard")
        newer.keepEditing()
        r.eq(newer.draft.profile.model, "newer edit", "asrNavigation: keep editing retains draft")
        newer.detach()
    }
}
