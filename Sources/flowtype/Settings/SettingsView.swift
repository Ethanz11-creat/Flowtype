import SwiftUI

struct SettingsPage: View {
    let navigation: SettingsNavigation?
    private var devices: () -> [AudioDevice] = { AudioRecorder.availableInputDevices() }
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var styleStore: StylePackStore
    @ObservedObject var monitor: ReadinessMonitor
    @ObservedObject var modelState: QwenModelState
    @ObservedObject var downloader: ModelDownloader
    @StateObject var importedActions: ImportedASRModelActions
    let connectionChecks: SettingsConnectionChecks
    @ObservedObject var checks: CloudASRConnectionCheck
    @ObservedObject var draftChecks: CloudASRConnectionCheck
    @Environment(\.clientNavigationRequest) private var request
    @State private var location = SettingsLocation()
    @State private var showsTrial = false
    @StateObject var trialPresenter: TrialSessionPresenter
    @State var providerDraft: LLMProviderDraft?

    /// Production composition boundary. Reusable constructors below resolve no singletons.
    init(navigation: SettingsNavigation? = nil, connectionChecks: SettingsConnectionChecks = .shared) {
        let store = ConfigurationStore.shared
        let coordinator = QwenModelState.shared
        let monitor = ReadinessMonitor.shared
        self.init(navigation: navigation, store: store, styleStore: .shared, monitor: monitor,
                  modelState: coordinator, downloader: .shared,
                  importedActions: ImportedASRModelActions(coordinator: coordinator, configuration: { store.current }),
                  trialPresenter: TrialSessionPresenter(configuration: store, resources: .shared,
                    refreshReadiness: { monitor.refresh(); return monitor.rawLevel },
                    readinessLevel: { monitor.refresh(); return monitor.rawLevel },
                    copy: { KeyboardInjector.copyText($0) }), connectionChecks: connectionChecks)
    }

    init(navigation: SettingsNavigation? = nil, store: ConfigurationStore, styleStore: StylePackStore,
         monitor: ReadinessMonitor, modelState: QwenModelState, downloader: ModelDownloader,
         importedActions: ImportedASRModelActions, trialPresenter: TrialSessionPresenter,
         connectionChecks: SettingsConnectionChecks,
         devices: @escaping () -> [AudioDevice] = { AudioRecorder.availableInputDevices() }) {
        self.navigation = navigation
        self.devices = devices
        self.store = store
        self.styleStore = styleStore
        self.monitor = monitor
        self.modelState = modelState
        self.downloader = downloader
        _trialPresenter = StateObject(wrappedValue: trialPresenter)
        _importedActions = StateObject(wrappedValue: importedActions)
        self.connectionChecks = connectionChecks
        checks = connectionChecks.checks
        draftChecks = connectionChecks.draftChecks
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heading
                    if showsTrial {
                        TrialSessionView(presenter: trialPresenter, store: store, monitor: monitor,
                                         configureEngine: configureTrialEngine)
                        Divider()
                    }
                    groupTabs
                    Color.clear.frame(height: 0).id("settings-top")
                    groupContent
                    Text("更改会自动保存")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: StatsConfig.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, StatsConfig.contentHorizontalPadding)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .task(id: location.requestID) {
                // Wait for the selected group's layout before resolving a row anchor.
                await Task.yield()
                guard !Task.isCancelled else { return }
                if case .provider(let id) = location.target { proxy.scrollTo(id, anchor: .top) }
                else if let target = location.target { proxy.scrollTo(target, anchor: .top) }
                else { proxy.scrollTo("settings-top", anchor: .top) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: request, initial: true) { _, request in location.consume(request) }
        .onAppear { monitor.refresh() }
        .onDisappear { trialPresenter.cancel() }
        .onChange(of: location.section) { _, _ in
            trialPresenter.cancel()
            showsTrial = false
        }
        .sheet(item: $providerDraft) { draft in
            ProviderEditSheet(
                draft: draft, navigation: navigation,
                hadStoredKey: !(store.current.providerAPIKeys[draft.id.uuidString] ?? "").isEmpty,
                storedKey: { store.current.providerAPIKeys[draft.id.uuidString] ?? "" },
                validate: { draft in
                    var latest = store.current
                    try ProviderDraftCommit.apply(draft, to: &latest)
                },
                onSave: { draft in
                    var latest = store.current
                    try ProviderDraftCommit.apply(draft, to: &latest)
                    store.save(latest)
                    providerDraft = nil
                }, onCancel: { providerDraft = nil })
        }
    }

    private var heading: some View {
        HStack {
            Text("设置").font(Theme.Typography.pageTitle)
            Spacer()
            Button(showsTrial ? "收起试说" : "试说一句…") {
                if showsTrial { trialPresenter.cancel() }
                showsTrial.toggle()
            }.controlSize(.small)
        }
    }

    private func configureTrialEngine() {
        trialPresenter.cancel()
        showsTrial = false
        if let navigation { navigation.navigate(to: .settings(.speech)) }
        else { location.consume(NavigationRequest(id: UUID(), destination: .settings(.speech))) }
    }

    private var groupTabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    Button {
                        if let navigation { navigation.navigate(to: .settings(section)) }
                        else { location.consume(NavigationRequest(id: UUID(), destination: .settings(section))) }
                    } label: {
                        Text(section.title)
                            .font(.system(size: 13, weight: location.section == section ? .semibold : .regular))
                            .foregroundStyle(location.section == section ? Color.primary : Color.secondary)
                            .padding(.bottom, 12)
                            .overlay(alignment: .bottom) {
                                if location.section == section { Rectangle().fill(Brand.accent).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(location.section == section ? .isSelected : [])
                }
                Spacer()
            }
            Divider()
        }
    }

    @ViewBuilder private var groupContent: some View {
        switch location.section {
        case .speech:
            ASRSettingsContent(store: store, monitor: monitor, modelState: modelState,
                               downloader: downloader, importedActions: importedActions, navigation: navigation,
                               checks: checks, draftChecks: draftChecks, target: location.target,
                               requestID: location.requestID, devices: devices)
        case .text: llmSection
        case .general:
            appearanceSection
            Divider()
            triggerSection
            Divider()
            recordingSection
        case .privacy:
            PermissionSettingsContent(store: store, monitor: monitor, navigation: navigation)
            Divider()
            privacySection
            Divider()
            diagnosticsSection
        }
    }
}

extension SettingsSection {
    var title: String {
        switch self {
        case .speech: "语音识别"
        case .text: "文本整理"
        case .general: "通用"
        case .privacy: "权限与隐私"
        }
    }
}
