import Foundation

enum ASRModelCenterSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        await testHonestStatusProjection(r)
        await testPrimarySelectionTransaction(r)
        await testPolicyConsentAndRemoval(r)
        await testNativePrimaryCommit(r)
        await testTrialDoesNotSelect(r)
        await testColdNativeFallback(r)
        await testCurrentEvidenceInvalidation(r)
        await testNativeRemovalAndMissingSample(r)
        await testManagedPresetActualIdentity(r)
        await testHistoryCallbackAndCompatibilityFlags(r)
        await testExplicitRequestGuardsAndUUIDDeselection(r)
        await testStaleAndDuplicateEffects(r)
        testInstallationAndHistoryProjection(r)
        await testDistinctPrimaryAdmission(r)
        await testCrossBackendAdmissionAndPreview(r)
        await testMutationsRemovalAndRetryAdmission(r)
    }

    @MainActor static func testDistinctPrimaryAdmission(_ r: SelfTest.Reporter) async {
        for finishSecondFirst in [false, true] {
            let f = ModelCenterFixture(), gate = ModelCenterRecognitionGate()
            var second = f.service; second.id = UUID(); second.revision = UUID(); second.name = "Second fixture service"
            f.config.localASRServices.append(second)
            let secondID = ASRBackendID(rawValue: "service:" + second.id.uuidString)
            f.recognitionOverride = { try await gate.recognize($0.id) }
            let vm = f.makeViewModel()
            let first = Task { await vm.selectPrimary(f.serviceID) }
            await gate.waitForCall(f.service.id)
            r.check(vm.isBusy, "C1 I1 accepted primary exposes busy state")
            var entered = false
            let overlap = Task { entered = true; await vm.selectPrimary(secondID) }
            await admissionTurns { entered }
            r.eq(gate.calls, [f.service.id], "C1 I1 distinct service overlap is rejected before transport in either completion order")
            r.check(vm.busyNotice != nil, "C1 I1 rejected overlap explains busy admission")
            if finishSecondFirst { gate.finish(second.id); gate.finish(f.service.id) }
            else { gate.finish(f.service.id); gate.finish(second.id) }
            await first.value; await overlap.value
            r.eq(f.config.asrBackendSelection?.primary, f.serviceID, "C1 I1 accepted primary alone commits in either completion order")
            r.check(!vm.isBusy, "C1 I1 completed primary releases admission")
            f.recognitionOverride = nil
            await vm.selectPrimary(secondID)
            r.eq(f.config.asrBackendSelection?.primary, secondID, "C1 I1 rejected primary can retry after accepted action finishes")
        }
    }

    @MainActor static func testCrossBackendAdmissionAndPreview(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(), gate = ModelCenterRecognitionGate()
        f.recognitionOverride = { try await gate.recognize($0.id) }
        let vm = f.makeViewModel()
        let service = Task { await vm.selectPrimary(f.serviceID) }
        await gate.waitForCall(f.service.id)
        await vm.selectPrimary(f.nativeID)
        r.eq(f.nativeLoads, 0, "C1 I1 pending service primary blocks native allocation")
        r.eq(f.nativePersists, 0, "C1 I1 pending service primary blocks native commit")
        gate.finish(f.service.id); await service.value
        r.eq(f.config.asrBackendSelection?.primary, f.serviceID, "C1 I1 rejected native action cannot defeat admitted service action")
        let g = ModelCenterFixture(); let gv = g.makeViewModel()
        await gv.test(g.cloudID)
        let preview = gv.lastTrialResult
        g.blockNativeLoad = true
        let native = Task { await gv.selectPrimary(g.nativeID) }
        await g.waitForNativeLoad()
        r.check(gv.isBusy, "C1 I1 native loading holds user admission")
        let priorNotice = gv.notice
        await gv.test(g.serviceID)
        await gv.selectPrimary(g.serviceID)
        r.eq(g.recognitions, 1, "C1 I1 pending native action blocks service recognition and primary work")
        r.eq(gv.lastTrialResult, preview, "C1 I1 rejected Test preserves the valid existing preview")
        r.eq(gv.notice, priorNotice, "C1 I1 busy rejection does not overwrite accepted-action notice")
        r.check(gv.busyNotice != nil, "C1 I1 native overlap has separate busy feedback")
        g.finishNativeLoad(); await native.value
        r.eq(g.config.asrBackendSelection?.primary, g.nativeID, "C1 I1 admitted native action alone commits actual native ID")
        await gv.test(g.serviceID)
        r.eq(gv.lastTrialResult?.backendID, g.serviceID, "C1 I1 later accepted Test owns new preview")
        r.check(!gv.isBusy && gv.busyNotice == nil, "C1 I1 retry clears busy feedback")
    }

    @MainActor static func testMutationsRemovalAndRetryAdmission(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(), gate = ModelCenterRecognitionGate()
        f.recognitionOverride = { try await gate.recognize($0.id) }
        let vm = f.makeViewModel()
        let first = Task { await vm.test(f.serviceID) }
        await gate.waitForCall(f.service.id)
        let selection = f.config.asrBackendSelection
        vm.changePolicy(.localOnly); vm.setAllowsCloudFallback(true); vm.deselect(f.cloudID)
        await vm.selectFallback(nil)
        await vm.remove(f.nativeID, deleteManagedFiles: false)
        r.eq(f.config.asrBackendSelection, selection, "C1 I1 busy sync mutations and fallback cannot alter selected roles/consent")
        r.eq(f.config.asrRoutingPolicy, .auto, "C1 I1 busy policy mutation is rejected")
        r.eq(f.centerPersists, 0, "C1 I1 conflicting mutations are rejected before persistence")
        r.check(f.config.importedASRModels.contains { $0.id == f.model.id }, "C1 I1 busy removal cannot delete native record")
        first.cancel()
        await vm.test(f.cloudID)
        r.eq(f.recognitions, 1, "C1 I1 cancelled but draining operation retains user admission")
        gate.finish(f.service.id); await first.value
        r.check(!vm.isBusy, "C1 I1 cancelled operation releases admission after domain completion")
        f.recognitionOverride = nil
        f.failRecognition = true
        await vm.test(f.serviceID)
        r.check(!vm.isBusy && vm.notice != nil, "C1 I1 failed Test releases admission with its own notice")
        f.failRecognition = false
        await vm.test(f.cloudID)
        r.eq(vm.lastTrialResult?.backendID, f.cloudID, "C1 I1 Test retry after cancellation and failure owns preview")
        r.eq(vm.notice, nil, "C1 I1 accepted successful retry clears prior action failure")
        let g = ModelCenterFixture(); let gv = g.makeViewModel()
        g.blockSnapshots = true
        let removal = Task { await gv.remove(g.serviceID, deleteManagedFiles: false) }
        await g.waitForSnapshots()
        r.check(gv.isBusy, "C1 I1 removal holds admission through awaited domain refresh")
        await gv.test(g.cloudID)
        r.eq(g.recognitions, 0, "C1 I1 pending removal rejects another Test before recognition")
        g.finishSnapshots(); await removal.value
        r.check(!gv.isBusy, "C1 I1 completed removal releases admission")
        await gv.test(g.cloudID)
        r.eq(g.recognitions, 1, "C1 I1 rejected Test can retry after removal")
    }

    @MainActor private static func admissionTurns(_ ready: () -> Bool) async {
        for _ in 0..<10_000 { if ready() { break }; await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor static func testHonestStatusProjection(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture()
        let vm = f.makeViewModel()
        r.eq(vm.rows.first { $0.id == f.nativeID }?.status, .installedUntested, "C1 installed static inspection is not loaded readiness")
        r.eq(vm.rows.first { $0.id == f.serviceID }?.subtitle, "由服务端决定 · 本机服务；服务自身可能联网", "C1 server-managed model and network boundary are honest")
        r.eq(f.recognitions, 0, "C1 rendering never uploads recognition audio")
        f.config.localASRServices.reverse(); vm.refresh()
        r.check(vm.rows.contains { $0.id == f.serviceID }, "C1 ordering preserves real backend ID")
        await vm.test(f.serviceID)
        r.eq(vm.rows.first { $0.id == f.serviceID }?.status, .ready, "C1 explicit real recognition supplies current evidence")
        f.date = Date().addingTimeInterval(61); vm.refresh()
        r.eq(vm.rows.first { $0.id == f.serviceID }?.status, .previouslyValidated, "C1 current service evidence expires after 60 seconds")
        let restarted = f.makeViewModel()
        r.eq(restarted.rows.first { $0.id == f.serviceID }?.status, .previouslyValidated, "C1 restart history never becomes current readiness")
        f.generation = UUID(); vm.refresh()
        r.eq(vm.rows.first { $0.id == f.serviceID }?.status, .installedUntested, "C1 credential edit invalidates matching recognition evidence")
    }

    @MainActor static func testPrimarySelectionTransaction(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(); let vm = f.makeViewModel()
        f.failRecognition = true
        await vm.selectPrimary(f.serviceID)
        r.eq(f.config.asrBackendSelection?.primary, f.cloudID, "C1 test failure leaves selection")
        r.check(vm.notice != nil, "C1 failed active test explains recovery")
        f.failRecognition = false
        await vm.selectPrimary(f.serviceID)
        r.eq(f.config.asrBackendSelection?.primary, f.serviceID, "C1 successful explicit trial selects exact ID")
        f.config.setASRBackendSelection(.init(primary: f.cloudID))
        f.persistFails = true
        await vm.selectPrimary(f.serviceID)
        r.eq(f.config.asrBackendSelection?.primary, f.cloudID, "C1 persistence failure leaves original selection")
        f.persistFails = false; f.editDuringRecognition = true
        await vm.selectPrimary(f.serviceID)
        r.eq(f.config.asrBackendSelection?.primary, f.cloudID, "C1 profile edit during recognition suppresses stale primary switch")
    }

    @MainActor static func testNativePrimaryCommit(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(); let vm = f.makeViewModel()
        await vm.selectPrimary(f.nativeID)
        r.eq(f.config.asrBackendSelection?.primary, f.nativeID, "C1 first native choice commits actual backend ID")
        r.eq(f.native.activeLease.map { ASRBackendID(nativeLease: $0) }, f.nativeID, "C1 native runtime and selected primary agree")
        r.eq(f.nativePersists, 1, "C1 native primary uses one B5 durable transaction")
        r.eq(f.centerPersists, 0, "C1 native selection never makes a second UI save")
        let failed = ModelCenterFixture(); let failedVM = failed.makeViewModel()
        failed.persistFails = true
        await failedVM.selectPrimary(failed.nativeID)
        r.eq(failed.config.asrBackendSelection?.primary, failed.cloudID, "C1 failed first native persistence preserves original cloud role")
        r.eq(failed.native.activeLease, nil, "C1 failed first native persistence never publishes runtime")
        failed.persistFails = false
        failed.config.setASRBackendSelection(.init(primary: failed.serviceID))
        await failedVM.selectPrimary(failed.nativeID)
        r.eq(failed.config.asrBackendSelection?.primary, failed.nativeID, "C1 service to native commits within B5")
        let conflict = ModelCenterFixture()
        conflict.config.asrRoutingPolicy = .cloudOnly
        do {
            _ = try await NativeASRActivationCoordinator(state: conflict.native).activate(modelID: conflict.model.id, sample: NativeActivationFixtures.sample(), selectionIntent: .primary)
            r.check(false, "C1 B5 shared policy rules reject cloud-only native primary")
        } catch { r.eq(conflict.native.activeLease, nil, "C1 B5 policy conflict preserves runtime") }
        conflict.config.asrRoutingPolicy = .auto
        conflict.config.setASRBackendSelection(.init(primary: conflict.cloudID, fallback: conflict.nativeID))
        do {
            _ = try await NativeASRActivationCoordinator(state: conflict.native).activate(modelID: conflict.model.id, sample: NativeActivationFixtures.sample(), selectionIntent: .primary)
            r.check(false, "C1 B5 shared duplicate-role rules reject native fallback promotion")
        } catch { r.eq(conflict.native.activeLease, nil, "C1 B5 role conflict preserves runtime") }
    }

    @MainActor static func testTrialDoesNotSelect(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(); let vm = f.makeViewModel()
        let previous = f.config.asrBackendSelection
        await vm.test(f.nativeID)
        r.eq(f.config.asrBackendSelection, previous, "C1 native Test never changes selected roles")
        r.eq(f.native.activeLease, nil, "C1 native Test never replaces inactive runtime with candidate")
        r.eq(vm.lastTrialResult?.text, "fixture recognized", "C1 native Test exposes ephemeral quality preview")
        r.check(f.config.installedASRModels.contains { $0.importedModelID == f.model.id && $0.validation != nil }, "C1 native Test persists minimal historical validation")
        await vm.selectPrimary(f.nativeID)
        let lease = f.native.activeLease
        await vm.test(f.nativeID)
        r.eq(f.native.activeLease, lease, "C1 native Test retains previous active lease")
        let g = ModelCenterFixture(); let gv = g.makeViewModel()
        g.config.setASRBackendSelection(.init(primary: g.serviceID, allowsCloudFallback: true))
        let count = g.recognitions
        await gv.selectFallback(g.cloudID)
        r.eq(g.config.asrBackendSelection?.fallback, nil, "C1 fallback requires prior explicit recognition")
        r.eq(g.recognitions, count, "C1 selecting fallback never uploads audio implicitly")
    }

    @MainActor static func testColdNativeFallback(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(); let vm = f.makeViewModel()
        await vm.selectFallback(f.nativeID)
        r.eq(f.config.asrBackendSelection?.primary, f.cloudID, "C1 cold native fallback retains primary")
        r.eq(f.config.asrBackendSelection?.fallback, f.nativeID, "C1 cold native fallback commits actual successful ID")
        r.eq(f.native.activeLease.map { ASRBackendID(nativeLease: $0) }, f.nativeID, "C1 cold native fallback loads the unique native owner")
        r.eq(f.nativePersists, 1, "C1 cold native fallback uses one durable B5 transaction")
        r.eq(f.centerPersists, 0, "C1 cold native fallback uses no second UI save")
        let g = ModelCenterFixture(); let gv = g.makeViewModel()
        g.persistFails = true
        await gv.selectFallback(g.nativeID)
        r.eq(g.config.asrBackendSelection, ASRBackendSelection(primary: g.cloudID), "C1 cold native fallback persistence failure preserves roles")
        r.eq(g.native.activeLease, nil, "C1 cold native fallback persistence failure preserves absent runtime")
        g.persistFails = false
        await gv.selectPrimary(g.nativeID)
        let active = g.native.activeLease
        g.config.setASRBackendSelection(.init(primary: g.cloudID))
        g.persistFails = true
        await gv.selectFallback(g.nativeID)
        r.eq(g.native.activeLease, active, "C1 failed fallback replacement retains previous lease")
        r.eq(g.config.asrBackendSelection?.fallback, nil, "C1 failed fallback replacement retains previous roles")
        let h = ModelCenterFixture(); let hv = h.makeViewModel()
        h.config.setASRBackendSelection(.init(primary: .init(rawValue: "native:preset:" + ModelPreset.qwen306B.id)))
        await hv.selectFallback(h.nativeID)
        r.eq(h.nativePersists, 0, "C1 two distinct native roles rejected before allocation")
        r.eq(h.config.asrBackendSelection?.fallback, nil, "C1 single native owner conflict never silently clears existing primary")
    }

    @MainActor static func testExplicitRequestGuardsAndUUIDDeselection(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(); let vm = f.makeViewModel()
        let lowercase = ASRBackendID(rawValue: "native:import:" + f.model.id.uuidString.lowercased())
        f.config.setASRBackendSelection(.init(primary: lowercase))
        f.config.activeImportedASRModelID = f.model.id
        f.config.customLocalModelPath = f.model.directory.path
        vm.deselect(f.nativeID)
        r.eq(f.config.asrBackendSelection?.primary, nil, "C1 explicit native deselect respects imported UUID value semantics")
        r.eq(f.config.activeImportedASRModelID, nil, "C1 explicit UUID deselect clears legacy imported intent")
        r.eq(f.config.customLocalModelPath, nil, "C1 explicit UUID deselect clears relevant legacy path intent")
        let g = ModelCenterFixture()
        g.config.setASRBackendSelection(.init(primary: .init(rawValue: "native:preset:" + ModelPreset.qwen306B.id)))
        await g.native.perform(.init(target: .imported(g.model), source: .mirror, origin: .offlineImport, validationSample: try! NativeActivationFixtures.sample(), selectionIntent: .fallback))
        r.eq(g.nativeLoads, 0, "C1 direct explicit request applies shared role guards before allocation")
        r.eq(g.native.activeLease, nil, "C1 invalid explicit request retains previous native owner")
    }

    @MainActor static func testHistoryCallbackAndCompatibilityFlags(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(); let vm = f.makeViewModel()
        f.onVerified = { _ = vm.recordValidation($0) }
        await f.validation.test(profile: f.service, credential: "fixture-only", sample: try! NativeActivationFixtures.sample(), credentialGeneration: f.generation)
        vm.refresh()
        r.eq(f.config.asrServiceValidationRecords.count, 1, "C1 A5 callback persists coordinator-emitted minimal record")
        r.eq(vm.currentValidatedServices, [], "C1 history callback alone never creates current readiness")
        r.eq(vm.rows.first { $0.id == f.serviceID }?.status, .previouslyValidated, "C1 history callback alone is only previously validated")
        let saves = f.centerPersists
        if let record = f.config.asrServiceValidationRecords.first {
            _ = vm.recordValidation(record)
            r.eq(f.centerPersists, saves, "C1 duplicate A5 callback does not write history again")
            let forged = ASRServiceValidationRecord(backendID: record.backendID, revision: UUID(), credentialGeneration: record.credentialGeneration, validatedAt: record.validatedAt)
            r.check(!vm.recordValidation(forged), "C1 stale historical revision callback rejected")
        }
        f.date = f.date.addingTimeInterval(1)
        await vm.test(f.serviceID)
        r.eq(f.centerPersists, saves + 1, "C1 own test and A5 callback deduplicate history persistence")
        f.config.setASRBackendSelection(.init(primary: f.serviceID))
        await vm.selectPrimary(f.cloudID)
        r.eq(f.config.cloudASRConfig.providers.first?.isActive, true, "C1 cloud primary updates compatibility flags atomically")
        r.eq(vm.rows.first { $0.id == f.cloudID }?.status, .ready, "C1 display-only active flag keeps valid recognition evidence")
        await vm.selectPrimary(f.serviceID)
        r.eq(f.config.cloudASRConfig.providers.first?.isActive, false, "C1 local primary clears contradictory cloud active flag")
    }

    @MainActor static func testNativeRemovalAndMissingSample(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(); let vm = f.makeViewModel()
        f.sampleAvailable = false
        await vm.selectPrimary(f.nativeID)
        r.eq(f.nativePersists, 0, "C1 absent sample fails closed before native activation")
        r.eq(f.config.asrBackendSelection?.primary, f.cloudID, "C1 absent sample preserves primary")
        f.sampleAvailable = true
        await vm.selectPrimary(f.nativeID)
        vm.deselect(f.nativeID)
        await vm.remove(f.nativeID, deleteManagedFiles: false)
        r.check(f.config.importedASRModels.contains { $0.id == f.model.id }, "C1 native removal reports blocked unload permission")
        r.check(vm.notice != nil, "C1 native removal surfaces guarded model error")
        f.canUnload = true
        var capture: ModelUsageToken? = try! f.native.activeLease!.usageToken!.captured()
        await vm.remove(f.nativeID, deleteManagedFiles: false)
        r.check(f.native.activeLease != nil && capture != nil, "C1 captured native model prevents resource drain/removal")
        capture = nil
        await vm.remove(f.nativeID, deleteManagedFiles: false)
        r.eq(f.native.activeLease, nil, "C1 explicit deselection and domain drain release active owner")
        r.check(!f.config.importedASRModels.contains { $0.id == f.model.id }, "C1 removal uses guarded B6 facade after drain")
        r.eq(f.config.asrBackendSelection?.primary, nil, "C1 native removal never promotes another row")
    }

    @MainActor static func testManagedPresetActualIdentity(_ r: SelfTest.Reporter) async {
        let f = HFInstallTransactionSelfTests.Fixture(), library = HFInstallTransactionSelfTests.Library()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = HFInstallTransactionSelfTests.Source(f.bytes); await source.release()
        let installer = HFInstallTransactionSelfTests.coordinator(f, library, source: source)
        let primary = ASRBackendID(rawValue: "service:" + UUID().uuidString)
        library.config.setASRBackendSelection(.init(primary: primary))
        let state = QwenModelState(configuration: { library.config }, localModel: { _ in nil },
            environment: .init(read: { nil }, write: { _ in }), inspect: { try ASRModelInspector.inspect(directory: $0) },
            assessHardware: { _, _ in .init(compatibility: .compatible, explanation: "fixture", recommendedMinimumMemory: nil, minimumResidentBytes: 10) },
            persistActivation: { library.config = $0 }, usageRegistry: NativeModelUsageRegistry(), acquirePreset: { _, _, _ in
                _ = try await installer.enqueue(f.plan)
                _ = await HFInstallTransactionSelfTests.until { await installer.snapshots().first?.state == .installed }
                library.config.downloadSource = .mirror
                guard let model = library.config.importedASRModels.first else { throw NativeASRActivationError.missingModel }
                return model
            }, loadImported: { model, authority in
                try authority(model)
                return LocalASRLease(id: UUID(), identity: .init(id: model.id.uuidString, displayName: model.name, engine: model.engine.rawValue, repoID: nil, directory: model.directory), provider: NativeActivationFixtures.Provider())
            })
        do {
            let lease = try await NativeASRActivationCoordinator(state: state).activate(preset: .qwen306B, sample: NativeActivationFixtures.sample(), selectionIntent: .primary)
            let actualID = ASRBackendID(nativeLease: lease)
            r.check(actualID.rawValue.hasPrefix("native:import:"), "C1 B4 acquired preset retains actual managed import identity")
            r.eq(library.config.asrBackendSelection?.primary, actualID, "C1 preset selection commits actual successful backend instead of requested row")
            r.eq(library.config.downloadSource, .mirror, "C1 unrelated latest download default survives atomic activation")
        } catch { r.check(false, "C1 managed preset identity fixture: \(error)") }
        let uninstalled = ModelCenterFixture()
        do { _ = try await NativeASRActivationCoordinator(state: uninstalled.native).test(preset: .qwen306B, sample: NativeActivationFixtures.sample()); r.check(false, "C1 uninstalled preset Test cannot acquire implicitly") }
        catch { r.eq(uninstalled.nativePersists, 0, "C1 uninstalled preset Test fails without acquisition/activation") }
    }

    @MainActor static func testCurrentEvidenceInvalidation(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(); let vm = f.makeViewModel()
        await vm.test(f.serviceID)
        r.eq(vm.lastTrialResult?.text, "fixture transcript", "C1 service Test exposes ephemeral quality preview")
        f.failRecognition = true
        await vm.test(f.serviceID)
        r.eq(vm.currentValidatedServices, [], "C1 failed repeat test revokes current readiness evidence")
        r.eq(vm.rows.first { $0.id == f.serviceID }?.status, .failed(reason: "invalidResponse"), "C1 failed repeat test is shown honestly")
        let g = ModelCenterFixture(); let gv = g.makeViewModel()
        g.blockRecognition = true
        let task = Task { await gv.selectPrimary(g.serviceID) }
        await g.waitForRecognition()
        g.config.asrRoutingPolicy = .cloudOnly
        g.finishRecognition(); await task.value
        r.eq(g.config.asrBackendSelection?.primary, g.cloudID, "C1 policy change during validation suppresses late switch")
        let h = ModelCenterFixture(); let hv = h.makeViewModel()
        h.blockRecognition = true
        let pending = Task { await hv.selectPrimary(h.serviceID) }
        await h.waitForRecognition()
        h.config.setASRBackendSelection(.init(primary: h.nativeID))
        h.finishRecognition(); await pending.value
        r.eq(h.config.asrBackendSelection?.primary, h.nativeID, "C1 newer selection is not overwritten by late service trial")
        let record = f.config.asrServiceValidationRecords.first!
        let json = String(decoding: try! JSONEncoder().encode(record), as: UTF8.self)
        r.check(!json.contains("fixture transcript") && !json.contains("fixture-only") && !json.contains("127.0.0.1"), "C1 persisted validation evidence excludes transcript/key/endpoint")
        r.eq(try! JSONDecoder().decode(ASRServiceValidationRecord.self, from: JSONEncoder().encode(record)), record, "C1 minimal validation history round trips")
    }

    @MainActor static func testStaleAndDuplicateEffects(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(); let vm = f.makeViewModel()
        f.blockRecognition = true
        let task = Task { await vm.selectPrimary(f.serviceID) }
        await f.waitForRecognition()
        vm.refresh()
        r.eq(vm.rows.first { $0.id == f.serviceID }?.status, .testing, "C1 in-flight domain recognition projects testing")
        await vm.test(f.serviceID)
        r.eq(f.recognitions, 1, "C1 double-click uses one A5 transport owner")
        f.generation = UUID(); vm.refresh()
        f.finishRecognition(); await task.value
        r.eq(f.config.asrBackendSelection?.primary, f.cloudID, "C1 changed atomic credential generation suppresses late selection")
        r.eq(vm.currentValidatedServices, [], "C1 stale credential response never supplies current readiness")
        let g = ModelCenterFixture(); let gv = g.makeViewModel()
        await gv.test(g.serviceID)
        let priorRecordCount = g.config.asrServiceValidationRecords.count
        g.blockRecognition = true
        let cancelled = Task { await gv.test(g.serviceID) }
        await g.waitForRecognition(count: 2)
        cancelled.cancel(); g.finishRecognition(); await cancelled.value
        r.eq(g.config.asrServiceValidationRecords.count, priorRecordCount, "C1 cancelled test persists no new historical evidence")
        let h = ModelCenterFixture(); let hv = h.makeViewModel()
        await hv.test(h.serviceID)
        h.generation = UUID()
        let restarted = h.makeViewModel()
        r.eq(restarted.rows.first { $0.id == h.serviceID }?.status, .previouslyValidated, "C1 random process generation never erases historical restart label")
        r.eq(restarted.currentValidatedServices, [], "C1 restart records never feed current readiness")
    }

    @MainActor static func testInstallationAndHistoryProjection(_ r: SelfTest.Reporter) {
        let plan = ASRInstallPlan(id: UUID(), displayName: "fixture", engine: .qwenMLX, files: [], totalBytes: 100, recipeID: nil, recipeVersion: 1, credentialID: nil)
        for (state, expected) in [(ModelInstallState.queued, ASRModelCenterStatus.queued), (.downloading, .downloading(progress: 0.25)), (.paused, .paused), (.verifying, .verifying), (.installed, .installedUntested), (.cancelled, .paused), (.failed, .failed(reason: "fixture"))] {
            let snapshot = ModelInstallSnapshot(jobID: UUID(), plan: plan, state: state, receivedBytes: 25, errorCode: "fixture")
            r.eq(ASRModelCenterPresentation.installationStatus(snapshot), expected, "C1 projects installation state " + state.rawValue)
        }
        let f = ModelCenterFixture()
        f.validation.checkConfiguration(profile: f.service, credential: "fixture-only", credentialGeneration: f.generation)
        f.validation.checkConfiguration(cloudProfile: f.cloud, apiKey: "fixture-only", credentialGeneration: f.generation)
        let vm = f.makeViewModel()
        r.eq(vm.rows.first { $0.id == f.serviceID }?.status, .installedUntested, "C1 service configuration validity is not recognition success")
        r.eq(vm.rows.first { $0.id == f.cloudID }?.status, .installedUntested, "C1 cloud configuration validity is not recognition success")
        let record = ASRInstalledModelRecord(id: UUID(), importedModelID: f.model.id, ownership: .external, installPlan: nil, directory: f.model.directory, validation: nil, legacyPresetID: ModelPreset.qwen306B.id)
        f.config.installedASRModels = [record]; vm.refresh()
        r.check(!vm.rows.contains { $0.id == f.nativeID }, "C1 exact B6 association folds adopted legacy model into preset row")
        r.eq(vm.rows.first { $0.id.rawValue == "native:preset:" + ModelPreset.qwen306B.id }?.status, .installedUntested, "C1 associated legacy preset retains installed status")
        f.config.installedASRModels[0].legacyPresetID = nil; vm.refresh()
        r.check(vm.rows.contains { $0.id == f.nativeID }, "C1 matching engine/path alone never guesses legacy association")
        do {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.config)) as! [String: Any]
            json.removeValue(forKey: "asrServiceValidationRecords")
            let old = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: json))
            r.eq(old.asrServiceValidationRecords, [], "C1 historical records default empty for old configuration")
        } catch { r.check(false, "C1 old configuration decoding succeeds") }
    }

    @MainActor static func testPolicyConsentAndRemoval(_ r: SelfTest.Reporter) async {
        let f = ModelCenterFixture(); let vm = f.makeViewModel()
        f.config.setASRBackendSelection(.init(primary: f.serviceID))
        await vm.selectFallback(f.serviceID)
        r.eq(f.config.asrBackendSelection?.fallback, nil, "C1 duplicate roles rejected")
        await vm.selectFallback(f.cloudID)
        r.eq(f.config.asrBackendSelection?.fallback, nil, "C1 cloud fallback needs explicit consent")
        vm.setAllowsCloudFallback(true); await vm.test(f.cloudID); await vm.selectFallback(f.cloudID)
        r.eq(f.config.asrBackendSelection?.fallback, f.cloudID, "C1 explicit upload consent permits chosen cloud fallback")
        f.config.asrRoutingPolicy = .localOnly
        let count = f.recognitions
        await vm.selectPrimary(f.cloudID)
        r.eq(f.recognitions, count, "C1 incompatible local-only choice sends no audio")
        r.eq(f.config.asrBackendSelection?.primary, f.serviceID, "C1 policy conflict never changes primary")
        f.config.asrRoutingPolicy = .cloudOnly
        await vm.selectPrimary(f.serviceID)
        r.eq(f.recognitions, count, "C1 incompatible cloud-only choice sends no audio")
        f.config.asrRoutingPolicy = .auto
        await vm.remove(f.serviceID, deleteManagedFiles: false)
        r.check(f.config.localASRServices.contains { $0.id == f.service.id }, "C1 selected removal requires explicit deselection")
        vm.deselect(f.serviceID)
        r.eq(f.config.asrBackendSelection?.primary, nil, "C1 explicit deselection never promotes arbitrary first row")
        r.check(!f.config.pendingLegacyNativeResolution, "C1 explicit deselection clears legacy migration marker")
        await vm.remove(f.serviceID, deleteManagedFiles: false)
        r.check(!f.config.localASRServices.contains { $0.id == f.service.id }, "C1 unselected service record can be removed")
    }
}

