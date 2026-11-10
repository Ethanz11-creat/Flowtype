import SwiftUI
import Combine

/// Owns the draft revision and close decision; the list owns the longer-lived transport slots.
@MainActor
final class ASRProviderDraftSession: ObservableObject {
    @Published var draft: ASRProviderDraft {
        didSet { if draft != oldValue { invalidateCheck() } }
    }
    @Published var isConfirmingDiscard = false
    private(set) var pendingNavigation: NavigationRequest?
    private let initialDraft: ASRProviderDraft
    let checks: CloudASRConnectionCheck
    private var checkTask: Task<Void, Never>?
    private let guardOwner = UUID()
    private weak var navigation: SettingsNavigation?
    private var onClose: (() -> Void)?

    init(draft: ASRProviderDraft, checks: CloudASRConnectionCheck) {
        self.draft = draft
        initialDraft = draft
        self.checks = checks
        checks.invalidate(profileID: draft.target.id)
    }

    var isModified: Bool { draft != initialDraft }
    var canTestRecognition: Bool { draft.profile.protocolKind == .openAICompatible }

    /// Matches ProviderDraftCommit's persisted field normalization; keys retain their exact value.
    private var checkProfile: CloudASRProviderConfig {
        var profile = draft.profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.baseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return profile
    }

    private func effectiveKey(_ storedKey: String) -> String {
        switch draft.keyEdit {
        case .preserve: return storedKey
        case .remove: return ""
        case .replace(let value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? storedKey : value
        }
    }

    func checkConfiguration(storedKey: String) {
        checks.checkConfiguration(provider: checkProfile, apiKey: effectiveKey(storedKey))
    }

    @discardableResult
    func testRecognition(storedKey: String) -> Task<Void, Never>? {
        let task = checks.testRecognition(provider: checkProfile, apiKey: effectiveKey(storedKey))
        if let task { checkTask = task }
        return task
    }

    func invalidateCheck() {
        checks.invalidate(profileID: draft.target.id)
        checkTask?.cancel()
        checkTask = nil
    }

    func attach(to navigation: SettingsNavigation?, onClose: @escaping () -> Void) {
        detach()
        self.navigation = navigation
        self.onClose = onClose
        navigation?.installNavigationGuard(owner: guardOwner) { [weak self] request in
            guard let self else { return true }
            if self.isModified {
                self.pendingNavigation = request
                self.isConfirmingDiscard = true
                return false
            }
            self.finishClose()
            return true
        }
    }

    func detach() {
        invalidateCheck()
        navigation?.removeNavigationGuard(owner: guardOwner)
        navigation = nil
        onClose = nil
        pendingNavigation = nil
        isConfirmingDiscard = false
    }

    func requestCancel() {
        if isModified { isConfirmingDiscard = true }
        else { finishClose() }
    }

    func keepEditing() { pendingNavigation = nil; isConfirmingDiscard = false }

    func discard() {
        let request = pendingNavigation
        let navigation = navigation
        finishClose()
        if let request { navigation?.navigate(request) }
    }

    private func finishClose() {
        let close = onClose
        detach()
        close?()
    }
}

struct ASRProviderEditSheet: View {
    @StateObject private var session: ASRProviderDraftSession
    @ObservedObject private var checks: CloudASRConnectionCheck
    let navigation: SettingsNavigation?
    let hadStoredKey: Bool
    let storedKey: () throws -> String
    let onSave: (ASRProviderDraft) throws -> Void
    let onCancel: () -> Void
    @State private var validationError: String?

