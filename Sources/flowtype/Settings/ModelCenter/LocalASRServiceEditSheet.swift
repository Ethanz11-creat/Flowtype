import SwiftUI

struct LocalASRServiceDraft: Equatable {
    var target: ProviderDraftTarget
    var profile: LocalASRServiceProfile
    var keyEdit: APIKeyEdit = .preserve
    func applying(to configuration: Configuration) throws -> Configuration {
        var result = configuration
        guard profile.id == target.id else { throw ProviderDraftCommitError.invalid("服务标识不匹配") }
        let index = result.localASRServices.firstIndex { $0.id == target.id }
        switch target {
        case .new: guard index == nil else { throw ProviderDraftCommitError.conflict }
        case .existing:
            guard let index else { throw ProviderDraftCommitError.deleted }
            guard result.localASRServices[index].revision == profile.revision else { throw ProviderDraftCommitError.conflict }
        }
        var normalized = profile
        normalized.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.baseURL = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.modelID = profile.modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.name.isEmpty else { throw ProviderDraftCommitError.invalid("服务名称不能为空") }
        _ = try LocalASRServiceEndpoint.transcriptionURL(profile: normalized)
        if normalized.protocolKind == .openAICompatible {
            guard let model = normalized.modelID, !model.isEmpty else { throw ProviderDraftCommitError.invalid("此协议需要模型 ID；可手动填写。") }
        } else { normalized.modelID = nil }
        if let index {
            normalized.authentication = result.localASRServices[index].authentication
            if normalized != result.localASRServices[index] { normalized.revision = UUID() }
            result.localASRServices[index] = normalized
        } else { normalized.authentication = .none; result.localASRServices.append(normalized) }
        return result
    }
}

@MainActor
final class LocalASRServiceDraftSession: ObservableObject {
    @Published var draft: LocalASRServiceDraft { didSet { if draft != oldValue { models = []; notice = nil; generation = UUID() } } }
    @Published private(set) var models: [String] = []
    @Published private(set) var notice: String?
    @Published private(set) var isDiscovering = false
    @Published var confirmingDiscard = false
    private let initial: LocalASRServiceDraft
    private var generation = UUID()
    private let guardOwner = UUID()
    private weak var navigation: SettingsNavigation?
    private var close: (() -> Void)?
    private var pendingNavigation: NavigationRequest?
    init(draft: LocalASRServiceDraft) { self.draft = draft; initial = draft }
    var isModified: Bool { draft != initial }
    func checkConfiguration() {
        do {
            var config = Configuration(); config.localASRServices = []
            var check = draft; check.target = .new(check.profile.id)
            _ = try check.applying(to: config)
            notice = "配置有效；尚未连接或试识别。"
        } catch { notice = "配置无效，请检查 loopback 地址、名称与必填模型。" }
    }
    func discover(credential: () throws -> String?, using client: ASRModelDiscoveryClient) async {
        guard !isDiscovering else { return }
        isDiscovering = true; let captured = draft; let token = generation
        defer { isDiscovering = false }
        do {
            let value: String?
            switch captured.keyEdit {
            case .preserve: value = try credential()
            case .remove: value = nil
            case .replace(let key): value = key
            }
            var profile = captured.profile
            if value?.isEmpty == false { profile.authentication = .bearer(credentialID: "draft-only") }
            else { profile.authentication = .none }
            let result = try await client.models(profile: profile, credential: value)
            guard token == generation, draft == captured, !Task.isCancelled else { return }
            models = result
            notice = result.isEmpty ? "未返回可发现模型；仍可手动填写。此结果不表示识别可用。" : "已读取模型列表；候选可能包含非 ASR 型号，尚未试识别。"
        } catch {
            guard token == generation else { return }
            notice = "无法读取模型列表；请检查地址或认证，也可手动填写模型 ID。"
        }
    }
    func invalidate() { generation = UUID() }
    func attach(to navigation: SettingsNavigation?, onClose: @escaping () -> Void) {
        detach(); self.navigation = navigation; close = onClose
        navigation?.installNavigationGuard(owner: guardOwner) { [weak self] request in
            guard let self else { return true }
            if isModified { pendingNavigation = request; confirmingDiscard = true; return false }
            finishClose(); return true
        }
    }
    func detach() {
        invalidate(); navigation?.removeNavigationGuard(owner: guardOwner)
        navigation = nil; close = nil; pendingNavigation = nil; confirmingDiscard = false
    }
    func requestCancel() { if isModified { confirmingDiscard = true } else { finishClose() } }
    func keepEditing() { pendingNavigation = nil; confirmingDiscard = false }
    func discard() {
        let request = pendingNavigation, target = navigation
        finishClose()
        if let request { target?.navigate(request) }
    }
    private func finishClose() { let callback = close; detach(); callback?() }
}

