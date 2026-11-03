import Foundation

/// Value-only fixtures: no store, credentials, permissions, audio, or transport access.
@MainActor
enum ProviderDraftSelfTests {
    static func run(_ r: SelfTest.Reporter) {
        let effectsBefore = ValidationEffects.live.snapshot
        print("--- ProviderDraftSelfTests.dirtyDraftNavigationRequiresDecision ---")
        dirtyDraftNavigationRequiresDecision(r)
        print("--- ProviderDraftSelfTests.cleanDraftNavigationAndDetach ---")
        cleanDraftNavigationAndDetach(r)
        print("--- ProviderDraftSelfTests.deletedDraftCannotResurrect ---")
        deletedDraftCannotResurrect(r)
        print("--- ProviderDraftSelfTests.mergePreservesConcurrentSettings ---")
        mergePreservesConcurrentSettings(r)
        print("--- ProviderDraftSelfTests.blankKeyPreservesAndRemovalIsExplicit ---")
        blankKeyPreservesAndRemovalIsExplicit(r)
        print("--- ProviderDraftSelfTests.vendorChangePreservesFields ---")
        vendorChangePreservesFields(r)
        print("--- ProviderDraftSelfTests.cancellationDoesNotMutate ---")
        cancellationDoesNotMutate(r)
        print("--- ProviderDraftSelfTests.invalidCommitIsAtomic ---")
        invalidCommitIsAtomic(r)
        r.eq(ValidationEffects.live.snapshot.blocked, effectsBefore.blocked,
             "providerDraftActions: no implicit transport, audio, permissions, clipboard or keychain attempts")
        r.eq(ValidationEffects.live.snapshot.permitted, effectsBefore.permitted,
             "providerDraftActions: no live service effects")
    }

    // Catches external/legacy navigation bypassing the modified-sheet close decision.
    private static func dirtyDraftNavigationRequiresDecision(_ r: SelfTest.Reporter) {
        let config = fixture()
        let before = config
        let profile = config.llmProviders[0]
        let session = LLMProviderDraftSession(draft: LLMProviderDraft(target: .existing(profile.id), profile: profile))
        let navigation = SettingsNavigation(initialTab: .settings)
        var closes = 0
        session.attach(to: navigation) { closes += 1 }
        session.draft.profile.model = "unsaved edit"
        navigation.navigate(to: .history("original-record"))
        let originalRequest = session.pendingNavigation
        r.eq(navigation.requestedTab, .settings, "dirtyDraftNavigation: does not leave settings")
        r.check(navigation.request == nil, "dirtyDraftNavigation: does not publish destination prematurely")
        r.eq(originalRequest?.destination, .history("original-record"), "dirtyDraftNavigation: retains exact destination")
        r.check(session.isConfirmingDiscard, "dirtyDraftNavigation: asks to keep or discard")
        session.keepEditing()
        r.eq(session.draft.profile.model, "unsaved edit", "dirtyDraftNavigation: keep retains draft")
        r.check(session.pendingNavigation == nil && !session.isConfirmingDiscard, "dirtyDraftNavigation: keep clears pending close")
        r.eq(closes, 0, "dirtyDraftNavigation: keep leaves sheet open")
        r.eq(config, before, "dirtyDraftNavigation: keep does not change configuration")
        session.requestCancel()
        r.check(session.isConfirmingDiscard, "dirtyDraftNavigation: Cancel also requires decision")
        session.keepEditing()
        // Public legacy tab assignment must also defer and restore the current tab.
        navigation.requestedTab = .style
        let continuedRequest = session.pendingNavigation
        r.eq(navigation.requestedTab, .settings, "dirtyDraftNavigation: legacy setter defers")
        session.discard()
        r.eq(navigation.request?.id, continuedRequest?.id, "dirtyDraftNavigation: discard preserves request identity")
        r.eq(navigation.request?.destination, .tab(.style), "dirtyDraftNavigation: discard reaches original destination")
        r.eq(closes, 1, "dirtyDraftNavigation: discard closes once")
        r.eq(config, before, "dirtyDraftNavigation: discard does not save")
        navigation.navigate(to: .tab(.overview))
        r.eq(navigation.requestedTab, .overview, "dirtyDraftNavigation: closed editor does not block future requests")
    }

