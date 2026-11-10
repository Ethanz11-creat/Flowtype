import Foundation
#if DEBUG
import SwiftUI
#endif

/// Review regressions through the production application-owned model-center actions.
enum ASRModelCenterFixSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        policyDisclosure(r)
        await renderPolicy(r)
        await legacyRelocation(r)
        await relocation(r)
        await relocationGuards(r)
    }
    @MainActor static func policyDisclosure(_ r: SelfTest.Reporter) {
        let f = ASRModelCenterIntegrationSelfTests.Fixture(); defer { f.cleanup() }
        let navigation = SettingsNavigation()
        let actions = f.environment.actions(navigation: navigation)
        let view = ASRModelCenterView(model: f.environment.model, actions: actions)
        for policy in [ASRRoutingPolicy.localOnly, .auto, .cloudOnly] {
            for polish in [false, true] {
                f.store.current.asrRoutingPolicy = policy; f.store.current.polishOnStop = polish
                r.eq(view.policyDisclosure != nil, policy == .localOnly && polish, "M1 production policy summary shows independent text upload disclosure only when applicable")
            }
        }
        actions.manageTextPolish()
        r.eq(navigation.request?.destination, .settings(.text), "M1 production policy action opens text management")
    }

    @MainActor static func renderPolicy(_ r: SelfTest.Reporter) async {
        #if DEBUG
        let f = RelocationFixture(); defer { f.base.cleanup() }
        f.base.store.current.asrRoutingPolicy = .localOnly; f.base.store.current.polishOnStop = true
        let env = f.environment; env.model.selectedID = f.id
        do {
            let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("model-center-fix-previews")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for dark in [false, true] {
                let view = ASRModelCenterView(model: env.model, actions: env.actions(navigation: .init()))
                let host = await NativeClientPreviewSelfTests.renderHost(AnyView(view.padding(20).background(Theme.pageBackground)), width: 850, height: 760, dark: dark)
                try NativeClientPreviewSelfTests.capture(host, to: root.appendingPathComponent("policy-relocation-\(dark ? "dark" : "light").png"))
            }
            print("Model center fix preview: \(root.path)")
        } catch { r.check(false, "review policy preview: \(error)") }
        #endif
    }

    @MainActor static func legacyRelocation(_ r: SelfTest.Reporter) async {
        for role in ["primary", "fallback", "unselected"] {
            let f = RelocationFixture(); defer { f.base.cleanup() }
            let env = f.environment
            await env.model.selectPrimary(f.id)
            let record = f.base.store.current.installedASRModels[0]
            f.base.store.current.installedASRModels[0] = .init(id: record.id, importedModelID: record.importedModelID,
                ownership: .external, installPlan: nil, directory: record.directory, validation: record.validation, legacyPresetID: ModelPreset.qwen306B.id)
            let oldID = ASRBackendID(rawValue: "native:preset:" + ModelPreset.qwen306B.id)
            let unrelated = ASRBackendID(rawValue: "native:preset:" + ModelPreset.qwen317B.id)
            let oldSelection = ASRBackendSelection(primary: role == "primary" ? oldID : (role == "fallback" ? f.base.id : unrelated),
                fallback: role == "fallback" ? oldID : nil)
            f.base.store.current.setASRBackendSelection(oldSelection); env.model.refresh()
            let previous = f.native.activeLease, actions = env.actions(navigation: nil)
            await actions.stageRelocation?(oldID, f.moved)?.value
            guard let preview = f.imported.preview else { r.check(false, "I3 legacy relocation preview exists"); continue }
            await actions.relocatePreview?(preview.id)
            r.eq(f.base.store.current.installedASRModels.first { $0.importedModelID == f.original.id }?.legacyPresetID, nil,
                 "I3 legacy relocation clears outdated preset association")
            r.eq(f.base.store.current.asrBackendSelection?.primary, role == "primary" ? f.id : oldSelection.primary,
                 "I3 legacy relocation maps only exact primary slot to same imported UUID")
            r.eq(f.base.store.current.asrBackendSelection?.fallback, role == "fallback" ? f.id : nil,
                 "I3 legacy relocation maps only exact fallback slot to same imported UUID")
            if role == "unselected" { r.eq(f.native.activeLease, previous, "I3 unselected legacy relocation never steals unrelated preset runtime") }
            else { r.eq(env.model.loadedNativeID, f.id, "I3 selected legacy relocation swaps to inspected imported identity") }
        }
    }

    @MainActor static func relocation(_ r: SelfTest.Reporter) async {
        for role in ["primary", "fallback", "unselected"] {
            let f = RelocationFixture(); defer { f.base.cleanup() }
            let env = f.environment, actions = env.actions(navigation: nil)
            await env.model.selectPrimary(role == "unselected" ? f.otherID : f.id)
            if role == "fallback" { f.base.store.current.setASRBackendSelection(.init(primary: f.base.id, fallback: f.id)); env.model.refresh() }
            let selection = f.base.store.current.asrBackendSelection, previous = f.native.activeLease
            await actions.stageRelocation?(f.id, f.moved)?.value
            r.check(actions.importedActions?.preview?.model.id == f.original.id, "I3 production detail stages relocation with same UUID")
            r.eq(f.base.store.current.importedASRModels.first { $0.id == f.original.id }?.directory, f.original.directory, "I3 relocation preview does not persist")
            if let preview = actions.importedActions?.preview { await actions.relocatePreview?(preview.id) }
            r.eq(f.base.store.current.importedASRModels.first { $0.id == f.original.id }?.directory, f.moved, "I3 validated relocation updates original path")
            r.eq(f.base.store.current.asrBackendSelection, selection, "I3 relocation preserves exact \(role) roles")
            r.eq(f.base.store.current.importedASRModels.count, 2, "I3 relocation cannot append another UUID")
            if role == "unselected" { r.eq(f.native.activeLease, previous, "I3 unselected relocation preserves unrelated active lease") }
            else { r.eq(f.native.activeLease?.identity.directory, f.moved, "I3 selected relocation replaces runtime after commit") }
        }
    }
    @MainActor static func relocationGuards(_ r: SelfTest.Reporter) async {
        for mode in ["failure", "cancel", "persist", "stale", "alias", "captured", "recording", "managed", "changedDuringLoad", "aliasDuringLoad", "stalePreview", "associationChanged"] {
            let f = RelocationFixture(); defer { f.base.cleanup() }
            let env = f.environment, actions = env.actions(navigation: nil)
            await env.model.selectPrimary(f.id)
            let oldLease = f.native.activeLease
            await actions.stageRelocation?(f.id, f.moved)?.value
            guard let preview = f.imported.preview else { r.check(false, "I3 guard fixture stages preview"); continue }
            var capture: LocalASRLease?
            var reservation: UUID?
            if mode == "failure" { f.fails = true }
            if mode == "persist" { f.persistFails = true }
            if mode == "stale" { f.base.store.current.importedASRModels[0].name = "newer editor" }
            if mode == "alias" { f.base.store.current.importedASRModels[1].directory = f.moved }
            if mode == "captured" { capture = try? f.native.activeLease?.captured() }
            if mode == "recording" { reservation = f.base.resources.acquire(owner: UUID()) }
            if mode == "managed", let record = f.base.store.current.installedASRModels.first {
                f.base.store.current.installedASRModels[0] = .init(id: record.id, importedModelID: record.importedModelID,
                    ownership: .managed, installPlan: nil, directory: record.directory, validation: record.validation, legacyPresetID: record.legacyPresetID)
            }
            if mode == "associationChanged", let record = f.base.store.current.installedASRModels.first {
                f.base.store.current.installedASRModels[0] = .init(id: record.id, importedModelID: record.importedModelID,
                    ownership: .external, installPlan: nil, directory: record.directory, validation: record.validation, legacyPresetID: ModelPreset.qwen306B.id)
            }
            if mode == "stalePreview" { await actions.stageRelocation?(f.id, f.moved.appendingPathComponent("newer"))?.value }
            var expected = f.base.store.current
            let blocks = ["cancel", "changedDuringLoad", "aliasDuringLoad"].contains(mode)
            f.blocked = blocks
            let task = Task { await actions.relocatePreview?(preview.id) }
            if blocks {
                await f.waitForLoad()
                if mode == "cancel" {
                    actions.currentOperation?()?.cancel()
                    r.check(env.model.isBusy, "I3 canceled relocation keeps admission until drain")
                }
                if mode == "changedDuringLoad" { f.base.store.current.importedASRModels[0].name = "edited during trial" }
                if mode == "aliasDuringLoad" { f.base.store.current.importedASRModels[1].directory = f.moved }
                expected = f.base.store.current
                f.finish()
            }
            await task.value
            r.eq(f.base.store.current, expected, "I3 \(mode) keeps original record/roles/evidence")
            r.eq(f.native.activeLease, oldLease, "I3 \(mode) keeps original lease")
            r.check(env.model.notice != nil, "I3 \(mode) reports refusal")
            if let reservation { f.base.resources.release(token: reservation) }
            withExtendedLifetime(capture) {}
            capture = nil
        }
    }

}

