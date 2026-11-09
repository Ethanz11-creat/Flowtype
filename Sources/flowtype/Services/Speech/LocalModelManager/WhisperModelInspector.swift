import Foundation

/// Package completeness only. C2 must load and verify graph inputs/outputs, vocabulary and variant offline.
enum WhisperModelInspector {
    static let components = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
    static let allComponents = components + ["TextDecoderContextPrefill"]
    static let packageExtensions = ["mlmodelc", "mlpackage"]
    static func hasModelComponents(_ directory: URL) -> Bool {
        components.contains { name in packageExtensions.contains { ext in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + "." + ext).path)
        } }
    }
    static func inspect(directory: URL) throws -> ImportedASRModel {
        let files = LocalInspectionFiles()
        var size: Int64 = 0
        for name in allComponents {
            let packages = packageExtensions.map { directory.appendingPathComponent(name + "." + $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if packages.isEmpty && name == "TextDecoderContextPrefill" { continue }
            guard packages.count == 1, let package = packages.first else { throw failure(.incompleteModel, "缺少或重复的 Core ML 组件：\(name)") }
            if package.pathExtension == "mlmodelc" {
                let core = try files.identity(package.appendingPathComponent("coremldata.bin"))
                guard core.size > 0 else { throw failure(.incompleteModel, "Core ML 编译数据为空。") }
                // Supported compiled ML Program layout. Runtime validation handles the actual graph semantics.
                let mil = try files.read(package.appendingPathComponent("model.mil"))
                guard !mil.isEmpty, let source = String(data: mil, encoding: .utf8) else { throw failure(.incompleteModel, "缺少 Core ML ML Program 图。") }
                let pattern = #"@model_path/([^"\s]+)"#
                let regex = try NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    guard let range = Range(match.range(at: 1), in: source) else { continue }
                    let relative = String(source[range]); try validateRelative(relative)
                    let identity = try files.identity(package.appendingPathComponent(relative))
                    guard identity.size > 0 else { throw failure(.incompleteModel, "Core ML 权重为空。") }
                }
            } else {
                let manifest = try files.json(package.appendingPathComponent("Manifest.json"))
                guard let rootID = manifest["rootModelIdentifier"] as? String,
                      let entries = manifest["itemInfoEntries"] as? [String: [String: Any]],
                      let root = entries[rootID], let rootPath = root["path"] as? String,
                      rootPath.hasSuffix(".mlmodel") else { throw failure(.invalidMetadata, "Core ML package manifest 无效。") }
                for entry in entries.values {
                    guard let relative = entry["path"] as? String else { throw failure(.invalidMetadata, "Core ML package 缺少资源路径。") }
                    try validateRelative(relative)
                    let resource = package.appendingPathComponent("Data").appendingPathComponent(relative)
                    guard FileManager.default.fileExists(atPath: resource.path) else { throw failure(.incompleteModel, "Core ML package 缺少声明的资源。") }
                }
                let model = try files.identity(package.appendingPathComponent("Data").appendingPathComponent(rootPath))
                guard model.size > 0 else { throw failure(.incompleteModel, "Core ML 模型为空。") }
            }
            // Walk only the selected package, bound entries, reject broken links and cycles.
            var visited = Set<String>(); var count = 0
            func walk(_ url: URL) throws {
                count += 1
                guard count <= 10000 else { throw failure(.invalidMetadata, "Core ML package 文件数量过多。") }
                let real = url.resolvingSymlinksInPath(); var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDir) else { throw failure(.unreadable, "Core ML package 包含断链。") }
                if isDir.boolValue {
                    guard visited.insert(real.path).inserted else { throw failure(.invalidMetadata, "Core ML package 包含目录链接循环。") }
                    for item in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try walk(item) }
                } else {
                    let identity = try files.identity(url)
                    guard identity.size > 0 else { throw failure(.incompleteModel, "Core ML package 包含空文件。") }
                    // Detect LFS pointers without reading model payloads.
                    let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
                    let prefix = try h.read(upToCount: 64) ?? Data()
                    guard !prefix.starts(with: Data("version https://git-lfs.github.com/spec/".utf8)) else { throw failure(.incompleteModel, "Core ML 文件仍是 LFS 指针。") }
                    try files.record(url, before: identity)
                    let sum = size.addingReportingOverflow(identity.size)
                    guard !sum.overflow else { throw failure(.invalidMetadata, "Core ML package 大小溢出。") }; size = sum.partialValue
                }
            }
            try walk(package)
        }
        let candidates = [directory, directory.appendingPathComponent("tokenizer", isDirectory: true)]
        let tokenizerDirs = candidates.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tokenizer.json").path) }
        guard tokenizerDirs.count == 1, let tokenizer = tokenizerDirs.first else { throw failure(.incompleteModel, "请在模型包或 tokenizer 子目录提供唯一完整的本地分词器。") }
        let tokenizerJSON = try files.json(tokenizer.appendingPathComponent("tokenizer.json"))
        let tokenizerConfig = try files.json(tokenizer.appendingPathComponent("tokenizer_config.json"))
        guard let model = tokenizerJSON["model"] as? [String: Any], let vocab = model["vocab"] as? [String: Any], !vocab.isEmpty,
              !tokenizerConfig.isEmpty else { throw failure(.invalidMetadata, "Whisper 本地分词器元数据无效。") }
        try files.verify()
        return ImportedASRModel(name: directory.lastPathComponent, directory: directory.resolvingSymlinksInPath(), engine: .whisperCoreML,
                                variant: "unverified", bits: nil, sizeBytes: size, tokenizerDirectory: tokenizer.resolvingSymlinksInPath(), fileFingerprint: files.fingerprint)
    }
    private static func validateRelative(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains("..") else {
            throw failure(.invalidMetadata, "Core ML 资源路径越界。")
        }
    }
}