struct LocalASRServiceEditSheet: View {
    @StateObject private var session: LocalASRServiceDraftSession
    let storedCredential: () throws -> String?
    let discovery: ASRModelDiscoveryClient
    let navigation: SettingsNavigation?
    let onSave: (LocalASRServiceDraft) throws -> Void
    let onCancel: () -> Void
    @State private var preset = LocalASRServicePreset.customOpenAICompatible
    @State private var saveError: String?
    init(draft: LocalASRServiceDraft, discovery: ASRModelDiscoveryClient, navigation: SettingsNavigation? = nil,
         storedCredential: @escaping () throws -> String?,
         onSave: @escaping (LocalASRServiceDraft) throws -> Void, onCancel: @escaping () -> Void) {
        _session = StateObject(wrappedValue: LocalASRServiceDraftSession(draft: draft))
        self.navigation = navigation; self.discovery = discovery; self.storedCredential = storedCredential; self.onSave = onSave; self.onCancel = onCancel
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接自行运行的本机服务").font(.title3)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("服务参考预设", selection: $preset) {
                        Text("自定义兼容").tag(LocalASRServicePreset.customOpenAICompatible)
                        Text("MLX Audio").tag(LocalASRServicePreset.mlxAudio)
                        Text("WhisperKit").tag(LocalASRServicePreset.whisperKit)
                        Text("whisper.cpp").tag(LocalASRServicePreset.whisperCpp)
                    }
                    Button("应用此预设协议与字段（保留地址、密钥）") {
                        let defaults = preset.makeProfile(baseURL: session.draft.profile.baseURL, modelID: session.draft.profile.modelID)
                        session.draft.profile.protocolKind = defaults.protocolKind
                        session.draft.profile.fieldCapabilities = defaults.fieldCapabilities
                        if defaults.protocolKind == .whisperCpp { session.draft.profile.modelID = nil }
                    }
                    TextField("服务名称", text: $session.draft.profile.name)
                    TextField("http://127.0.0.1:8000/v1", text: $session.draft.profile.baseURL)
                    if session.draft.profile.protocolKind == .whisperCpp { Text("模型由服务端决定；FlowType 不切换服务端模型。") }
                    else {
                        TextField("模型 ID（必填，可手动填写）", text: Binding(get: { session.draft.profile.modelID ?? "" }, set: { session.draft.profile.modelID = $0 }))
                        Button("读取模型列表（向所填地址发送凭据，不发送音频）") {
                            Task { await session.discover(credential: storedCredential, using: discovery) }
                        }.disabled(session.isDiscovering)
                        ForEach(session.models, id: \.self) { model in Button(model) { session.draft.profile.modelID = model } }
                    }
                    SecureField("替换 Bearer token（留空保留）", text: Binding(get: {
                        if case .replace(let key) = session.draft.keyEdit { return key }; return ""
                    }, set: { session.draft.keyEdit = $0.isEmpty ? .preserve : .replace($0) }))
                    Button(session.draft.keyEdit == .remove ? "保留凭据" : "保存时移除凭据") {
                        session.draft.keyEdit = session.draft.keyEdit == .remove ? .preserve : .remove
                    }
                    Text("FlowType 不安装、启动或更新第三方服务。服务本身可能联网。参考版本已固定，其他版本须自行核对协议。")
                    if let guide = preset.officialGuide { Link(guide.label, destination: guide.url) }
                    Text("手动地址示例：" + preset.exampleBaseURL).textSelection(.enabled)
                    Button("检查配置（不联网）") { session.checkConfiguration() }
                    Text("保存为未验证配置后，在模型中心查看目的地、内置语音样本和可能费用，再明确点击测试识别或试用并选择。测试输出供你判断质量。")
                    if let notice = session.notice { Text(notice) }
                    if let saveError { Text(saveError).foregroundStyle(.red) }
                }.textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("取消") { session.requestCancel() }
                Spacer()
                Button("保存未验证配置") {
                    do { try onSave(session.draft); session.detach() }
                    catch { saveError = (error as? ProviderDraftCommitError)?.localizedDescription ?? "保存失败，草稿已保留；请检查凭据存储后重试。" }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 570, height: 610)
            .interactiveDismissDisabled(session.isModified)
            .onAppear { session.attach(to: navigation, onClose: onCancel) }
            .onDisappear { session.detach() }
            .onExitCommand { session.requestCancel() }
            .alert("放弃未保存的更改？", isPresented: $session.confirmingDiscard) {
                Button("继续编辑", role: .cancel) { session.keepEditing() }
                Button("放弃", role: .destructive) { session.discard() }
            }
    }
}

extension LocalASRServicePreset: Hashable {
    var officialGuide: (label: String, url: URL)? {
        switch self {
        case .customOpenAICompatible: return nil
        case .mlxAudio: return ("MLX Audio 官方部署与 server（5dbe43b）", URL(string: "https://github.com/Blaizzy/mlx-audio/tree/5dbe43bdacccdf17a930a2787a39acae7a44d1a0")!)
        case .whisperKit: return ("WhisperKit 0.18.0 官方部署指引", URL(string: "https://github.com/argmaxinc/WhisperKit/blob/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef/README.md")!)
        case .whisperCpp: return ("whisper.cpp 官方 server 指引（f92e1e4）", URL(string: "https://github.com/ggml-org/whisper.cpp/blob/f92e1e4d1056700c39d4e86c1140f0a088fe1ab6/examples/server/README.md")!)
        }
    }
    var exampleBaseURL: String { self == .whisperCpp ? "http://127.0.0.1:8080" : "http://127.0.0.1:8000/v1" }
}
