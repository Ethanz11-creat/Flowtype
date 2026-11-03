import Foundation

/// Focused native-client contracts; fixtures never launch the application UI.
enum NativeClientSelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) {
        NativeNavigationSelfTests.run(r)
    }
}
