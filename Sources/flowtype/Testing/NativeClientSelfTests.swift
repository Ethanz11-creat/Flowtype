import Foundation

/// Focused native-client contracts; fixtures never launch the application UI.
enum NativeClientSelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) async {
        await OnboardingFlowSelfTests.run(r)
        await TrialSessionSelfTests.run(r)
        await SelfTest.testOnboardingDemoDelivery(r)
        await SelfTest.testOnboardingDeliveryCancellation(r)
        await SelfTest.testOnboardingDemoTeardown(r)
        NativeHistorySelfTests.run(r)
        ProviderDraftSelfTests.run(r)
        await ProviderDraftCheckSelfTests.run(r)
        NativeNavigationSelfTests.run(r)
        ReadinessPresentationSelfTests.run(r)
        await LocalSettingsOwnershipSelfTests.run(r)
        await SettingsChangeSelfTests.run(r)
        await NativeModelPresentationSelfTests.run(r)
        await ImportedModelUISelfTests.run(r)
        await ModelProvisionSelfTests.runPresentationAndRouting(r)
    }
}
