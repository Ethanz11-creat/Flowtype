import Foundation

enum ReadinessPresentationSelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) {
        print("--- ReadinessPresentationSelfTests.multipleReadinessIssuesWithoutPrompt ---")
        let effects = ValidationEffects.live.snapshot
        let snapshot = ReadinessSnapshot(accessibility: .denied, microphone: .denied,
            speechRecognition: .notDetermined, localModel: .ready,
            cloudASR: .unavailable(reason: "未配置"), appleSpeech: .unavailable(reason: "未授权"), computedAt: Date())
        let level = classifyReadiness(snapshot)
        let presentation = ReadinessPresentation.make(snapshot: snapshot, level: level)
        r.check(level.isBlocked, "multipleReadinessIssuesWithoutPrompt: microphone denial blocks")
        r.check(presentation.details.contains(ReadinessIssue.microphoneDenied.reason), "multipleReadinessIssuesWithoutPrompt: microphone blocker visible")
        r.check(presentation.details.contains(ReadinessIssue.accessibilityMissing.reason), "multipleReadinessIssuesWithoutPrompt: AX menu/clipboard degradation also visible")
        r.check(presentation.destinations.contains(.settings(.privacy, .microphone)), "multipleReadinessIssuesWithoutPrompt: microphone destination")
        r.check(presentation.destinations.contains(.settings(.privacy, .accessibility)), "multipleReadinessIssuesWithoutPrompt: AX destination")
        r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "multipleReadinessIssuesWithoutPrompt: zero attempted effects")
        r.eq(ValidationEffects.live.snapshot.permitted, effects.permitted, "multipleReadinessIssuesWithoutPrompt: zero live effects")

        print("--- ReadinessPresentationSelfTests.localASRWithCloudPolishDisclosure ---")
        var config = Configuration()
        config.asrRoutingPolicy = .localOnly
        config.polishOnStop = true
        let before = config
        let privacy = SettingsPrivacyPresentation.make(config: config)
        r.eq(privacy.localPolishDisclosure, "已开启云端文本整理，转写文字仍会发送给整理服务", "localASRWithCloudPolishDisclosure: disclose text transmission")
        r.eq(config, before, "localASRWithCloudPolishDisclosure: keeps polish preference")
        config.polishOnStop = false
        r.check(SettingsPrivacyPresentation.make(config: config).localPolishDisclosure == nil, "localASRWithCloudPolishDisclosure: disabled polish has no disclosure")

        print("--- ReadinessPresentationSelfTests.contextDisablePreservesPreferences ---")
        config.cloudASRSendContext = true
        config.cloudPolishSendContext = true
        let preserved = config
        let disabled = SettingsPrivacyPresentation.make(config: config)
        r.check(!disabled.contextEnabled && !disabled.polishContextEnabled, "contextDisablePreservesPreferences: local-only disables parent and child")
        r.eq(config, preserved, "contextDisablePreservesPreferences: disabled values preserved")
        config.asrRoutingPolicy = .auto
        config.cloudASRSendContext = false
        let childDisabled = SettingsPrivacyPresentation.make(config: config)
        r.check(childDisabled.contextEnabled && !childDisabled.polishContextEnabled, "contextDisablePreservesPreferences: child depends on master")
        r.check(config.cloudPolishSendContext, "contextDisablePreservesPreferences: child preference remains on")
        let context = ForegroundContext(appName: "fixture", elementText: "fixture-context", url: nil, selectedText: nil)
        r.check(LLMService.allowedForegroundContext(context, config: config) == nil,
                "contextDisablePreservesPreferences: master blocks actual polish context")
        config.cloudASRSendContext = true
        config.asrRoutingPolicy = .localOnly
        r.check(LLMService.allowedForegroundContext(context, config: config) == nil,
                "contextDisablePreservesPreferences: local-only blocks actual polish context")
        contextWireContracts(r)

        print("--- ReadinessPresentationSelfTests.repeatedSettingsTarget ---")
        var location = SettingsLocation()
        let destination = ClientDestination.settings(.speech, .provider(UUID()))
        let first = NavigationRequest(id: UUID(), destination: destination)
        let second = NavigationRequest(id: UUID(), destination: destination)
        location.consume(first)
        r.eq(location.requestID, first.id, "repeatedSettingsTarget: preserves first scroll identity")
        location.consume(second)
        r.eq(location.requestID, second.id, "repeatedSettingsTarget: repeats target with new scroll identity")
        if case .settings(_, let target) = destination {
            r.eq(location.target, target, "repeatedSettingsTarget: keeps provider row target")
        }
        isolatedSettingsDependencies(r, snapshot: snapshot)
    }

    private static func contextWireContracts(_ r: SelfTest.Reporter) {
        do {
            let realtime = CloudASRVendor.makeProfile(.dashScope, isActive: false)
            let wire = try ParaformerClientMessage.runTask(taskID: "fixture",
                configuration: RealtimeASRConfiguration(provider: realtime, apiKey: "fixture-key", language: nil)).encodedText()
            let json = try JSONSerialization.jsonObject(with: Data(wire.utf8)) as! [String: Any]
            let payload = json["payload"] as! [String: Any]
            let parameters = payload["parameters"] as! [String: Any]
            r.check(parameters["prompt"] == nil && parameters["context"] == nil,
                    "contextDisablePreservesPreferences: WSS wire has no prompt/context")
            r.eq((payload["input"] as? [String: Any])?.count, 0,
                 "contextDisablePreservesPreferences: WSS input carries no foreground text")
            let http = CloudASRVendor.makeProfile(.openAI, isActive: false)
            let request = try CloudTranscriptionRequestBuilder.make(configuration:
                CloudASRRequestConfiguration(provider: http, apiKey: "fixture-key", sendContext: false),
                samples: [0], language: nil, context: ASRContext(phrases: ["fixture-context"], foreground: "fixture-context"), timeout: 1)
            r.check(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("fixture-context"),
                    "contextDisablePreservesPreferences: HTTP master-off omits actual context")
        } catch { r.check(false, "contextDisablePreservesPreferences: wire fixtures failed: \(error)") }
    }

    @MainActor private static func isolatedSettingsDependencies(_ r: SelfTest.Reporter, snapshot: ReadinessSnapshot) {
        let suite = "flowtype.settings-presentation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(5, forKey: "flowtype.migrationVersion")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigurationStore(defaults: defaults)
        let original = store.current
        let effects = ValidationEffects.live.snapshot
        var refreshes = 0
        let monitor = ReadinessMonitor(snapshot: snapshot, refresh: { refreshes += 1; return snapshot })
        let navigation = SettingsNavigation()
        let checks = CloudASRConnectionCheck(recognitionTest: { _, _ in .success("fixture") })
        let drafts = CloudASRConnectionCheck(recognitionTest: { _, _ in .success("fixture") })
        let coordinator = LocalSettingsOwnershipSelfTests.coordinator(store: store)
        let downloader = ModelDownloader(coordinator: coordinator, configuration: { store.current })
        let importedActions = ImportedASRModelActions(coordinator: coordinator, configuration: { store.current })
        let page = SettingsPage(navigation: navigation, store: store,
            styleStore: StylePackStore(store: PersistentStore(filename: "settings-style-fixture.json",
                directory: RuntimeEnvironment.current.paths.applicationSupportDirectory)), monitor: monitor,
            modelState: coordinator, downloader: downloader, importedActions: importedActions,
            trialPresenter: TrialSessionPresenter(configuration: store, resources: SessionResourceCoordinator(),
                refreshReadiness: { monitor.rawLevel }, readinessLevel: { monitor.rawLevel }, copy: { _ in }),
            checks: checks, draftChecks: drafts)
        let asr = ASRSettingsContent(store: store, monitor: monitor, modelState: coordinator,
            downloader: downloader, importedActions: importedActions, navigation: navigation,
            checks: checks, draftChecks: drafts, devices: { [] })
        let permissions = PermissionSettingsContent(store: store, monitor: monitor, navigation: navigation,
            openMicrophoneSettings: {}, openAccessibilitySettings: {}, openSpeechSettings: {})
        _ = permissions.body
        r.eq(refreshes, 0, "isolatedSettingsDependencies: constructing/viewing permissions does not refresh or prompt")
        monitor.refresh()
        r.eq(refreshes, 1, "isolatedSettingsDependencies: refresh uses explicit source")
        r.check(page.store === store && asr.store === store && permissions.store === store,
                "isolatedSettingsDependencies: all surfaces retain injected store")
        r.check(asr.checks === checks && asr.draftChecks === drafts,
                "isolatedSettingsDependencies: reusable ASR uses stable checks")
        r.eq(store.current, original, "isolatedSettingsDependencies: no configuration mutations")
        r.check(defaults.data(forKey: "flowtype.config") == nil, "isolatedSettingsDependencies: no implicit save")
        r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "isolatedSettingsDependencies: zero attempted system effects")
        r.eq(ValidationEffects.live.snapshot.permitted, effects.permitted, "isolatedSettingsDependencies: zero live system effects")
        let first = LLMProvider.defaultSiliconFlow(isActive: true)
        let second = LLMProvider.defaultSiliconFlow(isActive: false)
        store.current.llmProviders = [first, second]
        store.current.providerAPIKeys = [first.id.uuidString: "fixture-first", second.id.uuidString: "fixture-second"]
        page.deleteProvider(first.id)
        r.eq(store.current.llmProviders.map(\.id), [second.id], "isolatedSettingsDependencies: delete targets injected provider UUID")
        r.check(store.current.llmProviders[0].isActive, "isolatedSettingsDependencies: delete activates remaining profile atomically")
        r.check(store.current.providerAPIKeys[first.id.uuidString] == nil && store.current.providerAPIKeys[second.id.uuidString] != nil,
                "isolatedSettingsDependencies: delete removes only matching injected key")
    }
}
