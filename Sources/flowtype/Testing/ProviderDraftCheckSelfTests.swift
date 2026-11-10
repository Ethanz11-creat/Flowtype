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
        lazyDraftConfigurationKey(r)
        let effects = ValidationEffects.live.snapshot
        print("--- ProviderDraftCheckSelfTests.lateDraftCheckCannotPublish ---")
        await lateDraftCheckCannotPublish(r)
        await recreatedSettingsCompositionRetainsTransport(r)
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

    private static func lazyDraftConfigurationKey(_ r: SelfTest.Reporter) {
        for isNew in [true, false] {
            for edit: APIKeyEdit in [.replace(" exact-key "), .remove, .preserve, .replace("  \n")] {
                var value = draft()
                value.target = isNew ? .new(value.profile.id) : .existing(value.profile.id)
                value.keyEdit = edit
                let checks = CloudASRConnectionCheck()
                let session = ASRProviderDraftSession(draft: value, checks: checks)
                var reads = 0
                let needsStored: Bool
                switch edit {
                case .preserve: needsStored = !isNew
                case .replace(let key): needsStored = !isNew && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .remove: needsStored = false
                }
                do {
                    try session.checkConfiguration(storedKey: { reads += 1; throw ASRCredentialError.unavailable })
                    r.check(!needsStored, "M1 existing preserve propagates lookup failure")
                    if case .replace(let key) = edit, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        r.eq(checks.state(for: value.target.id), .configurationValid, "M1 replacement checks without saved profile/key")
                    } else {
                        if case .failure = checks.state(for: value.target.id) {
                            r.check(true, "M1 removed or new empty key produces a configuration failure")
                        } else { r.check(false, "M1 empty key must still run local configuration validation") }
                    }
                } catch {
                    r.check(needsStored && (error as? ASRCredentialError) == .unavailable,
                            "M1 only existing preserve may read and propagate unavailable key")
                }
                r.eq(reads, needsStored ? 1 : 0, "M1 draft intent lazily determines saved-key access")
                if needsStored {
                    session.checkConfiguration(storedKey: { reads += 1; return "saved-key" })
                    r.eq(reads, 2, "M1 existing preserve reads available storage exactly once per check")
                    r.eq(checks.state(for: value.target.id), .configurationValid, "M1 preserve and blank replacement use saved key")
                }
            }
        }
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
        if var tested = transport.snapshots.first?.0, let saved = config.cloudASRConfig.providers.first {
            r.check(saved.revision != tested.revision, "checkDoesNotCommit: saving changed call fields rotates revision")
            tested.revision = saved.revision
            r.eq(tested, saved, "checkDoesNotCommit: tested normalized fields match saved profile")
        } else { r.check(false, "checkDoesNotCommit: tested and saved profiles exist") }
        session.detach()
        r.eq(checks.state(for: value.target.id), .idle, "checkDoesNotCommit: save cleanup invalidates success")
        session.draft.keyEdit = .replace(" replacement ")
        let replacement = session.testRecognition(storedKey: "current-key")
        await settle()
        r.eq(transport.snapshots.last?.1, " replacement ", "checkDoesNotCommit: replacement key tested without commit")
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
    private static func recreatedSettingsCompositionRetainsTransport(_ r: SelfTest.Reporter) async {
        let suite = "flowtype.recreated-settings.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigurationStore(defaults: defaults)
        let original = draft()
        var configuration = store.current
        configuration.cloudASRConfig = .init(providers: [original.profile])
        store.current = configuration
        let transport = Transport()
        let owners = SettingsConnectionChecks(configuration: store,
            checks: CloudASRConnectionCheck(recognitionTest: { profile, key in await transport.send(profile, key) }),
            draftChecks: CloudASRConnectionCheck(recognitionTest: { profile, key in await transport.send(profile, key) }))
        let snapshot = ReadinessSnapshot(accessibility: .granted, microphone: .granted,
            speechRecognition: .denied, localModel: .ready, cloudASR: .unavailable(reason: "fixture"),
            appleSpeech: .unavailable(reason: "fixture"), computedAt: Date())
        let monitor = ReadinessMonitor(snapshot: snapshot, refresh: { snapshot })
        let coordinator = LocalSettingsOwnershipSelfTests.coordinator(store: store)
        let downloader = ModelDownloader(coordinator: coordinator, configuration: { store.current })
        let actions = ImportedASRModelActions(coordinator: coordinator, configuration: { store.current })
        let styles = StylePackStore(store: PersistentStore(filename: "recreated-settings-style.json",
            directory: RuntimeEnvironment.current.paths.applicationSupportDirectory))
        let buildPage: MainWindowView.SettingsPageFactory = { navigation, connectionChecks in
            SettingsPage(navigation: navigation, store: store, styleStore: styles, monitor: monitor,
                modelState: coordinator, downloader: downloader, importedActions: actions,
                trialPresenter: TrialSessionPresenter(configuration: store, resources: SessionResourceCoordinator(),
                    refreshReadiness: { .ready }, readinessLevel: { .ready }, copy: { _ in }),
                connectionChecks: connectionChecks, devices: { [] })
        }
        // This is the same root constructor used by the production window. Only
        // app-lifetime dependencies and leaf service construction are injected.
        var root: MainWindowView? = SettingsWindowController.makeRootView(initialTab: .settings,
            navigation: SettingsNavigation(initialTab: .settings), connectionChecks: owners, settingsPage: buildPage)
        var page: SettingsPage? = root!.makeSettingsPage()
        guard page!.checks === owners.checks, page!.draftChecks === owners.draftChecks else {
            r.check(false, "settings recreation: production handoff must preserve explicit isolated dependencies")
            return
        }
        var session: ASRProviderDraftSession? = ASRProviderDraftSession(draft: original, checks: page!.draftChecks)
        let first = session!.testRecognition(storedKey: "fixture-key")
        await settle()
        r.eq(transport.snapshots.count, 1, "settings recreation: initial draft transport entered")
        session!.discard()
        session = nil
        page = nil
        let tabReturn = root!.makeSettingsPage()
        r.check(tabReturn.draftChecks.isTesting(original.target.id), "settings recreation: tab return sees draining reservation")
        r.check(tabReturn.draftChecks.testRecognition(provider: original.profile, apiKey: "fixture-key") == nil,
                "settings recreation: tab return cannot duplicate old request")
        root = nil
        let reopenedRoot = SettingsWindowController.makeRootView(initialTab: .settings,
            navigation: SettingsNavigation(initialTab: .settings), connectionChecks: owners, settingsPage: buildPage)
        let reopenedPage = reopenedRoot.makeSettingsPage()
        let reopened = ASRProviderDraftSession(draft: original, checks: reopenedPage.draftChecks)
        r.check(reopened.testRecognition(storedKey: "fixture-key") == nil,
                "settings recreation: recreated window cannot duplicate old request")
        transport.finish()
        await first?.value
        r.eq(reopenedPage.draftChecks.state(for: original.target.id), .idle,
             "settings recreation: late cancelled result cannot publish into new page")
        r.eq(store.current, configuration, "settings recreation: late completion never saves or activates profile")
        let second = reopened.testRecognition(storedKey: "fixture-key")
        await settle()
        r.eq(transport.snapshots.count, 2, "settings recreation: explicit test after drain enters transport")
        transport.finish()
        await second?.value
        r.eq(reopenedPage.draftChecks.state(for: original.target.id), .connected,
             "settings recreation: current explicit test publishes")
        r.eq(reopenedPage.checks.state(for: original.target.id), .idle,
             "settings recreation: draft success never changes live conclusion")
        reopened.detach()
        // Retained owners must invalidate even while no SettingsPage is observing
        // configuration. A live and a draft conclusion keep separate revisions.
        owners.checks.checkConfiguration(provider: original.profile, apiKey: "fixture-key")
        let third = owners.draftChecks.testRecognition(provider: original.profile, apiKey: "fixture-key")
        await settle()
        store.current.cloudASRConfig.providers[0].model = "externally-edited-model"
        r.eq(owners.checks.state(for: original.target.id), .idle, "settings recreation: absent-page edit invalidates live result")
        r.eq(owners.draftChecks.state(for: original.target.id), .idle, "settings recreation: absent-page edit invalidates draft result")
        r.check(owners.draftChecks.isTesting(original.target.id), "settings recreation: external edit does not free transport")
        let editedConfiguration = store.current
        transport.finish()
        await third?.value
        r.eq(owners.draftChecks.state(for: original.target.id), .idle, "settings recreation: externally stale result cannot publish")
        r.eq(store.current, editedConfiguration, "settings recreation: late result cannot undo external configuration")
    }

}
