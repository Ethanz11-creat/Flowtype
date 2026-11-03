import SwiftUI

struct CloudASRProviderList: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var checks: CloudASRConnectionCheck
    // This owner survives closing/reopening sheets, including the same profile UUID.
    @ObservedObject var draftChecks: CloudASRConnectionCheck
    @State private var editor: Editor?
    var navigation: SettingsNavigation? = nil

    private struct Editor: Identifiable {
        let id = UUID()
        let draft: ASRProviderDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("云端服务").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
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
                        if provider.isActive {
                            Label("已选", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12)).foregroundStyle(Brand.accent)
                        } else {
                            Button("选用") { checks.setActive(true, profileID: provider.id, in: &store.current.cloudASRConfig) }
                        }
                        Button("编辑") {
                            editor = Editor(draft: ASRProviderDraft(target: .existing(provider.id), profile: provider))
                        }
                        Button("删除", role: .destructive) {
                            draftChecks.invalidate(profileID: provider.id)
                            checks.deleteProfile(provider.id, in: &store.current.cloudASRConfig)
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
        .sheet(item: $editor) { item in
            ASRProviderEditSheet(draft: item.draft, checks: draftChecks, navigation: navigation,
                hadStoredKey: !(store.current.cloudASRConfig.providerAPIKeys[item.draft.target.id.uuidString] ?? "").isEmpty,
                storedKey: { store.current.cloudASRConfig.providerAPIKeys[item.draft.target.id.uuidString] ?? "" },
                onSave: { draft in
                    var latest = store.current
                    try ProviderDraftCommit.apply(draft, to: &latest)
                    checks.invalidate(profileID: draft.target.id)
                    draftChecks.invalidate(profileID: draft.target.id)
                    store.current = latest
                    editor = nil
                }, onCancel: { editor = nil })
        }
        .onDisappear {
            if let editor { draftChecks.invalidate(profileID: editor.draft.target.id) }
        }
    }

    private func addProvider(_ vendor: CloudASRVendorID) {
        let profile = CloudASRVendor.makeProfile(vendor, isActive: false)
        editor = Editor(draft: ASRProviderDraft(target: .new(profile.id), profile: profile))
    }
}
