import Foundation
import CoreML

/// Owns only generated runtime files; the caller's original directory is never removed.
final class PreparedWhisperModels: Sendable {
    let directory: URL
    private let ownedDirectory: URL?
    init(directory: URL, ownedDirectory: URL? = nil) {
        self.directory = directory
        self.ownedDirectory = ownedDirectory
    }
    deinit {
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
    }
}

enum WhisperModelPreparation {
    typealias Compiler = @Sendable (URL, URL) throws -> Void
    static func prepare(directory: URL, compile: @escaping Compiler = compilePackage) async throws -> PreparedWhisperModels {
        try Task.checkCancellation()
        // Detached synchronous work cannot inherit a caller's MainActor executor.
        // Await its actual completion even after cancellation: compilation may not stop.
        let work = Task.detached(priority: .userInitiated) {
            try prepareSynchronously(directory: directory, compile: compile)
        }
        let prepared = try await withTaskCancellationHandler(operation: {
            try await work.value
        }, onCancel: { work.cancel() })
        try Task.checkCancellation()
        return prepared
    }
    private static func prepareSynchronously(directory: URL, compile: Compiler) throws -> PreparedWhisperModels {
        guard directory.isFileURL else { throw OfflineWhisperError.invalidLocalDirectory }
        let fm = FileManager.default
        let required = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        var components: [(name: String, source: URL)] = []
        for name in required + ["TextDecoderContextPrefill"] {
            let matches = ["mlmodelc", "mlpackage"].map { directory.appendingPathComponent(name + "." + $0) }
                .filter { fm.fileExists(atPath: $0.path) }
            if matches.isEmpty && !required.contains(name) { continue }
            guard matches.count == 1, let source = matches.first else { throw OfflineWhisperError.invalidLocalDirectory }
            components.append((name, source))
        }
        try Task.checkCancellation()
        // Already compiled imports retain their original path and avoid any temporary work.
        guard components.contains(where: { $0.source.pathExtension == "mlpackage" }) else {
            return PreparedWhisperModels(directory: directory)
        }
        let root = fm.temporaryDirectory.appendingPathComponent("flowtype-whisper-runtime-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let prepared = PreparedWhisperModels(directory: root, ownedDirectory: root)
        for component in components {
            try Task.checkCancellation()
            let destination = root.appendingPathComponent(component.name + ".mlmodelc")
            if component.source.pathExtension == "mlpackage" {
                // Pass the whole package: Core ML resolves its Manifest and external resources.
                try compile(component.source, destination)
            } else {
                // Do not duplicate caller-owned multi-GB compiled weights in mixed imports.
                try fm.createSymbolicLink(at: destination, withDestinationURL: component.source)
            }
            try Task.checkCancellation()
        }
        return prepared
    }

    static func compilePackage(_ source: URL, _ destination: URL) throws {
        let compiled = try MLModel.compileModel(at: source)
        defer { try? FileManager.default.removeItem(at: compiled) }
        try FileManager.default.moveItem(at: compiled, to: destination)
    }
}
