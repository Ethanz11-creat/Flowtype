#!/usr/bin/env swift
import Foundation
import CryptoKit
import Darwin

struct ManifestMetadata: Codable {
    let schemaVersion: Int; let version: String; let buildNumber: String; let gitSHA: String
    let sourceTree: String; let builtAt: String; let dirty: Bool
}
func canonical(_ path: String) throws -> URL {
    guard let resolved = realpath(path, nil) else { throw NSError(domain: "path", code: 1) }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}

func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func execute(_ args: [String]) throws {
    guard args.count == 4, args[0] == "--app", args[2] == "--output", args[1].hasPrefix("/"), args[3].hasPrefix("/") else {
        throw NSError(domain: "usage", code: 64)
    }
    let app = try canonical(args[1])
    let requestedOutput = URL(fileURLWithPath: args[3])
    let output = try canonical(requestedOutput.deletingLastPathComponent().path).appendingPathComponent(requestedOutput.lastPathComponent)
    guard !output.path.hasPrefix(app.path + "/"), !FileManager.default.fileExists(atPath: output.path) else { throw NSError(domain: "output", code: 1) }
    let metadataURL = app.appendingPathComponent("Contents/Resources/FlowTypeBuild.json")
    let metadata = try JSONDecoder().decode(ManifestMetadata.self, from: Data(contentsOf: metadataURL))
    func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    guard metadata.schemaVersion == 1, !metadata.dirty,
          matches(metadata.version, #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#), matches(metadata.buildNumber, #"\A[0-9]+\z"#),
          matches(metadata.gitSHA, #"\A[0-9a-f]{40}\z"#), matches(metadata.sourceTree, #"\A[0-9a-f]{40}\z"#),
          matches(metadata.builtAt, #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z"#) else { throw NSError(domain: "identity", code: 1) }
    let resourcesRoot = app.appendingPathComponent("Contents/Resources")
    guard let files = FileManager.default.enumerator(at: resourcesRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw NSError(domain: "resources", code: 1) }
    var resources: [[String: String]] = []
    while let file = files.nextObject() as? URL {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw NSError(domain: "resourceLink", code: 1) }
        if values.isRegularFile == true {
            resources.append(["path": String(file.path.dropFirst(app.path.count + 1)), "sha256": try digest(file)])
        }
    }
    resources.sort { $0["path"]! < $1["path"]! }
    let manifest: [String: Any] = ["schemaVersion": 1, "buildInfo": try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)), "architecture": "arm64",
        "binarySHA256": try digest(app.appendingPathComponent("Contents/MacOS/FlowType")),
        "buildInfoSHA256": try digest(metadataURL),
        "shaderSHA256": try digest(app.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib")), "resources": resources]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
}
do { try execute(Array(CommandLine.arguments.dropFirst())) }
catch { FileHandle.standardError.write(Data("FlowType manifest generation failed\n".utf8)); exit((error as NSError).code == 64 ? 64 : 1) }
