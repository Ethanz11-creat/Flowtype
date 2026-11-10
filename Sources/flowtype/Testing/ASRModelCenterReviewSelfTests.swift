import Foundation
import os
#if DEBUG
import SwiftUI
#endif

/// Production composition paths identified by the C4/whole-A–C review. No live effects.
enum ASRModelCenterReviewSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        await newAnonymousDiscovery(r)
        await nativeUnloadRecovery(r)
        await realtimeSelection(r)
    }
    @MainActor static func newAnonymousDiscovery(_ r: SelfTest.Reporter) async {
        let f = ASRModelCenterIntegrationSelfTests.Fixture(); defer { f.cleanup() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DiscoveryTransport.self]
        let transport = URLSession(configuration: configuration); defer { transport.invalidateAndCancel() }
        let env = ASRModelCenterEnvironment(store: f.store, native: f.native, installer: f.installer, resources: f.resources,
            checks: f.checks, usage: f.usage, discovery: .init(session: transport, resolver: { _ in ["127.0.0.1"] }),
            sample: { try f.sample() }, now: { f.date })
        let actions = env.actions(navigation: nil)
        let profile = LocalASRServicePreset.mlxAudio.makeProfile(baseURL: "http://127.0.0.1:8111/v1", modelID: nil)
        let draft = LocalASRServiceDraft(target: .new(profile.id), profile: profile)
        let editor = LocalASRServiceDraftSession(draft: draft)
        let before = f.store.current
        DiscoveryTransport.reset()
        await editor.discover(credential: { try actions.credential!(.init(rawValue: "service:" + profile.id.uuidString)) }, using: actions.discovery!)
        r.eq(editor.models, ["fixture-asr"], "C4 I1 new anonymous sheet discovers before model selection/save")
        r.eq(DiscoveryTransport.requests.count, 1, "C4 I1 production actions reach injected discovery transport")
        r.eq(DiscoveryTransport.requests.first?.httpMethod, "GET", "C4 I1 discovery has no audio request")
        r.check(DiscoveryTransport.requests.first?.httpBody == nil && DiscoveryTransport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil, "C4 I1 anonymous discovery sends neither audio nor Authorization")
        r.eq(f.store.current, before, "C4 I1 discovery neither saves nor selects")
        let missing = LocalASRServiceDraftSession(draft: .init(target: .existing(profile.id), profile: profile))
        await missing.discover(credential: { try actions.credential!(.init(rawValue: "service:" + profile.id.uuidString)) }, using: actions.discovery!)
        r.check(missing.models.isEmpty && missing.notice != nil, "C4 I1 deleted existing credential remains strict")
        r.eq(DiscoveryTransport.requests.count, 1, "C4 I1 missing existing never becomes anonymous request")
    }

    @MainActor static func nativeUnloadRecovery(_ r: SelfTest.Reporter) async {
        let f = ASRModelCenterIntegrationSelfTests.Fixture(); defer { f.cleanup() }
        let old = NativeActivationFixtures.model(f.root.appendingPathComponent("old"))
        var next = NativeActivationFixtures.model(f.root.appendingPathComponent("next")); next.id = UUID()
        let candidate = next
        f.store.current.importedASRModels = [old, candidate]
        f.store.current.asrRoutingPolicy = .localOnly
        let failure = NativeFailure()
        let native = QwenModelState(preflight: { _, _ in }, load: { target, _, _ in
            guard case .imported(let model) = target else { throw NativeASRActivationError.missingModel }
            if model.id == candidate.id && failure.failCandidate { throw NativeASRActivationError.emptyResult }
            return .init(id: UUID(), identity: .init(id: model.id.uuidString, displayName: model.name, engine: model.engine.rawValue,
                repoID: nil, directory: model.directory), provider: NativeActivationFixtures.Provider(), minimumResidentBytes: 10)
        }, configuration: { f.store.current }, localModel: { _ in nil }, environment: .init(read: { nil }, write: { _ in }),
            inspect: { url in url == old.directory ? old : candidate },
            assessHardware: { _, active in .init(compatibility: active == nil ? .compatible : .incompatible,
                explanation: active == nil ? "fixture single model fits" : "fixture dual-model admission exceeds memory", recommendedMinimumMemory: nil, minimumResidentBytes: 10) },
            persistActivation: { try f.store.commitNativeASRActivation($0) }, sampleProvider: { try f.sample() }, usageRegistry: f.usage,
            canUnload: { ASRApplicationModelDependencies.canUnload(resources: f.resources) })
        let env = ASRModelCenterEnvironment(store: f.store, native: native, installer: f.installer, resources: f.resources,
            checks: f.checks, usage: f.usage, sample: { try f.sample() }, now: { f.date })
        let vm = env.model, oldID = ASRBackendID(rawValue: "native:import:" + old.id.uuidString)
        let nextID = ASRBackendID(rawValue: "native:import:" + candidate.id.uuidString)
        await vm.selectPrimary(oldID)
        await vm.selectPrimary(nextID)
        r.check(vm.nativeRecoveryDetail?.contains("dual-model") == true, "C4 I2 concrete dual-memory reason reaches model center")
        await renderRecovery(r, environment: env, id: nextID, state: "memory-refusal")
        let marker = old.directory.appendingPathComponent("fixture-marker")
        try? FileManager.default.createDirectory(at: old.directory, withIntermediateDirectories: true)
        try? Data("keep".utf8).write(to: marker)
        let before = f.store.current
        let token = f.resources.acquire(owner: UUID())!
        await vm.unloadNative(oldID)
        r.check(native.activeLease != nil && vm.unloadedNativeID == nil, "C4 I2 recording occupancy refuses explicit unload")
        f.resources.release(token: token)
        var captured = try? native.activeLease?.captured()
        await vm.unloadNative(oldID)
        r.check(native.activeLease != nil && vm.unloadedNativeID == nil, "C4 I2 captured resource refuses explicit unload")
        captured = nil
        await vm.unloadNative(oldID)
        r.eq(native.activeLease, nil, "C4 I2 released resources permit explicit unload")
        r.eq(vm.unloadedNativeID, oldID, "C4 I2 reload stores stable identity only")
        r.eq(f.store.current, before, "C4 I2 unload preserves all records paths roles and validation")
        r.eq(try? Data(contentsOf: marker), Data("keep".utf8), "C4 I2 explicit unload preserves model files")
        failure.failCandidate = true
        await vm.selectPrimary(nextID)
        r.eq(native.activeLease, nil, "C4 I2 failed replacement remains truthfully unloaded")
        r.eq(vm.unloadedNativeID, oldID, "C4 I2 failed replacement keeps explicit old reload path")
        await renderRecovery(r, environment: env, id: nextID, state: "unloaded-recovery")
        await vm.reloadUnloadedNative()
        r.eq(vm.loadedNativeID, oldID, "C4 I2 explicit reload restores old exact identity")
        r.eq(vm.unloadedNativeID, nil, "C4 I2 successful reload clears recovery hint")
        await vm.unloadNative(nextID)
        r.eq(vm.loadedNativeID, oldID, "C4 I2 stale confirmation cannot unload a different runtime")
        await vm.unloadNative(oldID)
        vm.deselect(oldID)
        r.eq(vm.unloadedNativeID, nil, "C4 I2 selection change invalidates old reload intent")
        await vm.reloadUnloadedNative()
        r.eq(vm.loadedNativeID, nil, "C4 I2 obsolete reload cannot restore a deselected backend")
        r.eq(f.store.current.asrBackendSelection?.primary, nil, "C4 I2 obsolete reload cannot restore an old role")
        await vm.selectPrimary(oldID)
        await vm.unloadNative(oldID)
        vm.changePolicy(.auto)
        r.eq(vm.unloadedNativeID, nil, "C4 I2 policy change invalidates old reload intent")
        await vm.selectPrimary(oldID)
        f.store.current.setASRBackendSelection(.init(primary: nextID))
        await vm.unloadNative(oldID)
        r.eq(vm.unloadedNativeID, nil, "C4 I2 mismatched selected identity offers no role-changing reload")
        await vm.reloadUnloadedNative()
        r.eq(f.store.current.asrBackendSelection?.primary, nextID, "C4 I2 unload of an obsolete runtime preserves latest selected identity")
        withExtendedLifetime(captured) {}
    }

    actor AdmissionGate {
        var held = false
        var waiter: CheckedContinuation<Void, Never>?, started: CheckedContinuation<Void, Never>?
        func hold() async {
            held = true; started?.resume(); started = nil
            await withCheckedContinuation { waiter = $0 }
        }
        func waitUntilHeld() async { if held { return }; await withCheckedContinuation { started = $0 } }
        func release() { waiter?.resume(); waiter = nil }
    }

    @MainActor static func realtimeSelection(_ r: SelfTest.Reporter) async {
        let f = ASRModelCenterIntegrationSelfTests.Fixture(); defer { f.cleanup() }
        let probe = RealtimeProbe(), clock = DeadlineClock()
        let env = ASRModelCenterEnvironment(store: f.store, native: f.native, installer: f.installer, resources: f.resources,
            checks: f.checks, usage: f.usage, sample: { try f.sample() }, now: { f.date },
            makeValidation: { callback in .init(now: { f.date }, onVerified: callback,
                serviceRecognition: { _, _, _ in "synthetic local" }, realtimeFactory: { probe.make($0) }, realtimeTimeout: 0.1, realtimeDeadlineSleep: { try await clock.sleep($0) }) })
        f.store.current.asrRoutingPolicy = .auto
        f.store.current.setASRBackendSelection(.init(primary: f.id))
        let dash = CloudASRProviderConfig.defaultParaformer(), vm = env.model
        let id = ASRBackendID(rawValue: "cloud:" + dash.id.uuidString)
        do {
            try env.actions(navigation: nil).saveCloud!(.init(target: .new(dash.id), profile: dash, keyEdit: .replace("fixture-key")))
            r.eq(f.store.current.asrBackendSelection?.primary, f.id, "C4 I3 saving DashScope does not select")
            env.validation.checkConfiguration(cloudProfile: dash, apiKey: "fixture-key")
            r.eq(env.validation.state(profileID: dash.id), .configurationValid, "C4 I3 check remains configuration-only")
            r.eq(probe.configurations.count, 0, "C4 I3 configuration check starts no realtime session")
            await vm.test(id)
            r.eq(vm.lastTrialResult?.text, "synthetic realtime", "C4 I3 explicit DashScope sample yields real factory result")
            r.eq(probe.configurations.first?.apiKey, "fixture-key", "C4 I3 captured realtime credential")
            r.eq(probe.configurations.first?.language, nil, "C4 I3 trial carries no context-derived language")
            if let session = probe.latest {
                let chunks = await session.chunks
                r.eq(chunks.flatMap { $0 }, try f.sample().samples, "C4 I3 sends exact canonical 16k sample")
                r.check(chunks.allSatisfy { $0.count <= 1600 }, "C4 I3 realtime sample uses bounded 1600-sample append")
                r.eq(await session.starts, 1, "C4 I3 realtime starts once")
                r.eq(await session.finishes, 1, "C4 I3 realtime finishes once")
                r.check(await session.cancelled, "C4 I3 successful trial cleans up session")
            } else { r.check(false, "C4 I3 explicit sample reaches factory") }
            vm.setAllowsCloudFallback(true)
            await vm.selectFallback(id)
            r.eq(f.store.current.asrBackendSelection?.fallback, id, "C4 I3 verified DashScope supports fallback")
            await vm.selectFallback(nil)
            await vm.selectPrimary(id)
            r.eq(f.store.current.asrBackendSelection?.primary, id, "C4 I3 validated DashScope supports primary")
            await vm.selectPrimary(f.id); await vm.selectPrimary(id)
            r.eq(f.store.current.asrBackendSelection?.primary, id, "C4 I3 switching back to DashScope remains available")
            await vm.selectPrimary(f.id)
            probe.mode = .empty
            await vm.selectPrimary(id)
            r.eq(f.store.current.asrBackendSelection?.primary, f.id, "C4 I3 empty trial preserves prior selection")
            probe.mode = .held
            let admission = AdmissionGate(), cancellationCount = probe.configurations.count
            let cancelTimerCount = clock.count
            let operation = Task { await admission.hold(); await vm.selectPrimary(id) }
            await admission.waitUntilHeld()
            let observation = Task { await probe.session(at: cancellationCount) }
            // Deliberately register observation before VM admission. A poll/yield
            // budget must never masquerade as proof that this producer is held.
            await probe.waitUntilSessionRequested(at: cancellationCount)
            r.check(!vm.isBusy && !env.validation.isTesting(profileID: dash.id), "C4 I3 delayed caller has no owner before positive admission")
            await admission.release()
            let cancelledSession = await observation.value
            await cancelledSession.waitUntilFinishHeld()
            let cancelledTimer = await clock.timer(at: cancelTimerCount)
            r.eq(cancelledSession.ordinal, cancellationCount, "C4 I3 cancellation targets newly admitted session")
            operation.cancel()
            await cancelledSession.waitUntilCleanupHeld()
            print("C4 cancellation barrier: \(await cancelledSession.diagnostic()) vmBusy=\(vm.isBusy) a5Owner=\(env.validation.isTesting(profileID: dash.id))")
            r.check(vm.isBusy, "C4 I3 cancelled producer retains VM owner until actual cleanup drain")
            r.check(env.validation.isTesting(profileID: dash.id), "C4 I3 cancelled producer retains A5 owner until actual cleanup drain")
            r.check(vm.isBusy && env.validation.isTesting(profileID: dash.id), "C4 I3 cancelled producer retains owner until actual cleanup drain")
            await cancelledSession.releaseFinish()
            r.check(vm.isBusy && env.validation.isTesting(profileID: dash.id), "C4 I3 finished producer still retains owner while cleanup is held")
            await cancelledSession.releaseCleanup(); await operation.value
            r.eq(clock.pending, 0, "C4 I3 cancellation drains timer continuation")
            r.eq(f.store.current.asrBackendSelection?.primary, f.id, "C4 I3 cancelled trial preserves prior selection")
            r.check(vm.currentValidatedServices.allSatisfy { $0.backendID != id }, "C4 I3 cancellation cannot publish live evidence")
            let timedCount = probe.configurations.count, timedTimerCount = clock.count
            let timed = Task { await vm.selectPrimary(id) }
            let timedSession = await probe.session(at: timedCount)
            await timedSession.waitUntilFinishHeld()
            let deadline = await clock.timer(at: timedTimerCount)
            r.eq(deadline.seconds, 0.1, "C4 I3 injected clock retains configured realtime deadline")
            r.check(!clock.expire(cancelledTimer), "C4 I3 canceled timer cannot expire successor")
            r.check(vm.isBusy && env.validation.isTesting(profileID: dash.id), "C4 I3 stale timer leaves successor owned")
            r.check(clock.expire(deadline), "C4 I3 expires exact current deadline after held finish")
            await timedSession.waitUntilCleanupHeld()
            print("C4 timeout barrier: \(await timedSession.diagnostic()) vmBusy=\(vm.isBusy) a5Owner=\(env.validation.isTesting(profileID: dash.id))")
            r.check(await timedSession.cancelled && vm.isBusy && env.validation.isTesting(profileID: dash.id), "C4 I3 timeout keeps owner while cleanup is held")
            await timedSession.releaseCleanup()
            r.check(vm.isBusy && env.validation.isTesting(profileID: dash.id), "C4 I3 cleanup completion still retains owner while producer is held")
            await timedSession.releaseFinish(); await timed.value
            r.eq(env.validation.state(profileID: dash.id), .failed(code: "timeout"), "C4 I3 timeout is stable failure despite late worker result")
            r.eq(f.store.current.asrBackendSelection?.primary, f.id, "C4 I3 timeout preserves prior selection")
            let count = probe.configurations.count
            let edited = Task { await vm.selectPrimary(id) }
            let editedSession = await probe.session(at: count)
            await editedSession.waitUntilFinishHeld()
            var changed = f.store.current.cloudASRConfig.providers.first { $0.id == dash.id }!; changed.model = "changed-model"
            try env.actions(navigation: nil).saveCloud!(.init(target: .existing(dash.id), profile: changed, keyEdit: .replace("replacement-key")))
            vm.refresh()
            r.check(vm.isBusy && env.validation.isTesting(profileID: dash.id), "C4 I3 edited profile keeps old transport owner while draining")
            await editedSession.waitUntilCleanupHeld()
            await editedSession.release(); await edited.value
            r.eq(clock.pending, 0, "C4 I3 edited validation drains timer continuation")
            r.eq(f.store.current.asrBackendSelection?.primary, f.id, "C4 I3 profile/key change prevents late selection commit")
            r.check(vm.currentValidatedServices.allSatisfy { $0.backendID != id }, "C4 I3 profile/key change prevents stale evidence")
        } catch { r.check(false, "C4 I3 realtime fixture: \(error)") }
    }

    @MainActor private static func renderRecovery(_ r: SelfTest.Reporter, environment: ASRModelCenterEnvironment,
                                                   id: ASRBackendID, state: String) async {
        #if DEBUG
        do {
            guard let row = environment.model.rows.first(where: { $0.id == id }) else { return }
            let actions = environment.actions(navigation: nil)
            let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("c4-recovery-previews")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for dark in [false, true] {
                let detail = ASRModelDetail(row: row, model: environment.model, config: actions.configuration?(), actions: actions, edit: {})
                let host = await NativeClientPreviewSelfTests.renderHost(AnyView(detail.background(Theme.pageBackground)), width: 480, height: 700, dark: dark)
                try NativeClientPreviewSelfTests.capture(host, to: root.appendingPathComponent("\(state)-\(dark ? "dark" : "light").png"))
            }
            print("C4 recovery preview: \(root.path) / \(state)")
        } catch { r.check(false, "C4 I2 recovery preview: \(error)") }
        #endif
    }

    final class NativeFailure: @unchecked Sendable { var failCandidate = false }
    final class RealtimeProbe: @unchecked Sendable {
        enum Mode { case success, empty, held }
        private let lock = NSLock()
        private var selectedMode: Mode = .success, configs: [RealtimeASRConfiguration] = [], sessions: [RealtimeFixture] = []
        private var sessionWaiters: [Int: [CheckedContinuation<RealtimeFixture, Never>]] = [:]
        private var requestWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
        var mode: Mode { get { lock.withLock { selectedMode } } set { lock.withLock { selectedMode = newValue } } }
        var configurations: [RealtimeASRConfiguration] { lock.withLock { configs } }
        var latest: RealtimeFixture? { lock.withLock { sessions.last } }
        func make(_ config: RealtimeASRConfiguration) -> RealtimeASRSessionHandle {
            lock.withLock {
                let ordinal = sessions.count
                configs.append(config)
                let session = RealtimeFixture(mode: selectedMode, ordinal: ordinal); sessions.append(session)
                sessionWaiters.removeValue(forKey: ordinal)?.forEach { $0.resume(returning: session) }
                return .init(session: session, ingress: .init(), capabilities: DashScopeRealtimeASR.capabilities)
            }
        }
        func session(at ordinal: Int) async -> RealtimeFixture {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if sessions.indices.contains(ordinal) { continuation.resume(returning: sessions[ordinal]); return }
                    sessionWaiters[ordinal, default: []].append(continuation)
                    requestWaiters.removeValue(forKey: ordinal)?.forEach { $0.resume() }
                }
            }
        }
        func waitUntilSessionRequested(at ordinal: Int) async {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if sessionWaiters[ordinal] != nil { continuation.resume() }
                    else { requestWaiters[ordinal, default: []].append(continuation) }
                }
            }
        }
    }
    actor RealtimeFixture: RealtimeASRSession {
        let mode: RealtimeProbe.Mode
        nonisolated let ordinal: Int
        var chunks: [[Float]] = [], starts = 0, finishes = 0, cancelled = false, waiting = false, cleanupWaiting = false
        private var continuation: CheckedContinuation<Void, Never>?, cleanup: CheckedContinuation<Void, Never>?
        private var finishWaiters: [CheckedContinuation<Void, Never>] = [], cleanupWaiters: [CheckedContinuation<Void, Never>] = []
        init(mode: RealtimeProbe.Mode, ordinal: Int) { self.mode = mode; self.ordinal = ordinal }
        func start() async throws { starts += 1 }
        func append(samples: [Float]) async throws { chunks.append(samples) }
        func finish() async throws -> ASRResult {
            finishes += 1
            if mode == .held {
                await withCheckedContinuation {
                    continuation = $0; waiting = true
                    finishWaiters.forEach { $0.resume() }; finishWaiters.removeAll()
                }
            }
            return .init(text: mode == .empty ? " " : "synthetic realtime", providerID: "fixture", latencyMs: 1)
        }
        func waitUntilFinishHeld() async {
            if waiting { return }
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        func cancel() async {
            cancelled = true
            if mode == .held && waiting {
                await withCheckedContinuation {
                    cleanup = $0; cleanupWaiting = true
                    cleanupWaiters.forEach { $0.resume() }; cleanupWaiters.removeAll()
                }
            }
        }
        func waitUntilCleanupHeld() async {
            if cleanupWaiting { return }
            await withCheckedContinuation { cleanupWaiters.append($0) }
        }
        func diagnostic() -> String { "session=\(ordinal) starts=\(starts) finishes=\(finishes) finishHeld=\(waiting) cancelled=\(cancelled) cleanupHeld=\(cleanupWaiting)" }
        func releaseFinish() { waiting = false; continuation?.resume(); continuation = nil }
        func releaseCleanup() { cleanupWaiting = false; cleanup?.resume(); cleanup = nil }
        func release() { releaseFinish(); releaseCleanup() }
    }

    /// Drives the real DeadlineRace timer, preserving cancellation and exact timer identity.
    final class DeadlineClock: @unchecked Sendable {
        struct Ticket: Sendable { let id: UUID; let seconds: TimeInterval }
        private let lock = NSLock()
        private var tickets: [Ticket] = []
        private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var observers: [Int: [CheckedContinuation<Ticket, Never>]] = [:]
        var count: Int { lock.withLock { tickets.count } }
        var pending: Int { lock.withLock { sleepers.count } }
        func sleep(_ seconds: TimeInterval) async throws {
            let ticket = Ticket(id: UUID(), seconds: seconds)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock {
                        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                        let ordinal = tickets.count; tickets.append(ticket); sleepers[ticket.id] = continuation
                        observers.removeValue(forKey: ordinal)?.forEach { $0.resume(returning: ticket) }
                    }
                }
            } onCancel: {
                self.lock.withLock { self.sleepers.removeValue(forKey: ticket.id) }?.resume(throwing: CancellationError())
            }
        }
        func timer(at ordinal: Int) async -> Ticket {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if tickets.indices.contains(ordinal) { continuation.resume(returning: tickets[ordinal]) }
                    else { observers[ordinal, default: []].append(continuation) }
                }
            }
        }
        func expire(_ ticket: Ticket) -> Bool {
            guard let continuation = lock.withLock({ sleepers.removeValue(forKey: ticket.id) }) else { return false }
            continuation.resume(); return true
        }
    }
    private final class DiscoveryTransport: URLProtocol, @unchecked Sendable {
        private static let captured = OSAllocatedUnfairLock(initialState: [URLRequest]())
        static var requests: [URLRequest] { captured.withLock { $0 } }
        static func reset() { captured.withLock { $0 = [] } }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.captured.withLock { $0.append(request) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"fixture-asr"}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