    private static func cleanDraftNavigationAndDetach(_ r: SelfTest.Reporter) {
        let profile = fixture().llmProviders[0]
        let session = LLMProviderDraftSession(draft: LLMProviderDraft(target: .existing(profile.id), profile: profile))
        let navigation = SettingsNavigation(initialTab: .settings)
        var closes = 0
        session.attach(to: navigation) { closes += 1 }
        navigation.navigate(to: .history(nil))
        r.eq(navigation.requestedTab, .history, "cleanDraftNavigation: clean sheet permits navigation")
        r.eq(closes, 1, "cleanDraftNavigation: clean sheet closes")
        r.check(!session.isConfirmingDiscard, "cleanDraftNavigation: no unnecessary confirmation")
        let second = LLMProviderDraftSession(draft: session.draft)
        var callbackOwner: NSObject? = NSObject()
        weak var retainedOwner = callbackOwner
        second.attach(to: navigation) { [callbackOwner] in
            withExtendedLifetime(callbackOwner) {}
            closes += 1
        }
        callbackOwner = nil
        r.check(retainedOwner != nil, "cleanDraftNavigation: attached close callback owns its capture")
        second.draft.profile.model = "changed"
        session.detach() // A stale editor cleanup must not unregister the newer editor.
        navigation.navigate(to: .tab(.settings))
        r.check(second.isConfirmingDiscard, "cleanDraftNavigation: stale detach retains new guard")
        second.detach()
        r.check(retainedOwner == nil, "cleanDraftNavigation: page close releases callback captures")
        navigation.navigate(to: .tab(.vocab))
        r.eq(navigation.requestedTab, .vocab, "cleanDraftNavigation: page close unregisters guard")
        r.eq(closes, 1, "cleanDraftNavigation: detached callback is not retained or called")
    }

    private static func fixture() -> Configuration {
        var config = Configuration.default
        config.llmProviders = [.defaultSiliconFlow()]
        config.cloudASRConfig = CloudASRConfig(providers: [.defaultSiliconFlow()])
        config.providerAPIKeys = [config.llmProviders[0].id.uuidString: "llm-fixture"]
        config.cloudASRConfig.providerAPIKeys = [config.cloudASRConfig.providers[0].id.uuidString: "asr-fixture"]
        return config
    }

    // Catches late saves recreating deleted profiles (including a key-only resurrection).
    private static func deletedDraftCannotResurrect(_ r: SelfTest.Reporter) {
        var config = fixture()
        let llm = LLMProviderDraft(target: .existing(config.llmProviders[0].id), profile: config.llmProviders[0], keyEdit: .replace("late"))
        let asr = ASRProviderDraft(target: .existing(config.cloudASRConfig.providers[0].id), profile: config.cloudASRConfig.providers[0], keyEdit: .replace("late"))
        config.llmProviders = []
        config.cloudASRConfig.providers = []
        let before = config
        do { try ProviderDraftCommit.apply(llm, to: &config); r.check(false, "deletedDraftCannotResurrect: LLM rejects") }
        catch { r.eq(error as? ProviderDraftCommitError, .deleted, "deletedDraftCannotResurrect: LLM deleted error") }
        do { try ProviderDraftCommit.apply(asr, to: &config); r.check(false, "deletedDraftCannotResurrect: ASR rejects") }
        catch { r.eq(error as? ProviderDraftCommitError, .deleted, "deletedDraftCannotResurrect: ASR deleted error") }
        r.eq(config, before, "deletedDraftCannotResurrect: no profile or key resurrection")
    }

