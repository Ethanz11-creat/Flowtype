import Foundation

/// Focused native-client contracts; fixtures never launch the application UI.
enum NativeClientSelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) async {
        ProviderDraftSelfTests.run(r)
        await ProviderDraftCheckSelfTests.run(r)
        NativeNavigationSelfTests.run(r)
        await SettingsChangeSelfTests.run(r)
    }
}
