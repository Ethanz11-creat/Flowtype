import SwiftUI

// MARK: - Provider Validation

enum ProviderValidationError: LocalizedError {
    case emptyName
    case emptyModel
    case invalidBaseURL(String)
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Provider 名称不能为空"
        case .emptyModel: return "模型 ID 不能为空"
        case .invalidBaseURL(let msg): return msg
        case .duplicateName: return "Provider 名称不能重复"
        }
    }
}

func validateProvider(_ provider: LLMProvider, existingProviders: [LLMProvider], excludingID: UUID? = nil) -> ProviderValidationError? {
    if provider.name.trimmingCharacters(in: .whitespaces).isEmpty {
        return .emptyName
    }
    if provider.model.trimmingCharacters(in: .whitespaces).isEmpty {
        return .emptyModel
    }

    let baseURL = provider.baseURL.trimmingCharacters(in: .whitespaces)
    if baseURL.isEmpty {
        return .invalidBaseURL("Base URL 不能为空")
    }
    if !baseURL.lowercased().hasPrefix("https://") {
        return .invalidBaseURL("Base URL 必须以 https:// 开头")
    }

    let trimmedName = provider.name.trimmingCharacters(in: .whitespaces)
    let duplicate = existingProviders.first(where: {
        $0.name.trimmingCharacters(in: .whitespaces) == trimmedName && $0.id != provider.id && $0.id != excludingID
    })
    if duplicate != nil {
        return .duplicateName
    }

    return nil
}

func normalizeBaseURL(_ url: String) -> String {
    var result = url.trimmingCharacters(in: .whitespaces)
    while result.hasSuffix("/") {
        result = String(result.dropLast())
    }
    return result
}

// MARK: - Model Picker Field

struct LLMModelPickerField: View {
    let title: String
    @Binding var model: String
    let providerName: String
    let baseURL: String

    @State private var isCustomModel: Bool

    init(title: String, model: Binding<String>, providerName: String, baseURL: String) {
        self.title = title
        self._model = model
        self.providerName = providerName
        self.baseURL = baseURL

        let presetIds = Set(LLMModelPreset.siliconFlowModels.map(\.modelId))
        let m = model.wrappedValue
        self._isCustomModel = State(initialValue: !m.isEmpty && !presetIds.contains(m))
    }

    private var isSiliconFlow: Bool {
        providerName == "SiliconFlow" || baseURL.contains("siliconflow.cn")
    }

