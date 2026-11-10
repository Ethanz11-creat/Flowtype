import SwiftUI
import AVFoundation

/// Shared configuration surface. Callers own services and connection-check lifetimes.
struct ASRSettingsContent: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var monitor: ReadinessMonitor
    @ObservedObject var modelState: QwenModelState
    @ObservedObject var downloader: ModelDownloader
    @ObservedObject var importedActions: ImportedASRModelActions
    let navigation: SettingsNavigation?
    @ObservedObject var checks: CloudASRConnectionCheck
    @ObservedObject var draftChecks: CloudASRConnectionCheck
    var environment: ASRModelCenterEnvironment? = nil
    var modelCenter: ASRModelCenterViewModel? = nil
    var modelCenterActions = ASRModelCenterUIActions()
    var target: SettingsTarget? = nil
    var requestID: UUID? = nil
    var devices: () -> [AudioDevice] = { AudioRecorder.availableInputDevices() }
    @State private var availableDevices: [AudioDevice] = []
    @State private var localExpanded = true
    @State private var cloudExpanded = true
    @State private var policyMessage: String?

    var localModelPicker: LocalModelPicker {
        LocalModelPicker(store: store, modelState: modelState, downloader: downloader, importedActions: importedActions, navigation: navigation)
    }

    var localModelStatus: QwenModelStatusCard {
        QwenModelStatusCard(modelState: modelState, store: store, importedActions: importedActions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let environment {
                ASRModelCenterHost(environment: environment, navigation: navigation, target: target, requestID: requestID)
            } else if let modelCenter {
                ASRModelCenterView(model: modelCenter, actions: modelCenterActions)
            } else {
                modeSection
                DisclosureGroup(isExpanded: $localExpanded) {
                    localModelPicker
                } label: {
                    Text(store.current.asrRoutingPolicy == .cloudOnly ? "本地模型 · 此模式不使用" : "本地模型")
                        .font(.system(size: 13, weight: .medium))
                }.id(SettingsTarget.localModels)
                Divider()
                DisclosureGroup(isExpanded: $cloudExpanded) {
                    CloudASRProviderList(store: store, checks: checks, draftChecks: draftChecks, navigation: navigation)
                } label: {
                    Text(store.current.asrRoutingPolicy == .localOnly ? "云端服务 · 此模式不使用" : "云端服务")
                        .font(.system(size: 13, weight: .medium))
                }
                Divider()
            }
            inputSection
            Text("更改识别配置后，进行中的听写继续使用原配置。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { resetExpansion(); refreshDevices() }
        .onChange(of: store.current.asrRoutingPolicy) { _, _ in resetExpansion() }
        .onChange(of: requestID, initial: true) { _, _ in revealTarget() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshDevices() }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("识别方式").font(.system(size: 13, weight: .semibold))
            Picker("识别方式", selection: Binding(get: { store.current.asrRoutingPolicy }, set: { policy in
                do {
                    try store.applyASRSettingsAction(.changePolicy(policy), activeNativeID: modelState.activeLease.map(ASRBackendID.init(nativeLease:)))
                    policyMessage = nil
                } catch { policyMessage = error.localizedDescription }
            })) {
                Text("仅本地").tag(ASRRoutingPolicy.localOnly)
                Text("自动（推荐）").tag(ASRRoutingPolicy.auto)
                Text("仅云端").tag(ASRRoutingPolicy.cloudOnly)
            }
            .labelsHidden().pickerStyle(.segmented)
            .frame(width: 276, height: 40)
            if let policyMessage { Text(policyMessage).font(.system(size: 12)).foregroundStyle(.secondary) }
            Text(modeDescription).font(.system(size: 12)).foregroundStyle(.secondary)
            if let disclosure = SettingsPrivacyPresentation.make(config: store.current).localPolishDisclosure {
                Text(disclosure).font(.system(size: 11)).foregroundStyle(.secondary)
                Button("管理文本整理") { navigation?.navigate(to: .settings(.text)) }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
    }

    private var inputSection: some View {
        VStack(spacing: 0) {
            SettingsRow("识别语言") {
                Picker("识别语言", selection: $store.current.asrLanguage) {
                    ForEach(WhisperLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 200)
            }
            Divider()
            SettingsRow("麦克风设备", description: selectedDeviceUnavailable ? "所选设备不可用；已保留选择，请重新连接或手动选择其他设备。" : nil) {
                Picker("麦克风设备", selection: $store.current.microphoneDeviceID) {
                    Text("系统默认").tag(String?.none)
                    if let id = store.current.microphoneDeviceID, selectedDeviceUnavailable {
                        Text("所选设备（不可用）").tag(Optional(id))
                    }
                    ForEach(availableDevices) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 220)
                Button("刷新") { refreshDevices() }.controlSize(.small)
            }
        }
    }

    private var selectedDeviceUnavailable: Bool {
        guard let id = store.current.microphoneDeviceID else { return false }
        return !availableDevices.contains { $0.id == id }
    }
    private func refreshDevices() { availableDevices = devices() }
    private func resetExpansion() {
        localExpanded = store.current.asrRoutingPolicy != .cloudOnly
        cloudExpanded = store.current.asrRoutingPolicy != .localOnly
        revealTarget()
    }
    private func revealTarget() {
        if target?.legacyASRTarget == .localModels { localExpanded = true }
        if case .provider = target?.legacyASRTarget { cloudExpanded = true }
    }
    private var modeDescription: String {
        switch store.current.asrRoutingPolicy {
        case .localOnly: "仅使用可用本地模型；识别录音不发送给云端 ASR。"
        case .auto: "按明确的主选与备选识别；本地转云端需要允许云端备选。"
        case .cloudOnly: "仅使用配置的云端识别服务，不切换到本地 ASR。"
        }
    }
}
