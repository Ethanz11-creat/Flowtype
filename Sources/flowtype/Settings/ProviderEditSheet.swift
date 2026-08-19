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

    var baseURL = provider.baseURL.trimmingCharacters(in: .whitespaces)
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
    @Binding var provider: LLMProvider
    @Binding var apiKey: String
    var existingProviders: [LLMProvider]
    var hadStoredKey: Bool = false
    var onSave: () -> Void
    var onCancel: () -> Void

    @State private var testStatus: TestStatus = .idle
    @State private var validationError: String? = nil

    enum TestStatus: Equatable {
        case idle, testing, success, failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(provider.name.isEmpty ? "添加 Provider" : "编辑 Provider")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name.isEmpty ? "新 Provider" : provider.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text("配置大语言模型服务商（需用户自行配置 API Key）")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("服务商")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    ProviderPicker(provider: $provider.provider, baseURL: $provider.baseURL)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("名称")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("例如：我的 SiliconFlow", text: $provider.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("https://api.siliconflow.cn/v1", text: $provider.baseURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }

                SecureKeyField(title: "API Key（需用户自行配置）", key: $apiKey)

                LLMModelPickerField(
                    title: "模型 ID",
                    model: $provider.model,
                    providerName: provider.provider,
                    baseURL: provider.baseURL
                )
            }
            .padding(16)
            .glassCard()

            if hadStoredKey && apiKey.isEmpty {
                Text("保存时将删除已保存的 API Key")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = validationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            switch testStatus {
            case .idle:
                EmptyView()
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在测试连接...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            case .success:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text("连接成功")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            case .failure(let msg):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("测试连接") {
                    Task { await testOnly() }
                }
                .buttonStyle(.bordered)
                .disabled(testStatus == .testing || apiKey.isEmpty)
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                Button("保存") {
                    Task {
                        await attemptSave()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(testStatus == .testing)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func attemptSave() async {
        validationError = nil

        if let error = validateProvider(provider, existingProviders: existingProviders) {
            validationError = error.localizedDescription
            return
        }

        provider.baseURL = normalizeBaseURL(provider.baseURL)

        if !apiKey.isEmpty {
            testStatus = .testing
            let service = LLMService()
            let result = await service.testConnection(provider: provider, apiKey: apiKey)
            switch result {
            case .success:
                testStatus = .success
                try? await Task.sleep(nanoseconds: 300_000_000)
            case .failure(let error):
                let msg = error.userFriendlyMessage
                testStatus = .failure(msg)
                validationError = "连接测试失败: \(msg)"
                return
            }
        }

        onSave()
    }

    private func testOnly() async {
        validationError = nil
        if let error = validateProvider(provider, existingProviders: existingProviders) {
            validationError = error.localizedDescription
            return
        }
        provider.baseURL = normalizeBaseURL(provider.baseURL)
        testStatus = .testing
        let result = await LLMService().testConnection(provider: provider, apiKey: apiKey)
        switch result {
        case .success:
            testStatus = .success
        case .failure(let error):
            testStatus = .failure(error.userFriendlyMessage)
        }
    }
}
