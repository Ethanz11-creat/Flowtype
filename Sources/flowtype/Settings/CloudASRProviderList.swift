import SwiftUI

struct CloudASRProviderList: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @StateObject private var checks = CloudASRConnectionCheck()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("云端服务商")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            ForEach(store.current.cloudASRConfig.providers) { provider in
                CloudASRProviderCard(provider: provider, checks: checks)
            }

            Menu("添加云端服务商") {
                Button("硅基流动 SiliconFlow") { addProvider(.siliconFlow) }
                Button("OpenAI") { addProvider(.openAI) }
                Button("阿里云 Paraformer 实时") { addProvider(.dashScope) }
                Button("自定义兼容服务") { addProvider(.custom) }
            }
            .buttonStyle(.plain)
            .foregroundColor(Brand.accent)
        }
        .onChange(of: store.current.cloudASRConfig) { old, new in
            checks.synchronize(old: old, new: new)
        }
    }

    private func addProvider(_ vendor: CloudASRVendorID) {
        store.current.cloudASRConfig.providers.append(
            CloudASRVendor.makeProfile(vendor, isActive: store.current.cloudASRConfig.providers.isEmpty))
    }
}

private struct CloudASRProviderCard: View {
    let provider: CloudASRProviderConfig
    @ObservedObject var checks: CloudASRConnectionCheck
    @ObservedObject private var store = ConfigurationStore.shared