    // Catches stale array/config replacement and stale isActive values overwriting a later choice.
    private static func mergePreservesConcurrentSettings(_ r: SelfTest.Reporter) {
        var config = fixture()
        var llm = LLMProviderDraft(target: .existing(config.llmProviders[0].id), profile: config.llmProviders[0])
        var asr = ASRProviderDraft(target: .existing(config.cloudASRConfig.providers[0].id), profile: config.cloudASRConfig.providers[0])
        llm.profile.model = "edited-llm"
        asr.profile.model = "edited-asr"
        var otherLLM = LLMProvider.defaultSiliconFlow(isActive: true)
        var otherASR = CloudASRProviderConfig.defaultSiliconFlow(isActive: true)
        otherLLM.name = "Concurrent LLM"
        otherASR.name = "Concurrent ASR"
        config.llmProviders[0].isActive = false
        config.cloudASRConfig.providers[0].isActive = false
        config.llmProviders.insert(otherLLM, at: 0)
        config.cloudASRConfig.providers.insert(otherASR, at: 0)
        config.appearancePreference = .dark
        config.systemPrompt = "concurrent prompt"
        config.providerAPIKeys[llm.id.uuidString] = "latest-llm"
        config.cloudASRConfig.providerAPIKeys[asr.target.id.uuidString] = "latest-asr"
        do {
            try ProviderDraftCommit.apply(llm, to: &config)
            try ProviderDraftCommit.apply(asr, to: &config)
            r.eq(config.llmProviders.map(\.model), [otherLLM.model, "edited-llm"], "mergePreservesConcurrentSettings: LLM merges by UUID")
            r.eq(config.cloudASRConfig.providers.map(\.model), [otherASR.model, "edited-asr"], "mergePreservesConcurrentSettings: ASR merges by UUID")
            r.eq(config.llmProviders.filter(\.isActive).map(\.id), [otherLLM.id], "mergePreservesConcurrentSettings: latest LLM selection")
            r.eq(config.cloudASRConfig.providers.filter(\.isActive).map(\.id), [otherASR.id], "mergePreservesConcurrentSettings: latest ASR selection")
            r.eq(config.providerAPIKeys[llm.id.uuidString], "latest-llm", "mergePreservesConcurrentSettings: preserve latest LLM key")
            r.eq(config.cloudASRConfig.providerAPIKeys[asr.target.id.uuidString], "latest-asr", "mergePreservesConcurrentSettings: preserve latest ASR key")
            r.eq(config.appearancePreference, .dark, "mergePreservesConcurrentSettings: appearance retained")
            r.eq(config.systemPrompt, "concurrent prompt", "mergePreservesConcurrentSettings: prompt retained")
        } catch { r.check(false, "mergePreservesConcurrentSettings: unexpected error") }
    }

    // Catches blank replacement deleting secrets or an ASR edit touching the LLM key namespace.
    private static func blankKeyPreservesAndRemovalIsExplicit(_ r: SelfTest.Reporter) {
        var config = fixture()
        let p = config.llmProviders[0]
        let a = config.cloudASRConfig.providers[0]
        do {
            try ProviderDraftCommit.apply(LLMProviderDraft(target: .existing(p.id), profile: p, keyEdit: .replace(" \n")), to: &config)
            try ProviderDraftCommit.apply(ASRProviderDraft(target: .existing(a.id), profile: a, keyEdit: .replace("")), to: &config)
            r.eq(config.providerAPIKeys[p.id.uuidString], "llm-fixture", "blankKeyPreservesAndRemovalIsExplicit: blank LLM preserves")
            r.eq(config.cloudASRConfig.providerAPIKeys[a.id.uuidString], "asr-fixture", "blankKeyPreservesAndRemovalIsExplicit: blank ASR preserves")
            try ProviderDraftCommit.apply(ASRProviderDraft(target: .existing(a.id), profile: a, keyEdit: .replace("asr-replaced")), to: &config)
            r.eq(config.providerAPIKeys[p.id.uuidString], "llm-fixture", "blankKeyPreservesAndRemovalIsExplicit: ASR cannot touch LLM")
            r.eq(config.cloudASRConfig.providerAPIKeys[a.id.uuidString], "asr-replaced", "blankKeyPreservesAndRemovalIsExplicit: ASR replaces")
            try ProviderDraftCommit.apply(LLMProviderDraft(target: .existing(p.id), profile: p, keyEdit: .remove), to: &config)
            r.check(config.providerAPIKeys[p.id.uuidString] == nil, "blankKeyPreservesAndRemovalIsExplicit: explicit LLM removal")
            try ProviderDraftCommit.apply(ASRProviderDraft(target: .existing(a.id), profile: a, keyEdit: .remove), to: &config)
            r.check(config.cloudASRConfig.providerAPIKeys[a.id.uuidString] == nil, "blankKeyPreservesAndRemovalIsExplicit: explicit ASR removal")
        } catch { r.check(false, "blankKeyPreservesAndRemovalIsExplicit: unexpected error") }
    }

