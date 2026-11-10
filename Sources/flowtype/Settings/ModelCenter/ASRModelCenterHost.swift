import SwiftUI

/// Views may be recreated freely; only their presentation/disclosure state is local.
struct ASRModelCenterHost: View {
    @ObservedObject var environment: ASRModelCenterEnvironment
    let navigation: SettingsNavigation?
    var target: SettingsTarget? = nil
    var requestID: UUID? = nil
    var body: some View {
        ASRModelCenterView(model: environment.model, actions: environment.actions(navigation: navigation))
            .id(requestID)
            .task(id: requestID) {
                await environment.model.refreshInstallations()
                guard !Task.isCancelled else { return }
                environment.focus(target)
            }
    }
}