    // Resolve by UUID on every access: cards can outlive an array insertion/deletion.
    private var binding: Binding<CloudASRProviderConfig> {
        Binding(
            get: { store.current.cloudASRConfig.providers.first(where: { $0.id == provider.id }) ?? provider },
            set: { checks.updateProfile($0, in: &store.current.cloudASRConfig) }
        )
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { store.current.cloudASRConfig.providerAPIKeys[provider.id.uuidString] ?? "" },
            set: { checks.updateAPIKey($0, profileID: provider.id, in: &store.current.cloudASRConfig) }
        )
    }

    private var isActiveBinding: Binding<Bool> {
        Binding(
            get: { binding.wrappedValue.isActive },
            set: { checks.setActive($0, profileID: provider.id, in: &store.current.cloudASRConfig) }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { binding.wrappedValue.model },
            set: { checks.selectModel($0, profileID: provider.id, in: &store.current.cloudASRConfig) }
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
                Spacer()
                Toggle("启用", isOn: isActiveBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button(role: .destructive) {
                    checks.deleteProfile(provider.id, in: &store.current.cloudASRConfig)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundColor(.red.opacity(0.8))
                .accessibilityLabel("删除服务商")
            }

            Text("服务：\(vendorName) · 模型：\(provider.model.isEmpty ? "待填写" : provider.model)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 4) {
                Text(provider.protocolKind == .dashScopeRealtime ? "WSS URL" : "Base URL / 完整转写 URL")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(provider.protocolKind == .dashScopeRealtime ? "wss://服务地址/路径" : "https://服务地址/v1", text: binding.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            SecureField("输入 API Key", text: apiKeyBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            if provider.vendorID == .custom && provider.model.isEmpty {
                Text("请在高级配置中填写模型 ID；自定义服务还需提供 URL 和 API Key。")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            DisclosureGroup("高级配置（模型与请求字段）") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("厂商", selection: binding.vendorID) {
                        Text("硅基流动 SiliconFlow").tag(CloudASRVendorID.siliconFlow)
                        Text("OpenAI").tag(CloudASRVendorID.openAI)
                        Text("阿里云 DashScope").tag(CloudASRVendorID.dashScope)
                        Text("自定义兼容服务").tag(CloudASRVendorID.custom)
                    }
                    Text("更换厂商保留现有 URL、模型与 Key，请按服务商要求修改。")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Picker("识别协议", selection: binding.protocolKind) {
                        Text("OpenAI 兼容 HTTP").tag(CloudASRProtocolKind.openAICompatible)
                        Text("DashScope 实时 WSS").tag(CloudASRProtocolKind.dashScopeRealtime)
                    }
                    let presets = CloudASRVendor.modelPresets(for: provider)
                    if !presets.isEmpty {
                        Picker("模型预设", selection: modelBinding) {
                            ForEach(presets) { preset in
                                Text(preset.name).tag(preset.modelId)
                            }
                            if !presets.contains(where: { $0.modelId == provider.model }) {
                                Text("自定义模型（在下方编辑）").tag(provider.model)
                            }
                        }
                    }
                    TextField("模型 ID", text: modelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityLabel("模型 ID")
                    if provider.vendorID == .custom && provider.protocolKind == .openAICompatible {
                        Text("仅在服务商文档确认支持时启用下列字段；返回值须为包含 text 字符串的 JSON。")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        Toggle("发送 language（识别语言）", isOn: binding.customFieldCapabilities.sendLanguage)
                        Toggle("发送 prompt（上下文，仍受全局开关控制）", isOn: binding.customFieldCapabilities.sendPrompt)
                        Toggle("发送 temperature=0", isOn: binding.customFieldCapabilities.sendTemperature)
                        Toggle("发送 response_format=json", isOn: binding.customFieldCapabilities.sendResponseFormat)
                    }
                    Text(capabilityDescription)
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))

            HStack(spacing: 12) {
                Button("检查配置") {
                    checks.checkConfiguration(provider: binding.wrappedValue, apiKey: apiKeyBinding.wrappedValue)
                }
                if provider.protocolKind == .openAICompatible {
                    Button("测试识别") {
                        checks.testRecognition(provider: binding.wrappedValue, apiKey: apiKeyBinding.wrappedValue)
                    }
                }
                if checks.isTesting(provider.id) {
                    ProgressView().controlSize(.small)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(checks.isTesting(provider.id))

            Text(provider.protocolKind == .dashScopeRealtime
                 ? "检查配置仅本地校验，不联网、不发送音频；尚未连接。实时连接与识别将在真实录音时验证。"
                 : "检查配置不联网。测试识别会向当前 URL 发送 API Key 与 0.5 秒合成静音音频，可能产生费用；不使用麦克风录音。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            statusView
        }
        .padding(14)
        .glassCard(active: provider.isActive, cornerRadius: 10)
    }

    @ViewBuilder private var statusView: some View {
        switch checks.state(for: provider.id) {
        case .idle:
            Text("尚未连接").foregroundColor(.secondary)
        case .testing:
            Text("正在发送合成音频测试…").foregroundColor(.secondary)
        case .configurationValid:
            Text("配置有效；尚未连接").foregroundColor(.secondary)
        case .connected:
            Text("测试识别成功；当前配置已连接").foregroundColor(.green)
        case .failure(let message):
            Text(message).foregroundColor(.red)
        }
    }

    private var vendorName: String {
        switch provider.vendorID {
        case .siliconFlow: return "硅基流动 SiliconFlow"
        case .openAI: return "OpenAI"
        case .dashScope: return "阿里云 DashScope"
        case .custom: return "自定义兼容服务"
        }
    }

    private var capabilityDescription: String {
        if provider.protocolKind == .dashScopeRealtime {
            return "实时协议使用独立音频通道；这里不进行 WebSocket 握手或识别测试。"
        }
        let capabilities = CloudASRVendor.capabilities(for: provider)
        if provider.vendorID == .custom {
            return "默认仅发送 file / model；可选字段由上述开关决定。启用字段不代表已验证服务端支持。"
        }
        if capabilities.sendResponseFormat {
            return "当前请求发送 file / model / response_format=json；暂不发送 language、prompt 或 temperature。模型在线可用性需测试识别确认。"
        }
        return "当前请求仅发送 file / model；暂不发送 language、prompt、temperature 或 response_format。模型在线可用性需测试识别确认。"
    }
}
