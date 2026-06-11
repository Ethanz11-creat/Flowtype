import SwiftUI

// MARK: - Settings View

struct SettingsPage: View {
    @ObservedObject var store = ConfigurationStore.shared
    @State var showSaved = false
    @State var hasAccessibility = false
    @State var availableDevices: [AudioDevice] = []
    @State var selectedDeviceUnavailable: Bool = false
    // Provider sheet states
    @State var showAddProvider = false
    @State var editingProvider: LLMProvider? = nil
    @State var draftProvider = LLMProvider(name: "", provider: "SiliconFlow", baseURL: "https://api.siliconflow.cn/v1", model: "", isActive: false)
    @State var draftApiKey = ""
    @State var editingHadStoredKey = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Title
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("设置")
                            .font(.system(size: 22, weight: .bold))
                        Text("配置语音识别与文本润色服务")
                            .font(.system(size: 12))
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
            .padding(24)
        }
        .frame(minWidth: 520, maxWidth: 580, minHeight: 600, maxHeight: .infinity)
        .onAppear {
            hasAccessibility = PermissionHelper.checkAccessibility()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                hasAccessibility = PermissionHelper.checkAccessibility()
            }
        }
        .onChange(of: store.current) { _, _ in
            store.save(store.current)
            WindowManager.shared.reloadHotkey()
            withAnimation(.easeInOut(duration: 0.2)) {
                showSaved = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showSaved = false
                }
            }
        }
        .overlay(alignment: .top) {
            if showSaved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text("设置已自动保存")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.9))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showAddProvider) {
            ProviderEditSheet(
                provider: .init(
                    get: { draftProvider },
                    set: { draftProvider = $0 }
                ),
                apiKey: $draftApiKey,
                existingProviders: store.current.llmProviders,
                onSave: {
                    let newProvider = LLMProvider(
                        name: draftProvider.name,
                        provider: draftProvider.provider,
                        baseURL: draftProvider.baseURL,
                        model: draftProvider.model,
                        isActive: store.current.llmProviders.isEmpty
                    )
                    store.current.llmProviders.append(newProvider)
                    if !draftApiKey.isEmpty {
                        ConfigurationStore.shared.saveProviderAPIKey(draftApiKey, for: newProvider.id)
                    }
                    store.save(store.current)   // persist the provider list, not just the in-memory copy
                    showAddProvider = false
                },
                onCancel: {
                    showAddProvider = false
                }
            )
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditSheet(
                provider: $draftProvider,
                apiKey: $draftApiKey,
                existingProviders: store.current.llmProviders.filter { $0.id != provider.id },
                hadStoredKey: editingHadStoredKey,
                onSave: {
                    if let idx = store.current.llmProviders.firstIndex(where: { $0.id == provider.id }) {
                        store.current.llmProviders[idx] = draftProvider
                    }
                    if draftApiKey.isEmpty {
                        ConfigurationStore.shared.deleteProviderAPIKey(provider.id)
                    } else {
                        ConfigurationStore.shared.saveProviderAPIKey(draftApiKey, for: provider.id)
                    }
                    store.save(store.current)
                    editingProvider = nil
                },
                onCancel: {
                    editingProvider = nil
                }
            )
            .onAppear {
                draftProvider = provider
                draftApiKey = ConfigurationStore.shared.loadProviderAPIKey(provider.id) ?? ""
                editingHadStoredKey = !draftApiKey.isEmpty
            }
        }
    }
}
