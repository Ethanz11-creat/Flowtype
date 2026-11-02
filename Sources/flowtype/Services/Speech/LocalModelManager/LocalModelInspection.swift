import Foundation

/// Full token/weight/file validation is synchronous CPU and filesystem work. Keep it
/// off MainActor even when the caller is the coordinator, and drain before returning
/// cancellation so its operation reservation and the process-wide gate remain owned.
enum LocalModelInspection {
    nonisolated static func inspect(directory: URL,
        using inspect: @escaping @Sendable (URL) throws -> ImportedASRModel = { try ASRModelInspector.inspect(directory: $0) }
    ) async throws -> ImportedASRModel {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) { try inspect(directory) }
        let model = try await withTaskCancellationHandler(operation: {
            try await work.value
        }, onCancel: { work.cancel() })
        try Task.checkCancellation()
        return model
    }
}
