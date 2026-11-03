import SwiftUI

extension SettingsPage {
    var llmSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text("文本整理")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            Text("配置大语言模型服务商，用于将口语化的语音识别结果整理成结构化的开发指令。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("停止后自动整理", isOn: $store.current.polishOnStop)
                .toggleStyle(.switch).controlSize(.small)
            Text("停止录音后将转写文字发送给已选整理服务；仅本地识别不关闭此功能。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            effectiveStyleSection

            // Provider list
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.current.llmProviders) { provider in
                    ProviderRow(
                        provider: provider,
                        isActive: provider.isActive,
                        onSetActive: {
                            setActiveProvider(provider.id)
                        },
                        onEdit: {
                            startEditing(provider)
                        },
                        onDelete: {
                            deleteProvider(provider.id)
                        }
                    )
                }
            }

            Button {
                startAddingProvider()
            } label: {
                Label("添加 Provider", systemImage: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(Brand.accent)

            // System Prompt Editor
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("系统提示词")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("恢复默认") {
                        store.current.systemPrompt = Configuration.default.systemPrompt
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(Brand.accent)
                }

                Text("高级默认提示词仅在没有可用风格包时使用；修改这里不会覆盖当前生效风格。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $store.current.systemPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 4)
    }

    private var effectiveStyleSection: some View {
        let pack = styleStore.activePack
        return SettingsRow("生效风格", description: StylePresentation.effectiveSource(pack: pack, configuration: store.current)) {
            Button("编辑生效风格") { navigation?.navigate(to: .style(pack?.id)) }.controlSize(.small)
        }
    }
}