    // Catches preset application on ordinary vendor changes and key resets on explicit defaults.
    private static func vendorChangePreservesFields(_ r: SelfTest.Reporter) {
        let config = fixture()
        var llm = LLMProviderDraft(target: .existing(config.llmProviders[0].id), profile: config.llmProviders[0], keyEdit: .replace("staged"))
        var asr = ASRProviderDraft(target: .existing(config.cloudASRConfig.providers[0].id), profile: config.cloudASRConfig.providers[0], keyEdit: .replace("staged"))
        llm.profile.baseURL = "https://proxy.invalid/v1"; llm.profile.model = "custom-model"
        asr.profile.baseURL = "https://proxy.invalid/v1"; asr.profile.model = "custom-model"
        llm.selectVendor("OpenAI")
        asr.selectVendor(.openAI)
        r.eq(llm.profile.baseURL, "https://proxy.invalid/v1", "vendorChangePreservesFields: LLM URL preserved")
        r.eq(llm.profile.model, "custom-model", "vendorChangePreservesFields: LLM model preserved")
        r.eq(asr.profile.baseURL, "https://proxy.invalid/v1", "vendorChangePreservesFields: ASR URL preserved")
        r.eq(asr.profile.model, "custom-model", "vendorChangePreservesFields: ASR model preserved")
        r.eq(llm.profile.provider, "OpenAI", "vendorChangePreservesFields: LLM vendor changed")
        r.eq(asr.profile.vendorID, .openAI, "vendorChangePreservesFields: ASR vendor changed")
        asr.selectVendor(.dashScope)
        r.eq(asr.profile.protocolKind, .openAICompatible, "vendorChangePreservesFields: protocol remains explicit")
        asr.selectVendor(.openAI)
        llm.useVendorDefaults(); asr.useVendorDefaults()
        r.eq(llm.profile.baseURL, "https://api.openai.com/v1", "vendorChangePreservesFields: explicit LLM defaults")
        r.eq(asr.profile.model, "whisper-1", "vendorChangePreservesFields: explicit ASR defaults")
        r.eq(llm.keyEdit, .replace("staged"), "vendorChangePreservesFields: LLM key preserved")
        r.eq(asr.keyEdit, .replace("staged"), "vendorChangePreservesFields: ASR key preserved")
    }

    private static func cancellationDoesNotMutate(_ r: SelfTest.Reporter) {
        let config = fixture()
        let before = config
        var llm = LLMProviderDraft(target: .existing(config.llmProviders[0].id), profile: config.llmProviders[0])
        var asr = ASRProviderDraft(target: .existing(config.cloudASRConfig.providers[0].id), profile: config.cloudASRConfig.providers[0])
        llm.profile.name = "discard"; llm.keyEdit = .remove
        asr.profile.name = "discard"; asr.keyEdit = .remove
        r.eq(config, before, "cancellationDoesNotMutate: discarding value drafts leaves whole config unchanged")
        r.check(llm.profile.name != config.llmProviders[0].name && asr.profile.name != config.cloudASRConfig.providers[0].name, "cancellationDoesNotMutate: edited drafts are independent")
    }

