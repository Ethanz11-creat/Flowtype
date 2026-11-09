import Foundation

enum HFInstallSelfTests {
    static func run(_ r: SelfTest.Reporter) async {
        await HFRepositorySelfTests.run(r)
    }
}
