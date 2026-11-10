import AppKit
import Combine
import Foundation
import Speech

struct PermissionWatchPolicy {
    static let interval: Duration = .seconds(2)
    static let maxPolls = 30

    nonisolated static func shouldStop(accessibility: PermissionState, pollsCompleted: Int) -> Bool {
        accessibility == .granted || pollsCompleted >= maxPolls
    }
}

/// Tracks deadlines independently of refresh frequency and rejects superseded timers.
struct ReadinessDebounce {
    private(set) var level: ReadinessLevel
    private var pending: (id: UUID, level: ReadinessLevel)?
    var hasPending: Bool { pending != nil }

    init(level: ReadinessLevel) {
        self.level = level
    }

    mutating func receive(_ candidate: ReadinessLevel) -> UUID? {
        guard candidate != level else {
            pending = nil
            return nil
        }
        // Model progress and permission polling may refresh faster than the debounce.
        guard pending?.level != candidate else { return nil }
        let id = UUID()
        pending = (id, candidate)
        return id
    }

    mutating func publish(_ id: UUID) -> ReadinessLevel? {
        guard let pending, pending.id == id else { return nil }
        level = pending.level
        self.pending = nil
        return level
    }
}

/// A cancelled task can finish after a replacement has already started.
struct PermissionWatchOwnership {
    private var id: UUID?

    mutating func start(accessibility: PermissionState) -> UUID? {
        guard accessibility != .granted, id == nil else { return nil }
        let id = UUID()
        self.id = id
        return id
    }

    mutating func stop() { id = nil }

    mutating func finish(_ id: UUID) -> Bool {
        guard self.id == id else { return false }
        self.id = nil
        return true
    }
}

/// Pure aggregation keeps readiness rules testable without prompting or changing settings.
enum ReadinessSnapshotBuilder {
    static func make(config: Configuration, modelStatus: QwenModelStatus,
                     accessibility: PermissionState, microphone: PermissionState,
                     speechRecognition: PermissionState, networkReachable: Bool,
                     appleAvailable: Bool, computedAt: Date,
                     backends: [ASRBackendDescriptor] = [], availableIDs: Set<ASRBackendID> = []) -> ReadinessSnapshot {
        var projected = config
        projected.migrateASRBackendSelectionIfNeeded()
        var selection = ASRBackendMigration.selection(from: projected)
        // Pending legacy intent may use only the actual loaded native identity
        // supplied by the caller. Explicit cleared/unknown selections stay intact.
        let loadedNativeBackends = backends.filter { $0.location == .native && availableIDs.contains($0.id) }
        if projected.pendingLegacyNativeResolution, loadedNativeBackends.count == 1,
           let loaded = loadedNativeBackends.first {
            if config.asrRoutingPolicy == .localOnly { selection.primary = loaded.id }
            else if config.asrRoutingPolicy == .auto { selection.fallback = loaded.id }
        }
        let eligible = ASRBackendRouting.order(selection: selection, policy: config.asrRoutingPolicy,
            descriptors: backends, availableIDs: Set(backends.map(\.id)), internetAvailable: true, degradedIDs: [])
        let ready = ASRBackendRouting.order(selection: selection, policy: config.asrRoutingPolicy,
            descriptors: backends, availableIDs: availableIDs, internetAvailable: networkReachable, degradedIDs: [])
        var states: [ASRBackendID: EngineReadiness] = [:]
        for descriptor in backends where eligible.contains(descriptor.id) {
            if ready.contains(descriptor.id) { states[descriptor.id] = .ready; continue }
            switch descriptor.location {
            case .native:
                switch modelStatus {
                case .downloading(let progress, _, _): states[descriptor.id] = .provisioning(progress: progress)
                case .loading, .stalled: states[descriptor.id] = .provisioning(progress: 0)
                case .error(let reason, _): states[descriptor.id] = .unavailable(reason: reason)
                case .ready, .notLoaded: states[descriptor.id] = .unavailable(reason: "本地模型未加载")
                }
            case .loopbackService: states[descriptor.id] = .unavailable(reason: "本机服务尚未验证或不可用")
            case .cloud: states[descriptor.id] = .unavailable(reason: descriptor.requiresInternet && !networkReachable
                ? "网络不可达" : "云端未配置或凭据不可用")
            }
        }
        func aggregate(cloud: Bool) -> EngineReadiness {
            let candidates = backends.filter { ($0.location == .cloud) == cloud }.compactMap { states[$0.id] }
            if candidates.contains(.ready) { return .ready }
            if let preparing = candidates.first(where: { if case .provisioning = $0 { return true }; return false }) { return preparing }
            return candidates.first ?? .unavailable(reason: cloud
                ? (config.asrRoutingPolicy == .localOnly ? "仅本地模式" : "云端未配置")
                : (config.asrRoutingPolicy == .cloudOnly ? "仅云端模式" : "本地模型未加载"))
        }
        let apple: EngineReadiness
        if config.asrRoutingPolicy != .auto { apple = .unavailable(reason: "当前路由未启用 Apple 识别") }
        else if speechRecognition != .granted { apple = .unavailable(reason: "语音识别权限未开启") }
        else { apple = appleAvailable ? .ready : .unavailable(reason: "Apple 识别不可用") }
        return ReadinessSnapshot(accessibility: accessibility, microphone: microphone,
            speechRecognition: speechRecognition, localModel: aggregate(cloud: false), cloudASR: aggregate(cloud: true),
            appleSpeech: apple, computedAt: computedAt, backends: backends, backendStates: states,
            readyBackendIDs: ready, selectedBackendID: selection.primary ?? selection.fallback)
    }