@MainActor private final class RelocationFixture {
    let base = ASRModelCenterIntegrationSelfTests.Fixture()
    let original: ImportedASRModel
    let other: ImportedASRModel
    let moved: URL
    var blocked = false, fails = false, persistFails = false
    var loads = 0
    var continuation: CheckedContinuation<Void, Never>?
    var id: ASRBackendID { .init(rawValue: "native:import:" + original.id.uuidString) }
    var otherID: ASRBackendID { .init(rawValue: "native:import:" + other.id.uuidString) }
    init() {
        original = NativeActivationFixtures.model(base.root.appendingPathComponent("old"))
        other = NativeActivationFixtures.model(base.root.appendingPathComponent("other"))
        moved = base.root.appendingPathComponent("moved")
        base.store.current.importedASRModels = [original, other]
    }
    func load() async throws {
        loads += 1
        if blocked { await withCheckedContinuation { continuation = $0 } }
        if fails { throw NativeASRActivationError.emptyResult }
    }
    func waitForLoad() async { for _ in 0..<10_000 { if continuation != nil { return }; await Task.yield() } }
    func finish() { let c = continuation; continuation = nil; c?.resume() }
    lazy var native = QwenModelState(preflight: { _, _ in }, load: { [weak self] target, _, _ in
        guard case .imported(let model) = target else { throw NativeASRActivationError.missingModel }
        try await self?.load()
        return .init(id: UUID(), identity: .init(id: model.id.uuidString, displayName: model.name, engine: model.engine.rawValue,
            repoID: nil, directory: model.directory), provider: NativeActivationFixtures.Provider(), minimumResidentBytes: 10)
    }, configuration: { [self] in base.store.current }, localModel: { _ in nil }, environment: .init(read: { nil }, write: { _ in }),
        inspect: { [original, other] url in var model = url == other.directory ? other : original; model.directory = url; return model },
        assessHardware: { _, _ in .init(compatibility: .compatible, explanation: "synthetic", recommendedMinimumMemory: nil, minimumResidentBytes: 10) },
        persistActivation: { [self] in if persistFails { throw ASRCredentialError.persistence }; try base.store.commitNativeASRActivation($0) },
        sampleProvider: NativeActivationFixtures.sample, usageRegistry: base.usage,
        canUnload: { [self] in !base.resources.isReserved })
    lazy var imported = ImportedASRModelActions(coordinator: native, configuration: { [self] in base.store.current },
        inspect: { [original] url in var model = original; model.directory = url; return model },
        assess: { _ in .init(compatibility: .compatible, explanation: "synthetic", recommendedMinimumMemory: nil, minimumResidentBytes: 10) })
    lazy var environment = ASRModelCenterEnvironment(store: base.store, native: native, installer: base.installer,
        resources: base.resources, checks: base.checks, usage: base.usage, importedActions: imported,
        sample: NativeActivationFixtures.sample, now: { Date(timeIntervalSince1970: 2000) })
}
