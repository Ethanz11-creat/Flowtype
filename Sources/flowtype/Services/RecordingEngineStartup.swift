/// Synchronous engine boundary: every startup failure signals interruption before
/// ending the spectrum stream, so it cannot look like a successful empty capture.
enum RecordingEngineStartup {
    static func run(prepare: () -> Void, start: () throws -> Void,
                    onFailure: () -> Void, finish: () -> Void) {
        prepare()
        do { try start() }
        catch {
            onFailure()
            finish()
        }
    }
}