    static func logLine(level: ReadinessLevel, snapshot: ReadinessSnapshot) -> String {
        let levelTag: String
        switch level {
        case .ready: levelTag = "ready"
        case .degraded: levelTag = "degraded"
        case .blocked: levelTag = "blocked"
        }
        func engineTag(_ state: EngineReadiness) -> String {
            switch state {
            case .ready: return "ready"
            case .provisioning: return "provisioning"
            case .unavailable: return "unavailable"
            }
        }
        return "[ReadinessMonitor] level=\(levelTag) ax=\(snapshot.accessibility) mic=\(snapshot.microphone) local=\(engineTag(snapshot.localModel)) cloud=\(engineTag(snapshot.cloudASR)) apple=\(engineTag(snapshot.appleSpeech))"
    }
}

@MainActor
final class ReadinessMonitor: ObservableObject {
    static let shared = ReadinessMonitor()

    @Published private(set) var snapshot: ReadinessSnapshot
    @Published private(set) var level: ReadinessLevel
    var rawLevel: ReadinessLevel { classifyReadiness(snapshot) }
    var onAccessibilityGranted: (@MainActor @Sendable () -> Void)?

    private var subscriptions = Set<AnyCancellable>()
    private var debounce: ReadinessDebounce
    private var debounceTask: Task<Void, Never>?
    private var permissionWatchOwnership = PermissionWatchOwnership()
    private var permissionWatchTask: Task<Void, Never>?
    private var snapshotProvider: (() -> ReadinessSnapshot)?
    /// Current-process successful recognition only. C4 owns invalidation and refresh;
    /// persisted historical validation records must never be supplied after restart.
    private var currentValidatedServices: () -> [ASRServiceValidationRecord] = { [] }

    /// Explicit isolated source for previews/tests; never initializes shared services.
    init(snapshot: ReadinessSnapshot, refresh: (() -> ReadinessSnapshot)? = nil) {
        self.snapshot = snapshot
        let level = classifyReadiness(snapshot)
        self.level = level
        debounce = ReadinessDebounce(level: level)
        snapshotProvider = refresh ?? { snapshot }
    }

    init(currentValidatedServices: @escaping () -> [ASRServiceValidationRecord] = { [] }) {
        self.currentValidatedServices = currentValidatedServices
        let snapshot = Self.makeSnapshot(currentValidatedServices: currentValidatedServices())
        let level = classifyReadiness(snapshot)
        self.snapshot = snapshot
        self.level = level
        debounce = ReadinessDebounce(level: level)

        QwenModelState.shared.$status.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &subscriptions)
        QwenModelState.shared.$activeLease.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &subscriptions)
        ConfigurationStore.shared.$current.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }.store(in: &subscriptions)
    }

    deinit {
        debounceTask?.cancel()
        permissionWatchTask?.cancel()
    }

    func connectCurrentValidation(_ source: @escaping () -> [ASRServiceValidationRecord]) {
        currentValidatedServices = source
        refresh()
    }

    func refresh() {
        let oldAccessibility = snapshot.accessibility
        snapshot = snapshotProvider?() ?? Self.makeSnapshot(currentValidatedServices: currentValidatedServices())
        publishIfChanged(rawLevel)
        if oldAccessibility != .granted, snapshot.accessibility == .granted {
            stopPermissionWatch()
            onAccessibilityGranted?()
        }
    }

    func startPermissionWatchIfNeeded() {
        guard let id = permissionWatchOwnership.start(accessibility: snapshot.accessibility) else { return }
        permissionWatchTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.permissionWatchOwnership.finish(id) {
                    self.permissionWatchTask = nil
                }
            }
            for pollsCompleted in 1...PermissionWatchPolicy.maxPolls {
                do {
                    try await Task.sleep(for: PermissionWatchPolicy.interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.refresh()
                if PermissionWatchPolicy.shouldStop(accessibility: self.snapshot.accessibility,
                                                    pollsCompleted: pollsCompleted) { return }
            }
        }
    }

    func stopPermissionWatch() {
        permissionWatchOwnership.stop()
        permissionWatchTask?.cancel()
        permissionWatchTask = nil
    }

    private func publishIfChanged(_ candidate: ReadinessLevel) {
        let id = debounce.receive(candidate)
        if !debounce.hasPending {
            debounceTask?.cancel()
            debounceTask = nil
            return
        }
        guard let id else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let level = self.debounce.publish(id) else { return }
            self.debounceTask = nil
            self.level = level
            AppLogger.log(ReadinessSnapshotBuilder.logLine(level: level, snapshot: self.snapshot))
        }
    }

    private static func makeSnapshot(currentValidatedServices: [ASRServiceValidationRecord]) -> ReadinessSnapshot {
        let config = ConfigurationStore.shared.current
        let speechRecognition = PermissionHelper.speechRecognitionState()
        let appleAvailable = config.asrRoutingPolicy == .auto && speechRecognition == .granted
            && SFSpeechRecognizer(locale: Locale(identifier: config.asrLanguage.appleLocaleIdentifier))?.isAvailable == true
        let backendAvailability = ASRRouter.shared.readinessBackends(currentValidatedServices: currentValidatedServices)
        return ReadinessSnapshotBuilder.make(
            config: config, modelStatus: QwenModelState.shared.status,
            accessibility: PermissionHelper.accessibilityState(), microphone: PermissionHelper.microphoneState(),
            speechRecognition: speechRecognition, networkReachable: ASRRouter.shared.snapshot().networkReachable,
            appleAvailable: appleAvailable, computedAt: Date(), backends: backendAvailability.backends,
            availableIDs: backendAvailability.availableIDs)
    }
}