@MainActor private final class ModelCenterFixture {
    var config = Configuration()
    var date = Date()
    var generation = UUID()
    var recognitions = 0
    var failRecognition = false
    var persistFails = false
    var editDuringRecognition = false
    var nativePersists = 0
    var nativeLoads = 0
    var centerPersists = 0
    var onVerified: ((ASRServiceValidationRecord) -> Void)?
    var sampleAvailable = true
    var canUnload = false
    let usage = NativeModelUsageRegistry()
    var recognitionOverride: ((LocalASRServiceProfile) async throws -> String)?
    var blockNativeLoad = false
    var nativeContinuation: CheckedContinuation<Void, Never>?
    func pauseNativeLoad() async {
        nativeLoads += 1
        if blockNativeLoad { await withCheckedContinuation { nativeContinuation = $0 } }
    }
    func waitForNativeLoad() async { for _ in 0..<10_000 { if nativeContinuation != nil { return }; await Task.yield() } }
    func finishNativeLoad() { let c = nativeContinuation; nativeContinuation = nil; c?.resume() }
    var blockSnapshots = false
    var snapshotsContinuation: CheckedContinuation<Void, Never>?
    func snapshots() async -> [ModelInstallSnapshot] {
        if blockSnapshots { await withCheckedContinuation { snapshotsContinuation = $0 } }
        return []
    }
    func waitForSnapshots() async { for _ in 0..<10_000 { if snapshotsContinuation != nil { return }; await Task.yield() } }
    func finishSnapshots() { let c = snapshotsContinuation; snapshotsContinuation = nil; c?.resume() }
    var blockRecognition = false
    var continuation: CheckedContinuation<Void, Never>?
    func waitForRecognition(count: Int = 1) async { for _ in 0..<10_000 { if recognitions >= count && continuation != nil { return }; await Task.yield() } }
    func finishRecognition() { let c = continuation; continuation = nil; c?.resume() }
    let service = LocalASRServiceProfile(id: UUID(), revision: UUID(), name: "Fixture service", baseURL: "http://127.0.0.1:8123", protocolKind: .whisperCpp, modelID: nil, authentication: .none, fieldCapabilities: .init())
    let cloud = CloudASRProviderConfig(name: "Fixture cloud", provider: "custom", baseURL: "https://fixture.invalid/v1", model: "fixture")
    let model = ImportedASRModel(name: "Fixture native", directory: URL(fileURLWithPath: "/injected/c1"), engine: .qwenMLX, variant: "0.6B", bits: 4, sizeBytes: 10, tokenizerDirectory: nil, fileFingerprint: "fixture")
    var serviceID: ASRBackendID { .init(rawValue: "service:" + service.id.uuidString) }
    var cloudID: ASRBackendID { .init(rawValue: "cloud:" + cloud.id.uuidString) }
    var nativeID: ASRBackendID { .init(rawValue: "native:import:" + model.id.uuidString) }
    lazy var native = QwenModelState(preflight: { _, _ in }, load: { [model, weak self] _, _, _ in
        await self?.pauseNativeLoad()
        return LocalASRLease(id: UUID(), identity: .init(id: model.id.uuidString, displayName: model.name,
            engine: model.engine.rawValue, repoID: nil, directory: model.directory), provider: NativeActivationFixtures.Provider())
    }, configuration: { [self] in config }, localModel: { _ in nil }, environment: .init(read: { nil }, write: { _ in }), inspect: { [model] _ in model },
        assessHardware: { _, _ in .init(compatibility: .compatible, explanation: "fixture", recommendedMinimumMemory: nil, minimumResidentBytes: 10) },
        saveConfiguration: { [self] in config = $0 }, persistActivation: { [self] in
            nativePersists += 1
            if persistFails { throw ASRCredentialError.persistence }; config = $0
        }, usageRegistry: usage, canUnload: { [self] in canUnload })
    lazy var validation = makeValidation()
    private func makeValidation() -> ASRServiceValidationCoordinator {
        ASRServiceValidationCoordinator(session: nil, resolver: { _ in ["127.0.0.1"] }, now: { [self] in date }, onVerified: { [self] in onVerified?($0) }, serviceRecognition: { [self] profile, _, _ in
        recognitions += 1
        if let recognitionOverride { return try await recognitionOverride(profile) }
        if blockRecognition { await withCheckedContinuation { continuation = $0 } }
        if editDuringRecognition { config.localASRServices[0].revision = UUID() }
        if failRecognition { throw CloudASRError.invalidResponse }
        return "fixture transcript"
    }, cloudRecognition: { [self] _, _, _ in recognitions += 1; return "fixture transcript" })
    }
    init() {
        config.localASRServices = [service]
        config.cloudASRConfig.providers = [cloud]
        config.importedASRModels = [model]
        config.setASRBackendSelection(.init(primary: cloudID))
    }
    func makeViewModel() -> ASRModelCenterViewModel {
        .init(configuration: { [self] in config }, persist: { [self] value in
            centerPersists += 1
            if persistFails { throw ASRCredentialError.persistence }; config = value
        }, native: native, validation: validation, credential: { [self] _ in .init(value: "fixture-only", generation: generation) },
              sample: { [self] in
                  guard sampleAvailable else { throw NativeASRActivationError.validationRequired }
                  return try ASRValidationSample(samples: [0, 0.25], sampleRate: 16000, label: "synthetic") }, installationSnapshots: { [self] in await snapshots() }, now: { [self] in date })
    }
}

@MainActor private final class ModelCenterRecognitionGate {
    var calls: [UUID] = []
    private var pending: [UUID: CheckedContinuation<String, Error>] = [:]
    func recognize(_ id: UUID) async throws -> String {
        calls.append(id)
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func waitForCall(_ id: UUID) async { for _ in 0..<10_000 { if pending[id] != nil { return }; await Task.yield() } }
    func finish(_ id: UUID) { pending.removeValue(forKey: id)?.resume(returning: "recognized " + id.uuidString) }
}