    // Catches validation after partial profile/key writes, UUID collisions, or missing first activation.
    private static func invalidCommitIsAtomic(_ r: SelfTest.Reporter) {
        var config = fixture()
        let p = config.llmProviders[0]
        let a = config.cloudASRConfig.providers[0]
        let before = config
        do { try ProviderDraftCommit.apply(LLMProviderDraft(target: .new(p.id), profile: p), to: &config); r.check(false, "invalidCommitIsAtomic: LLM collision") }
        catch { r.eq(error as? ProviderDraftCommitError, .conflict, "invalidCommitIsAtomic: LLM conflict error") }
        do { try ProviderDraftCommit.apply(ASRProviderDraft(target: .new(a.id), profile: a), to: &config); r.check(false, "invalidCommitIsAtomic: ASR collision") }
        catch { r.eq(error as? ProviderDraftCommitError, .conflict, "invalidCommitIsAtomic: ASR conflict error") }
        var invalid = ASRProviderDraft(target: .existing(a.id), profile: a, keyEdit: .remove)
        invalid.profile.baseURL = "http://invalid.example"
        do { try ProviderDraftCommit.apply(invalid, to: &config); r.check(false, "invalidCommitIsAtomic: rejects invalid URL") }
        catch { r.check(error is ProviderDraftCommitError, "invalidCommitIsAtomic: typed validation failure") }
        var invalidLLM = LLMProviderDraft(target: .existing(p.id), profile: p, keyEdit: .remove)
        invalidLLM.profile.model = " "
        do { try ProviderDraftCommit.apply(invalidLLM, to: &config); r.check(false, "invalidCommitIsAtomic: rejects invalid LLM model") }
        catch { r.check(error is ProviderDraftCommitError, "invalidCommitIsAtomic: LLM typed validation failure") }
        var wrongID = LLMProviderDraft(target: .existing(p.id), profile: .defaultSiliconFlow())
        wrongID.profile.name = "Different name"
        do { try ProviderDraftCommit.apply(wrongID, to: &config); r.check(false, "invalidCommitIsAtomic: rejects identity mismatch") }
        catch { r.check(error is ProviderDraftCommitError, "invalidCommitIsAtomic: identity typed failure") }
        var duplicate = LLMProviderDraft(target: .new(UUID()), profile: .defaultSiliconFlow())
        duplicate.target = .new(duplicate.profile.id)
        do { try ProviderDraftCommit.apply(duplicate, to: &config); r.check(false, "invalidCommitIsAtomic: rejects latest duplicate name") }
        catch { r.check(error is ProviderDraftCommitError, "invalidCommitIsAtomic: duplicate typed failure") }
        r.eq(config, before, "invalidCommitIsAtomic: failed transactions leave whole config unchanged")
        config.llmProviders = []; config.cloudASRConfig.providers = []
        do {
            var inactiveLLM = p
            var inactiveASR = a
            inactiveLLM.isActive = false; inactiveASR.isActive = false
            try ProviderDraftCommit.apply(LLMProviderDraft(target: .new(p.id), profile: inactiveLLM), to: &config)
            try ProviderDraftCommit.apply(ASRProviderDraft(target: .new(a.id), profile: inactiveASR), to: &config)
            r.eq(config.llmProviders.filter(\.isActive).count, 1, "invalidCommitIsAtomic: first LLM activated")
            r.eq(config.cloudASRConfig.providers.filter(\.isActive).count, 1, "invalidCommitIsAtomic: first ASR activated")
        } catch { r.check(false, "invalidCommitIsAtomic: first creation succeeds") }
    }
}
