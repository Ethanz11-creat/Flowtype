import Foundation
import CreateML
import CoreML

// Only the error type is stubbed to compile the exact product preparation source alone.
enum OfflineWhisperError: Error { case invalidLocalDirectory }

@main struct NativeSmoke {
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try MLDataTable(dictionary: ["x": [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0],
                                              "y": [1.0, 3.0, 5.0, 7.0, 9.0, 11.0, 13.0, 15.0]])
        let regression = try MLLinearRegressor(trainingData: data, targetColumn: "y",
                                               parameters: .init(validationData: nil, l2Penalty: 0))
        let source = root.appendingPathComponent("regression.mlmodel")
        try regression.write(to: source)
        let names = ["MelSpectrogram", "AudioEncoder", "TextDecoder", "TextDecoderContextPrefill"]
        for (index, name) in names.enumerated() {
            let package = root.appendingPathComponent(name + ".mlpackage")
            let path = index == 0 ? "com.apple.CoreML/model.mlmodel" : "custom/exported.mlmodel"
            let destination = package.appendingPathComponent("Data/" + path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
            let id = UUID().uuidString
            let manifest: [String: Any] = ["fileFormatVersion": "1.0.0", "rootModelIdentifier": id,
                "itemInfoEntries": [id: ["path": path, "name": "model.mlmodel", "author": "com.apple.CoreML", "description": "CoreML Model Specification"]]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("Manifest.json"))
        }
        var prepared: PreparedWhisperModels? = try await WhisperModelPreparation.prepare(directory: root)
        let generated = prepared!.directory
        for name in names {
            let url = generated.appendingPathComponent(name + ".mlmodelc")
            let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
            let model = try await MLModel.load(contentsOf: url, configuration: configuration)
            let result = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": 3.0]))
            guard let output = result.featureValue(for: "y")?.doubleValue, abs(output - 7) < 0.01 else {
                fatalError("Native compiled model prediction mismatch")
            }
            print("PASS native whole-package compile + compiled load + CPU prediction: \(name), root \(name == names[0] ? "conventional" : "alternate")")
        }
        prepared = nil
        guard !fm.fileExists(atPath: generated.path), fm.fileExists(atPath: source.path) else { fatalError("Ownership cleanup mismatch") }
        print("PASS generated resources removed, source preserved. Tiny regression only; NOT Whisper inference.")
    }
}
