import SwiftUI

/// Legacy links retain profile UUIDs and delegate all editing/testing/selection to the shared host.
struct CloudASRProviderList: View {
    @ObservedObject var store: ConfigurationStore
    @ObservedObject var checks: CloudASRConnectionCheck
    @ObservedObject var draftChecks: CloudASRConnectionCheck
    var navigation: SettingsNavigation? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("云端服务的配置、试识别与选择已移至模型中心。")
                .foregroundStyle(.secondary)
            ForEach(store.current.cloudASRConfig.providers) { provider in
                Button(provider.name + " · " + provider.model) {
                    navigation?.navigate(to: .settings(.speech, .provider(provider.id)))
                }.disabled(navigation == nil).id(provider.id)
            }
            Button("打开模型中心") { navigation?.navigate(to: .settings(.speech)) }
                .disabled(navigation == nil)
        }
    }
}
