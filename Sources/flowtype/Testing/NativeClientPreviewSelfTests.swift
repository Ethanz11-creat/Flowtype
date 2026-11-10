#if DEBUG
import AppKit
import SwiftUI
import GRDB

/// Development-only real SwiftUI rendering. No application/window, screen capture or live effects.
enum NativeClientPreviewSelfTests {
    private struct PreviewRecord: Encodable {
        let file: String
        let width: Int
        let height: Int
        let appearance: String
        let destination: String
        let position: String
    }
    private enum FixtureError: Error { case unavailable, bitmap }

    @MainActor static func run(_ r: SelfTest.Reporter) async {
        let effects = ValidationEffects.live.snapshot
        do {
            let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("native-client-previews")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = RuntimeEnvironment.current.paths.applicationSupportDirectory.appendingPathComponent("preview-fixtures")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            let store = ConfigurationStore(defaults: RuntimeEnvironment.defaults)
            var config = store.current
            config.asrRoutingPolicy = .auto
            config.polishOnStop = true
            var provider = CloudASRVendor.makeProfile(.openAI, isActive: true)
            provider.name = "项目转写服务 · 长名称 Mixed Language"
            provider.model = "synthetic-long-model-name-for-native-layout-2026"
            provider.baseURL = "https://example.invalid/long-team/transcription/v1"
            config.cloudASRConfig.providers = [provider]
            store.save(config)
            let dictionary = DictionaryStore(store: PersistentStore(filename: "dictionary.json", directory: fixture))
            for index in 0..<18 {
                dictionary.add(phrase: "原生客户端 SwiftUI mixed-language 专业术语 \(index)",
                               note: "长内容说明：保留用户原意，显示英文 API 与中文标点。用于原生布局观察。")
            }
            let styles = StylePackStore(store: PersistentStore(filename: "styles.json", directory: fixture))
            _ = styles.createCustom(name: "产品与工程周报 · Mixed-language 长风格名称", prompt: String(repeating: "整理为清楚的段落，保留技术名称、emoji 🙂 与中英混合内容。\n", count: 12))
            let now = Date(timeIntervalSince1970: 1_793_635_200)
            let stats = (0..<365).filter { $0 % 3 != 0 }.map { offset -> DailyStats in
                let date = Calendar.current.date(byAdding: .day, value: -offset, to: now)!
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                var histogram = Array(repeating: 0, count: 24)
                histogram[(offset + 9) % 24] = offset % 3 + 1
                return DailyStats(date: f.string(from: date), totalDurationMs: 180000, totalWordCount: 240 + offset,
                    sessionCount: offset % 3 + 1, totalRecordingMs: 120000, hourHistogram: histogram)
            }
            let statsStore = DailyStatsStore(stats: stats, readStats: { stats })
            let emptyStats = DailyStatsStore(stats: [], readStats: { [] })
            let emptyDictionary = DictionaryStore(store: PersistentStore(filename: "empty-dictionary.json", directory: fixture))
            let db = try AppDatabase(try DatabaseQueue(path: fixture.appendingPathComponent("history.sqlite").path), isOnDisk: true)
            let sessions = (0..<12).map { index -> DictationSession in
                var value = DictationSession(rawTranscript: "原始识别 \(index)：这是一段中英混合记录，包含 SwiftUI、API、emoji 🙂。", finalText: String(repeating: "最终文本：项目讨论与技术方案，保留用户表达。SwiftUI native client 🙂\n", count: 12), polishMode: .polish,
                    durationMs: 18000, recordingMs: 10000, appName: "Synthetic Editor", appBundleID: "test.preview", language: "zh", sttBackend: "cloud-asr")
                value.deliveryOutcome = index == 0 ? .uncertain : .pasteDispatched
                return value
            }
            let history = HistoryStore(database: db, readSessions: { sessions }, refreshStats: {})
            let emptyHistory = HistoryStore(database: db, readSessions: { [] }, refreshStats: {})
            let errorHistory = HistoryStore(database: db, readSessions: { throw FixtureError.unavailable }, refreshStats: {})
            let snapshot = ReadinessSnapshot(accessibility: .denied, microphone: .denied, speechRecognition: .notDetermined,
                localModel: .unavailable(reason: "尚未加载本地模型"), cloudASR: .ready,
                appleSpeech: .unavailable(reason: "未授权"), computedAt: now)
            let monitor = ReadinessMonitor(snapshot: snapshot, refresh: { snapshot })
            let coordinator = LocalSettingsOwnershipSelfTests.coordinator(store: store)
            let downloader = ModelDownloader(coordinator: coordinator, configuration: { store.current })
            let actions = ImportedASRModelActions(coordinator: coordinator, configuration: { store.current })
            let checks = CloudASRConnectionCheck(recognitionTest: { _, _ in .success("Synthetic") })
            let draftChecks = CloudASRConnectionCheck(recognitionTest: { _, _ in .success("Synthetic") })
            var records: [PreviewRecord] = []
            let sizes = [(1040, 700, "minimum"), (1120, 760, "default"), (1440, 900, "wide")]
            for (width, height, size) in sizes {
                for dark in [false, true] {
                    for page in ["overview", "settings-speech", "settings-text", "settings-general", "settings-privacy", "history", "dictionary", "style"] {
                        let navigation = SettingsNavigation()
                        let destination: ClientDestination
                        switch page {
                        case "history": destination = .history(sessions.first?.id)
                        case "dictionary": destination = .tab(.vocab)
                        case "style": destination = .style("builtin.structured")
                        case "settings-speech": destination = .settings(.speech)
                        case "settings-text": destination = .settings(.text)
                        case "settings-general": destination = .settings(.general)
                        case "settings-privacy": destination = .settings(.privacy)
                        default: destination = .tab(.overview)
                        }
                        navigation.navigate(to: destination)
                        let view = MainWindowView(navigation: navigation, page: { tab in
                            switch tab {
                            case .overview: AnyView(OverviewPage(statsStore: statsStore, dictionaryStore: dictionary, now: { now }, openDictionary: {}))
                            case .history: AnyView(HistoryPage(historyStore: history, copy: { _ in }, export: { _ in }))
                            case .vocab: AnyView(VocabPage(store: dictionary))
                            case .style: AnyView(StylePage(store: styles, export: { _, _ in }))
                            case .settings: AnyView(SettingsPage(navigation: navigation, store: store, styleStore: styles, monitor: monitor,
                                modelState: coordinator, downloader: downloader, importedActions: actions,
                                trialPresenter: TrialSessionPresenter(configuration: store, resources: SessionResourceCoordinator(),
                                    refreshReadiness: { monitor.rawLevel }, readinessLevel: { monitor.rawLevel }, copy: { _ in }),
                                connectionChecks: SettingsConnectionChecks(configuration: store, checks: checks, draftChecks: draftChecks),
                                devices: { [] }))
                            }
                        })
                        let prefix = "\(page)-\(size)-\(dark ? "dark" : "light")"
                        let host = await renderHost(AnyView(view), width: width, height: height, dark: dark)
                        try capture(host, to: root.appendingPathComponent(prefix + ".png"))
                        records.append(.init(file: prefix + ".png", width: width, height: height, appearance: dark ? "dark" : "light", destination: page, position: "top"))

                    }
                }
            }
            for (name, view) in [
                ("overview-empty", AnyView(OverviewPage(statsStore: emptyStats, dictionaryStore: emptyDictionary, now: { now }, openDictionary: {}))),
                ("history-empty", AnyView(HistoryPage(historyStore: emptyHistory, copy: { _ in }, export: { _ in }))),
                ("history-error", AnyView(HistoryPage(historyStore: errorHistory, copy: { _ in }, export: { _ in }))),
                ("dictionary-empty", AnyView(VocabPage(store: emptyDictionary)))
            ] {
                for dark in [false, true] {
                    let file = "\(name)-default-\(dark ? "dark" : "light").png"
                    let tab: AppTab = name.hasPrefix("history") ? .history : name.hasPrefix("dictionary") ? .vocab : .overview
                    let navigation = SettingsNavigation(initialTab: tab)
                    let wrapped = MainWindowView(navigation: navigation, page: { _ in view })
                    let host = await renderHost(AnyView(wrapped), width: 1120, height: 760, dark: dark)
                    try capture(host, to: root.appendingPathComponent(file))
                    records.append(.init(file: file, width: 1120, height: 760, appearance: dark ? "dark" : "light", destination: name, position: "top"))
                }
            }
            // C3: actual model-center views with isolated configuration and injected effects only.
            for state in ["model-center", "model-center-loading", "model-center-empty", "model-center-error", "model-center-long-content", "model-center-download"] {
                var centerConfig = Configuration()
                centerConfig.asrRoutingPolicy = .auto
                centerConfig.localASRServices = [LocalASRServicePreset.whisperCpp.makeProfile(baseURL: "http://127.0.0.1:8123", modelID: nil)]
                centerConfig.cloudASRConfig.providers = state == "model-center-empty" ? [] : [provider]
                let long = state == "model-center-long-content" || state == "model-center-error"
                let imported = ImportedASRModel(name: long ? "团队离线转写模型 · Mixed Language Qwen3-ASR 0.6B 4-bit 长名称与兼容性说明" : "Qwen3-ASR 0.6B · 团队模型",
                    directory: fixture.appendingPathComponent(long ? "Models/团队共享/2026/项目讨论与产品工程记录/aufklarer-Qwen3-ASR-0.6B-MLX-4bit-fixed-revision" : "Models/Qwen3-ASR-0.6B"),
                    engine: .qwenMLX, variant: "0.6B", bits: 4, sizeBytes: 642_518_320, tokenizerDirectory: nil, fileFingerprint: "preview-only")
                centerConfig.importedASRModels = [imported]
                let nativeID = ASRBackendID(rawValue: "native:import:" + imported.id.uuidString)
                centerConfig.setASRBackendSelection(.init(primary: nativeID))
                store.save(centerConfig)
                let plan = ASRInstallPlan(id: UUID(), displayName: "Whisper base · 多语言 Core ML", engine: .whisperCoreML, files: [], totalBytes: 318_000_000, recipeID: nil, recipeVersion: 1, credentialID: nil)
                let failedPlan = ASRInstallPlan(id: UUID(), displayName: "Qwen3-ASR 1.7B · 暂停后可恢复", engine: .qwenMLX, files: [], totalBytes: 1_280_000_000, recipeID: nil, recipeVersion: 1, credentialID: nil)
                let jobs: [ModelInstallSnapshot] = state == "model-center-download" ? [
                    .init(jobID: plan.id, plan: plan, state: .downloading, receivedBytes: 124_500_000, errorCode: nil),
                    .init(jobID: failedPlan.id, plan: failedPlan, state: .failed, receivedBytes: 28_300_000, errorCode: "network: 连接中断；已保留部分文件，请检查下载源后继续。")
                ] : []
                let generation = UUID()
                let validation = ASRServiceValidationCoordinator(session: nil, resolver: { _ in ["127.0.0.1"] }, now: { now },
                    serviceRecognition: { _, _, _ in "你好，这是语音识别测试。" }, cloudRecognition: { _, _, _ in "你好，这是语音识别测试。" })
                let center = ASRModelCenterViewModel(configuration: { store.current }, persist: { store.save($0) }, native: coordinator,
                    validation: validation, credential: { _ in .init(value: nil, generation: generation) },
                    sample: { try ASRValidationSampleStore.load(language: .zh) }, installationSnapshots: { jobs }, now: { now })
                await center.refreshInstallations()
                center.selectedID = long ? nativeID : centerConfig.localASRServices.first.map { .init(rawValue: "service:" + $0.id.uuidString) }
                if state == "model-center" { await center.test(center.selectedID!) }
                if state == "model-center-empty" || state == "model-center-loading" { center.selectedID = nil }
                let hf = HFModelInstallSession(resolve: { _, _, _ in throw FixtureError.unavailable }, plan: { _, _, _, _ in throw FixtureError.unavailable }, enqueue: { _ in throw FixtureError.unavailable })
                let centerActions = ASRModelCenterUIActions(configuration: { store.current }, importedActions: actions,
                    hfSession: hf, discovery: ASRModelDiscoveryClient(), draftChecks: draftChecks,
                    chooseDirectory: { nil }, persistImported: { store.save($0) }, saveLocal: { _ in throw FixtureError.unavailable },
                    saveCloud: { _ in throw FixtureError.unavailable }, hasCredential: { _ in false }, credential: { _ in nil },
                    saveHFToken: { _ in throw FixtureError.unavailable }, copy: { _ in },
                    removalReason: { _, _ in nil }, pause: { _ in }, resume: { _ in }, cancel: { _ in }, clearPartial: { _ in },
                    loading: state == "model-center-loading", loadError: state == "model-center-error" ? "模型配置不可用：保留旧选择。候选目录缺少完整分词器与模型权重；请核对固定版本和目录结构，重新检查后再试用。错误详情保持完整展示，不以省略号隐藏恢复线索。" : nil)
                for (width, height, size) in sizes {
                    for dark in [false, true] {
                        let navigation = SettingsNavigation(); navigation.navigate(to: .settings(.speech))
                        let centerView = ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                Text("识别设置").font(Theme.Typography.pageTitle)
                                ASRModelCenterView(model: center, actions: centerActions, initialSource: state == "model-center-empty" ? ASRBackendLocation.cloud.rawValue : "all")
                            }.padding(24).frame(maxWidth: 1160).frame(maxWidth: .infinity)
                        }.background(Theme.pageBackground)
                        let wrapped = MainWindowView(navigation: navigation, page: { _ in AnyView(centerView) })
                        let file = "\(state)-\(size)-\(dark ? "dark" : "light").png"
                        let host = await renderHost(AnyView(wrapped), width: width, height: height, dark: dark)
                        try capture(host, to: root.appendingPathComponent(file))
                        records.append(.init(file: file, width: width, height: height, appearance: dark ? "dark" : "light", destination: state, position: "top"))
                        if state == "model-center-download" {
                            let taskView = MainWindowView(navigation: navigation, page: { _ in AnyView(
                                ScrollView { VStack(alignment: .leading, spacing: 18) {
                                    Text("安装任务").font(Theme.Typography.pageTitle)
                                    Text("下载由应用管理，关闭模型中心继续保留任务。").foregroundStyle(.secondary)
                                    ModelInstallationList(installations: center.installations, actions: centerActions, refresh: {})
                                }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading) }.background(Theme.pageBackground)) })
                            let taskFile = "\(state)-tasks-\(size)-\(dark ? "dark" : "light").png"
                            let taskHost = await renderHost(AnyView(taskView), width: width, height: height, dark: dark)
                            try capture(taskHost, to: root.appendingPathComponent(taskFile))
                            records.append(.init(file: taskFile, width: width, height: height, appearance: dark ? "dark" : "light", destination: state, position: "installation-component"))
                        }
                    }
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: root.appendingPathComponent("manifest.json"))
            r.check(!records.isEmpty, "native preview generated actual SwiftUI PNGs")
            print("Native preview artifacts: \(root.path) (\(records.count) PNGs)")
        } catch { r.check(false, "native preview failed: \(error)") }
        r.eq(ValidationEffects.live.snapshot.blocked, effects.blocked, "native preview attempts no prohibited system effects")
        r.eq(ValidationEffects.live.snapshot.permitted, effects.permitted, "native preview performs no live system effects")
    }

    @MainActor static func renderHost(_ view: AnyView, width: Int, height: Int, dark: Bool) async -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for _ in 0..<8 {
            settleNativeLayout(host)
            try? await Task.sleep(for: .milliseconds(20))
        }
        return host
    }
    @MainActor private static func settleNativeLayout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor static func capture(_ host: NSView, to file: URL, pixelScale: Int? = nil) throws {
        host.layoutSubtreeIfNeeded()
        let representation: NSBitmapImageRep?
        if let scale = pixelScale {
            representation = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(host.bounds.width) * scale, pixelsHigh: Int(host.bounds.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            representation?.size = host.bounds.size
        } else { representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) }
        guard let bitmap = representation else { throw FixtureError.bitmap }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw FixtureError.bitmap }
        try data.write(to: file)
    }
}
#endif