    private var pickerSelection: Binding<String> {
        Binding(
            get: {
                if isCustomModel { return "__custom__" }
                return model
            },
            set: { newValue in
                if newValue == "__custom__" {
                    isCustomModel = true
                    model = ""
                } else {
                    isCustomModel = false
                    model = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            if isSiliconFlow {
                Picker("", selection: pickerSelection) {
                    Text("请选择模型...").tag("")
                    ForEach(LLMModelPreset.siliconFlowModels) { preset in
                        Text(preset.name).tag(preset.modelId)
                    }
                    Divider()
                    Text("自定义模型 ID...").tag("__custom__")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                if isCustomModel {
                    TextField("输入模型 ID", text: $model)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }

                if model.isEmpty && !isCustomModel {
                    Text("请选择一个 LLM 润色模型")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            } else {
                TextField("例如：deepseek-ai/DeepSeek-V3", text: $model)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Provider Edit Sheet

struct ProviderEditSheet: View {
    @StateObject private var session: LLMProviderDraftSession
    private var draft: LLMProviderDraft { session.draft }
    let navigation: SettingsNavigation?
    let hadStoredKey: Bool
    let storedKey: () -> String
    let validate: (LLMProviderDraft) throws -> Void
    let onSave: (LLMProviderDraft) throws -> Void
    let onCancel: () -> Void

    @State private var testStatus: TestStatus = .idle
    @State private var validationError: String?
    @State private var testRevision = UUID()
    @State private var testTask: Task<Void, Never>?

    init(draft: LLMProviderDraft, navigation: SettingsNavigation? = nil, hadStoredKey: Bool, storedKey: @escaping () -> String,
         validate: @escaping (LLMProviderDraft) throws -> Void,
         onSave: @escaping (LLMProviderDraft) throws -> Void, onCancel: @escaping () -> Void) {
        _session = StateObject(wrappedValue: LLMProviderDraftSession(draft: draft))
        self.navigation = navigation
        self.hadStoredKey = hadStoredKey
        self.storedKey = storedKey
        self.validate = validate
        self.onSave = onSave
        self.onCancel = onCancel
    }

    enum TestStatus: Equatable {
        case idle, testing, success, failure(String)
    }

    private var apiKeyInput: Binding<String> {
        Binding(get: {
            if case .replace(let value) = draft.keyEdit { return value }
            return ""
        }, set: { value in
            session.draft.keyEdit = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .preserve : .replace(value)
        })
    }

    private var effectiveKey: String {
        switch draft.keyEdit {
        case .preserve: return storedKey()
        case .replace(let key): return key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? storedKey() : key
        case .remove: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "添加整理服务" : "编辑整理服务")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                Picker("服务商", selection: Binding(get: { draft.profile.provider }, set: { session.draft.selectVendor($0) })) {
                    ForEach(ProviderPreset.all) { preset in Text(preset.name).tag(preset.name) }
                    if !ProviderPreset.all.contains(where: { $0.name == draft.profile.provider }) {
                        Text(draft.profile.provider).tag(draft.profile.provider)
                    }
                }
                Button("使用厂商默认值") { session.draft.useVendorDefaults() }
                    .font(.system(size: 12))
                    .disabled(!ProviderPreset.all.contains(where: { $0.name == draft.profile.provider }))
                LabeledContent("名称") { TextField("服务名称", text: $session.draft.profile.name) }
                LabeledContent("Base URL") {
                    TextField("https://…", text: $session.draft.profile.baseURL)
                        .font(.system(size: 12, design: .monospaced))
                }
                SecureKeyField(title: hadStoredKey ? "替换 API Key（留空保留）" : "API Key", key: apiKeyInput)
                if hadStoredKey || draft.keyEdit == .remove {
                    HStack {
                        Text(draft.keyEdit == .remove ? "保存时删除密钥" : "已保存密钥；留空保留")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(draft.keyEdit == .remove ? "保留已存密钥" : "删除密钥") {
                            session.draft.keyEdit = draft.keyEdit == .remove ? .preserve : .remove
                        }
                        .font(.system(size: 12))
                    }
                }
                LLMModelPickerField(title: "模型 ID", model: $session.draft.profile.model,
                                    providerName: draft.profile.provider, baseURL: draft.profile.baseURL)
                    .id(draft.profile.provider)
            }
            .textFieldStyle(.roundedBorder)

            if let error = validationError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
            switch testStatus {
            case .idle: EmptyView()
            case .testing:
                HStack { ProgressView().controlSize(.small); Text("正在测试连接…") }
            case .success: Text("连接成功").foregroundStyle(.green)
            case .failure(let message): Text(message).foregroundStyle(.red)
            }

            HStack {
                Button("测试连接") { beginTest() }
                    .disabled(testStatus == .testing || effectiveKey.isEmpty)
                Spacer()
                Button("取消", action: requestCancel)
                Button("保存", action: attemptSave)
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(session.isModified)
        .onExitCommand(perform: requestCancel)
        .alert("放弃未保存的更改？", isPresented: $session.isConfirmingDiscard) {
            Button("继续编辑", role: .cancel) { session.keepEditing() }
            Button("放弃", role: .destructive, action: finishCancel)
        }
        .onChange(of: draft) { _, _ in
            invalidateTest()
            validationError = nil
        }
        .onAppear { session.attach(to: navigation, onClose: onCancel) }
        .onDisappear { invalidateTest(); session.detach() }
    }

    private var isNew: Bool {
        if case .new = draft.target { return true }
        return false
    }

    private func requestCancel() {
        session.requestCancel()
    }

    private func finishCancel() {
        invalidateTest()
        session.discard()
    }

    private func invalidateTest() {
        testRevision = UUID()
        testTask?.cancel()
        testTask = nil
        testStatus = .idle
    }

    /// Saving performs local validation and one transaction; network testing is a separate action.
    private func attemptSave() {
        do {
            try onSave(draft)
            session.detach()
            invalidateTest()
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func beginTest() {
        do { try validate(draft) }
        catch { validationError = error.localizedDescription; return }
        let key = effectiveKey
        guard !key.isEmpty else { return }
        invalidateTest()
        let revision = testRevision
        let testedDraft = draft
        let profile = ProviderDraftCommit.normalizedLLMProfile(draft.profile)
        testStatus = .testing
        testTask = Task { @MainActor in
            guard !Task.isCancelled, testRevision == revision, draft == testedDraft else { return }
            let result = await LLMService().testConnection(provider: profile, apiKey: key)
            guard !Task.isCancelled, testRevision == revision, draft == testedDraft else { return }
            switch result {
            case .success: testStatus = .success
            case .failure(let error): testStatus = .failure(error.userFriendlyMessage)
            }
            testTask = nil
        }
    }
}
