import SwiftUI

struct CloudASRProviderList: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var checks: CloudASRConnectionCheck
    // This owner survives closing/reopening sheets, including the same profile UUID.
    @ObservedObject var draftChecks: CloudASRConnectionCheck
    @State private var editor: Editor?
    @State private var actionMessage: String?
    @State private var pendingDeletion: UUID?
    var navigation: SettingsNavigation? = nil

    private struct Editor: Identifiable {
        let id = UUID()
        let draft: ASRProviderDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("云端服务").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if let actionMessage { Text(actionMessage).font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(store.current.cloudASRConfig.providers) { provider in
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name).font(.system(size: 13, weight: .medium))
                            Text(provider.model.isEmpty ? "待填写模型 ID" : provider.model)
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(checks.state(for: provider.id).displayText)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if ASRSettingsAction.isCloudPrimary(provider.id, in: store.current) {
                            Label("已选", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12)).foregroundStyle(Brand.accent)
                        } else {
                            Button("选用") { apply(.activateCloud(provider.id)) }
                        }
                        Button("编辑") {
                            editor = Editor(draft: ASRProviderDraft(target: .existing(provider.id), profile: provider))
                        }
                        Button("删除", role: .destructive) {
                            if ASRSettingsAction.referencesCloud(provider.id, in: store.current) { pendingDeletion = provider.id }
                            else { apply(.deleteCloud(provider.id, confirmSelected: false)) }
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.vertical, 10)
                    Divider()
                }
                .id(provider.id)
            }
            Menu("添加云端服务") {
                Button("硅基流动 SiliconFlow") { addProvider(.siliconFlow) }
                Button("OpenAI") { addProvider(.openAI) }
                Button("阿里云 Paraformer 实时") { addProvider(.dashScope) }
                Button("自定义兼容服务") { addProvider(.custom) }
            }
            .controlSize(.small)
        }
        .confirmationDialog("删除所选服务？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("删除并保留不可用选择", role: .destructive) {
                if let id = pendingDeletion { apply(.deleteCloud(id, confirmSelected: true)) }
                pendingDeletion = nil
            }
        } message: { Text("该服务仍被主选或备选引用。删除后不会自动选用其他服务，请明确选择替代项。") }
        .sheet(item: $editor) { item in
            ASRProviderEditSheet(draft: item.draft, checks: draftChecks, navigation: navigation,
                hadStoredKey: ((try? store.cloudASRCredential(profileID: item.draft.target.id).value)?.isEmpty == false),
                storedKey: { try store.cloudASRCredential(profileID: item.draft.target.id).value ?? "" },
                onSave: { draft in
                    try store.saveASRDraft(draft)
                    checks.invalidate(profileID: draft.target.id)
                    draftChecks.invalidate(profileID: draft.target.id)
                    editor = nil
                }, onCancel: { editor = nil })
        }
        .onDisappear {
            if let editor { draftChecks.invalidate(profileID: editor.draft.target.id) }
        }
    }

    private func apply(_ action: ASRSettingsAction) {
        do {
            let before = store.current.cloudASRConfig
            try store.applyASRSettingsAction(action)
            checks.synchronize(old: before, new: store.current.cloudASRConfig)
            draftChecks.synchronize(old: before, new: store.current.cloudASRConfig)
            if case .deleteCloud(let id, _) = action {
                actionMessage = ASRSettingsAction.referencesCloud(id, in: store.current)
                    ? "已删除服务；原选择现不可用，请明确选用替代服务。" : nil
            } else { actionMessage = nil }
        } catch { actionMessage = error.localizedDescription }
    }

    private func addProvider(_ vendor: CloudASRVendorID) {
        let profile = CloudASRVendor.makeProfile(vendor, isActive: false)
        editor = Editor(draft: ASRProviderDraft(target: .new(profile.id), profile: profile))
    }
}