    init(draft: ASRProviderDraft, checks: CloudASRConnectionCheck, navigation: SettingsNavigation? = nil,
         hadStoredKey: Bool, storedKey: @escaping () throws -> String,
         onSave: @escaping (ASRProviderDraft) throws -> Void, onCancel: @escaping () -> Void) {
        _session = StateObject(wrappedValue: ASRProviderDraftSession(draft: draft, checks: checks))
        self.checks = checks
        self.navigation = navigation
        self.hadStoredKey = hadStoredKey
        self.storedKey = storedKey
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var keyInput: Binding<String> {
        Binding(get: {
            if case .replace(let value) = session.draft.keyEdit { return value }
            return ""
        }, set: {
            session.draft.keyEdit = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .preserve : .replace($0)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("云端识别服务").font(.system(size: 18, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("厂商", selection: Binding(get: { session.draft.profile.vendorID }, set: { session.draft.selectVendor($0) })) {
                        Text("硅基流动 SiliconFlow").tag(CloudASRVendorID.siliconFlow)
                        Text("OpenAI").tag(CloudASRVendorID.openAI)
                        Text("阿里云 DashScope").tag(CloudASRVendorID.dashScope)
                        Text("自定义兼容服务").tag(CloudASRVendorID.custom)
                    }
                    HStack {
                        Text("切换厂商保留 URL、模型和密钥。 ").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("使用厂商默认值") { session.draft.useVendorDefaults() }
                    }
                    LabeledContent("名称") { TextField("服务名称", text: $session.draft.profile.name) }
                    LabeledContent("模型 ID（必填）") {
                        TextField("服务商文档中的模型 ID", text: $session.draft.profile.model)
                            .accessibilityLabel("模型 ID（必填）")
                    }
                    LabeledContent(session.canTestRecognition ? "Base URL / 完整转写 URL" : "WSS URL") {
                        TextField(session.canTestRecognition ? "https://…" : "wss://…", text: $session.draft.profile.baseURL)
                    }
                    SecureKeyField(title: hadStoredKey ? "替换 API Key（留空保留）" : "API Key", key: keyInput)
                    if hadStoredKey || session.draft.keyEdit == .remove {
                        HStack {
                            Text(session.draft.keyEdit == .remove ? "保存时删除密钥" : "已保存密钥；留空保留")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button(session.draft.keyEdit == .remove ? "保留已存密钥" : "删除密钥") {
                                session.draft.keyEdit = session.draft.keyEdit == .remove ? .preserve : .remove
                            }
                        }
                    }
                    DisclosureGroup("高级配置（协议与请求字段）") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("识别协议", selection: $session.draft.profile.protocolKind) {
                                Text("OpenAI 兼容 HTTP").tag(CloudASRProtocolKind.openAICompatible)
                                Text("DashScope 实时 WSS").tag(CloudASRProtocolKind.dashScopeRealtime)
                            }
                            let presets = CloudASRVendor.modelPresets(for: session.draft.profile)
                            if !presets.isEmpty {
                                Picker("模型预设", selection: $session.draft.profile.model) {
                                    ForEach(presets) { Text($0.name).tag($0.modelId) }
                                    if !presets.contains(where: { $0.modelId == session.draft.profile.model }) {
                                        Text("自定义模型").tag(session.draft.profile.model)
                                    }
                                }
                            }
                            if session.draft.profile.vendorID == .custom && session.canTestRecognition {
                                Text("仅在服务商文档确认支持时启用；默认仅发送 file / model。")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Toggle("发送 language", isOn: $session.draft.profile.customFieldCapabilities.sendLanguage)
                                Toggle("发送 prompt（仍受上下文总开关控制）", isOn: $session.draft.profile.customFieldCapabilities.sendPrompt)
                                Toggle("发送 temperature=0", isOn: $session.draft.profile.customFieldCapabilities.sendTemperature)
                                Toggle("发送 response_format=json", isOn: $session.draft.profile.customFieldCapabilities.sendResponseFormat)
                            }
                        }.padding(.top, 8)
                    }
                    Divider()
                    HStack {
                        Button("检查配置") { performConfigurationCheck() }
                        if checks.isTesting(session.draft.target.id) { ProgressView().controlSize(.small) }
                    }
                    .disabled(checks.isTesting(session.draft.target.id))
                    Text(session.canTestRecognition
                         ? "检查配置不联网。请先保存未验证配置，再在模型中心查看目标地址、内置语音样本与可能费用，并明确点击测试或试用并选择；测试结果供你判断质量。"
                         : "检查配置仅本地校验，不联网；连接与识别将在真实录音时验证。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(checks.state(for: session.draft.target.id).displayText)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let validationError { Text(validationError).foregroundStyle(.red) }
                }
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("取消") { session.requestCancel() }
                Button("保存", action: save).buttonStyle(.borderedProminent)
            }
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(width: 560, height: 600)
        .interactiveDismissDisabled(session.isModified)
        .onExitCommand { session.requestCancel() }
        .alert("放弃未保存的更改？", isPresented: $session.isConfirmingDiscard) {
            Button("继续编辑", role: .cancel) { session.keepEditing() }
            Button("放弃", role: .destructive) { session.discard() }
        }
        .onChange(of: session.draft) { _, _ in validationError = nil }
        .onAppear { session.attach(to: navigation, onClose: onCancel) }
        .onDisappear { session.detach() }
    }

    private func performConfigurationCheck() {
        do {
            let key = try storedKey()
            session.checkConfiguration(storedKey: key)
        } catch { validationError = ASRCredentialError.unavailable.localizedDescription }
    }

    private func save() {
        do { try onSave(session.draft); session.detach() }
        catch { validationError = error.localizedDescription }
    }
}

extension CloudASRConnectionCheck.State {
    var displayText: String {
        switch self {
        case .idle: return "尚未验证"
        case .testing: return "正在测试识别…"
        case .configurationValid: return "配置有效；尚未连接"
        case .connected: return "当前修订测试识别成功"
        case .failure(let message): return message
        }
    }
}
