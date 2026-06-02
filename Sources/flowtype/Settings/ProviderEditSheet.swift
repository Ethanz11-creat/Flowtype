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

// MARK: - Provider Edit Sheet

struct ProviderEditSheet: View {
    @Binding var provider: LLMProvider
    @Binding var apiKey: String
    var existingProviders: [LLMProvider]
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

            ServiceConfigCard(
                title: provider.name.isEmpty ? "新 Provider" : provider.name,
                subtitle: "配置大语言模型服务商",
                provider: $provider.provider,
                baseURL: $provider.baseURL,
                apiKey: $apiKey,
                model: $provider.model,
                modelPlaceholder: "例如：deepseek-ai/DeepSeek-V3"
            )

            // Validation / test error display
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

            // Test status display
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

        // Step 1: Validation
        if let error = validateProvider(provider, existingProviders: existingProviders) {
            validationError = error.localizedDescription
            return
        }

        // Normalize base URL
        provider.baseURL = normalizeBaseURL(provider.baseURL)

        // Step 2: Connection test (skip if API key is empty)
        if !apiKey.isEmpty {
            testStatus = .testing
            let service = LLMService()
            let result = await service.testConnection(provider: provider)
            switch result {
            case .success:
                testStatus = .success
                // Small delay so user sees success
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
}
