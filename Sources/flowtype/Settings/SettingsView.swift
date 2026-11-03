import SwiftUI

// MARK: - Settings View

struct SettingsPage: View {
    var navigation: SettingsNavigation? = nil
    @ObservedObject var store = ConfigurationStore.shared
    @State var hasAccessibility = false
    @State var availableDevices: [AudioDevice] = []
    @State var selectedDeviceUnavailable: Bool = false
    @State var providerDraft: LLMProviderDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Title
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("设置")
                            .font(Theme.Typography.pageTitle)
                        Text("配置语音识别与文本润色服务")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("更改会自动保存")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)

                appearanceSection
                Divider().padding(.vertical, 4)
                asrSection
                Divider().padding(.vertical, 4)
                llmSection
                Divider().padding(.vertical, 4)
                recordingSection
                Divider().padding(.vertical, 4)
                privacySection
                Divider().padding(.vertical, 4)
                triggerSection
                Divider().padding(.vertical, 4)
                permissionSection
                diagnosticsSection

                Spacer(minLength: 20)
            }
            .frame(maxWidth: StatsConfig.contentMaxWidth)
            .padding(.horizontal, StatsConfig.contentHorizontalPadding)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            hasAccessibility = PermissionHelper.checkAccessibility()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                hasAccessibility = PermissionHelper.checkAccessibility()
            }
        }
        .sheet(item: $providerDraft) { draft in
            ProviderEditSheet(
                draft: draft,
                navigation: navigation,
                hadStoredKey: !(store.current.providerAPIKeys[draft.id.uuidString] ?? "").isEmpty,
                storedKey: { store.current.providerAPIKeys[draft.id.uuidString] ?? "" },
                validate: { draft in
                    var latest = store.current
                    try ProviderDraftCommit.apply(draft, to: &latest)
                },
                onSave: { draft in
                    var latest = store.current
                    try ProviderDraftCommit.apply(draft, to: &latest)
                    store.save(latest)
                    providerDraft = nil
                },
                onCancel: { providerDraft = nil }
            )
        }
    }
}
