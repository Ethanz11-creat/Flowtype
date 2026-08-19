import SwiftUI

struct CloudASRProviderList: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var testStatus: [UUID: TestState] = [:]

    fileprivate enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("云端服务商")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(store.current.cloudASRConfig.providers.enumerated()), id: \.element.id) { index, provider in
                    CloudASRProviderCard(
                        provider: provider,
                        index: index,
                        testStatus: testStatus[provider.id] ?? .idle,
                        onDelete: { deleteProvider(provider.id) },
                        onTest: { apiKey in
                            await runTest(for: provider, apiKey: apiKey)
                        },
                        onUpdateTestStatus: { status in
                            testStatus[provider.id] = status
                        }
                    )
                }
            }

            Button {
                addProvider()
            } label: {
                Label("添加云端服务商", systemImage: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(Brand.accent)
        }
    }

    private func addProvider() {
        let newProvider = CloudASRProviderConfig(
            name: "新服务商",
            provider: "SiliconFlow",
            baseURL: "https://api.siliconflow.cn/v1",
            model: "",
            isActive: store.current.cloudASRConfig.providers.isEmpty
        )
        store.current.cloudASRConfig.providers.append(newProvider)
    }

    private func deleteProvider(_ id: UUID) {
        let wasActive = store.current.cloudASRConfig.providers.first(where: { $0.id == id })?.isActive ?? false
        store.current.cloudASRConfig.providers.removeAll(where: { $0.id == id })
        store.current.cloudASRConfig.providerAPIKeys.removeValue(forKey: id.uuidString)
        testStatus.removeValue(forKey: id)
        if wasActive, !store.current.cloudASRConfig.providers.isEmpty {
            store.current.cloudASRConfig.providers[0].isActive = true
        }
    }

    private func runTest(for provider: CloudASRProviderConfig, apiKey: String) async -> TestState {
        await MainActor.run {
            testStatus[provider.id] = .testing
        }
        let service = CloudASRProvider()
        let result = await service.testConnection(provider: provider, apiKey: apiKey)
        switch result {
        case .success:
            return .success
        case .failure(let error):
            return .failure(error.localizedDescription)
        }
    }
}

private struct CloudASRProviderCard: View {
    let provider: CloudASRProviderConfig
    let index: Int
    let testStatus: CloudASRProviderList.TestState
    let onDelete: () -> Void
    let onTest: (String) async -> CloudASRProviderList.TestState
    let onUpdateTestStatus: (CloudASRProviderList.TestState) -> Void

    @ObservedObject private var store = ConfigurationStore.shared
    @State private var isCustomModel: Bool

    init(provider: CloudASRProviderConfig, index: Int, testStatus: CloudASRProviderList.TestState, onDelete: @escaping () -> Void, onTest: @escaping (String) async -> CloudASRProviderList.TestState, onUpdateTestStatus: @escaping (CloudASRProviderList.TestState) -> Void) {
        self.provider = provider
        self.index = index
        self.testStatus = testStatus
        self.onDelete = onDelete
        self.onTest = onTest
        self.onUpdateTestStatus = onUpdateTestStatus

        let presetIds = Set(CloudASRModelPreset.siliconFlowModels.map(\.modelId))
        let model = provider.model
        self._isCustomModel = State(initialValue: !model.isEmpty && !presetIds.contains(model))
    }

    private var binding: Binding<CloudASRProviderConfig> {
        Binding(
            get: { store.current.cloudASRConfig.providers[index] },
            set: { store.current.cloudASRConfig.providers[index] = $0 }
        )
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { store.current.cloudASRConfig.providerAPIKeys[provider.id.uuidString] ?? "" },
            set: { store.current.cloudASRConfig.providerAPIKeys[provider.id.uuidString] = $0 }
        )
    }

    private var isActiveBinding: Binding<Bool> {
        Binding(
            get: { provider.isActive },
            set: { newValue in
                if newValue {
                    for i in store.current.cloudASRConfig.providers.indices {
                        store.current.cloudASRConfig.providers[i].isActive = (i == index)
                    }
                } else {
                    store.current.cloudASRConfig.providers[index].isActive = false
                }
            }
        )
    }

    private var isSiliconFlow: Bool {
        provider.provider == "SiliconFlow" || provider.baseURL.contains("siliconflow.cn")
    }

    private var pickerSelection: Binding<String> {
        Binding(
            get: {
                if isCustomModel { return "__custom__" }
                return binding.model.wrappedValue
            },
            set: { newValue in
                if newValue == "__custom__" {
                    isCustomModel = true
                    binding.model.wrappedValue = ""
                } else {
                    isCustomModel = false
                    binding.model.wrappedValue = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(provider.isActive ? Brand.accent : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)

                TextField("名称", text: binding.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))

                Text(provider.provider)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())

                Spacer()

                Toggle("启用", isOn: isActiveBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11))

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("https://api.siliconflow.cn/v1", text: binding.baseURL)
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

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    if isSiliconFlow {
                        Picker("", selection: pickerSelection) {
                            Text("请选择模型...").tag("")
                            ForEach(CloudASRModelPreset.siliconFlowModels) { preset in
                                Text(preset.name).tag(preset.modelId)
                            }
                            Divider()
                            Text("自定义模型 ID...").tag("__custom__")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if isCustomModel {
                            TextField("输入模型 ID", text: binding.model)
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

                        if binding.model.wrappedValue.isEmpty && !isCustomModel {
                            Text("请选择一个 ASR 模型")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    } else {
                        TextField("输入模型 ID，如 FunAudioLLM/SenseVoiceSmall", text: binding.model)
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
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        SecureField("输入 API Key（需用户自行配置）", text: apiKeyBinding)
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

                        HStack(spacing: 4) {
                            switch testStatus {
                            case .idle:
                                EmptyView()
                            case .testing:
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 14, height: 14)
                            case .success:
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            case .failure:
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }

                            Button {
                                Task {
                                    let status = await onTest(apiKeyBinding.wrappedValue)
                                    onUpdateTestStatus(status)
                                }
                            } label: {
                                Image(systemName: "bolt.horizontal.circle")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(testStatus == .testing)
                        }
                    }
                    Text("API Key 请前往 siliconflow.cn 注册获取，本地存储不上传")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                if case let .failure(msg) = testStatus {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .glassCard(active: provider.isActive, cornerRadius: 10)
    }
}
