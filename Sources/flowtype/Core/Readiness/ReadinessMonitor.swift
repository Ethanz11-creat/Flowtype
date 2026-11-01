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
                     appleAvailable: Bool, computedAt: Date) -> ReadinessSnapshot {
        let local: EngineReadiness
        if config.asrRoutingPolicy == .cloudOnly {
            local = .unavailable(reason: "仅云端模式")
        } else {
            switch modelStatus {
            case .ready: local = .ready
            case .downloading(let progress, _, _): local = .provisioning(progress: progress)
            case .loading, .stalled: local = .provisioning(progress: 0)
            case .notLoaded:
                local = config.hasCompletedOnboarding
                    ? .provisioning(progress: 0) : .unavailable(reason: "本地模型未加载")
            case .error(let reason, _): local = .unavailable(reason: reason)
            }
        }

        let cloud: EngineReadiness
        if config.asrRoutingPolicy == .localOnly {
            cloud = .unavailable(reason: "仅本地模式")
        } else if let cloudConfig = config.effectiveCloudASRConfig,
                  !cloudConfig.apiKey.isEmpty, !cloudConfig.provider.baseURL.isEmpty,
                  !cloudConfig.provider.model.isEmpty {
            cloud = networkReachable ? .ready : .unavailable(reason: "网络不可达")
        } else {
            cloud = .unavailable(reason: "云端未配置")
        }

        let apple: EngineReadiness
        if config.asrRoutingPolicy != .auto {
            apple = .unavailable(reason: "当前路由未启用 Apple 识别")
        } else if speechRecognition != .granted {
            apple = .unavailable(reason: "语音识别权限未开启")
        } else {
            apple = appleAvailable ? .ready : .unavailable(reason: "Apple 识别不可用")
        }
        return ReadinessSnapshot(accessibility: accessibility, microphone: microphone,
                                 speechRecognition: speechRecognition, localModel: local,
                                 cloudASR: cloud, appleSpeech: apple, computedAt: computedAt)
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

    init() {
        let snapshot = Self.makeSnapshot()
        let level = classifyReadiness(snapshot)
        self.snapshot = snapshot
        self.level = level
        debounce = ReadinessDebounce(level: level)

        QwenModelState.shared.$status.sink { [weak self] _ in
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

    func refresh() {
        let oldAccessibility = snapshot.accessibility
        snapshot = Self.makeSnapshot()
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

    private static func makeSnapshot() -> ReadinessSnapshot {
        let config = ConfigurationStore.shared.current
        let speechRecognition = PermissionHelper.speechRecognitionState()
        let appleAvailable = config.asrRoutingPolicy == .auto && speechRecognition == .granted
            && SFSpeechRecognizer(locale: Locale(identifier: config.asrLanguage.appleLocaleIdentifier))?.isAvailable == true
        return ReadinessSnapshotBuilder.make(
            config: config, modelStatus: QwenModelState.shared.status,
            accessibility: PermissionHelper.accessibilityState(), microphone: PermissionHelper.microphoneState(),
            speechRecognition: speechRecognition, networkReachable: ASRRouter.shared.snapshot().networkReachable,
            appleAvailable: appleAvailable, computedAt: Date())
    }
}
