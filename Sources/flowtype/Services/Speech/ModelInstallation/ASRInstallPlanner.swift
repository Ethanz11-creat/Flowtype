import Foundation

/// Produces an exact, pinned file closure. It never downloads model payloads or marks a model verified.
struct ASRInstallPlanner: Sendable {
    private let readMetadata: @Sendable (HFRepositoryFile, HFResolvedRepository) async throws -> Data
    private let metadataContext: @Sendable (HFResolvedRepository) async throws -> HFRepositoryPreflightContext
    private let registry: LocalASRRuntimeRegistry
    private let limits: HFMetadataLimits

    init(client: HFRepositoryClient, registry: LocalASRRuntimeRegistry = .standard, metadataLimits: HFMetadataLimits = .init()) {
        self.init(readMetadata: { try await client.readMetadata(file: $0, repository: $1) },
                  metadataContext: { try await client.preflightContext(for: $0) }, registry: registry, metadataLimits: metadataLimits)
    }
    init(readMetadata: @escaping @Sendable (HFRepositoryFile, HFResolvedRepository) async throws -> Data,
         metadataContext: @escaping @Sendable (HFResolvedRepository) async throws -> HFRepositoryPreflightContext,
         registry: LocalASRRuntimeRegistry = .standard, metadataLimits: HFMetadataLimits = .init()) {
        self.readMetadata = readMetadata; self.metadataContext = metadataContext
        self.registry = registry; limits = metadataLimits
    }

    func plan(repository: HFResolvedRepository, variant: String?, tokenizer: HFResolvedRepository?,
              credentialID: String? = nil) async throws -> ASRInstallPlan {
        try Task.checkCancellation()
        let repositories = [repository] + (tokenizer.map { [$0] } ?? [])
        var seenContexts = Set<UUID>(), initialBytes = 0
        var credentialIDs = Set<String>()
        for source in repositories {
            try Self.validate(source)
            let context = try await metadataContext(source) // Original result, including resolver auth identity.
            if let id = context.credentialID { credentialIDs.insert(id) }
            if let id = source.resolutionContextID, !seenContexts.insert(id).inserted { continue }
            guard context.receivedBytes >= 0, context.receivedBytes <= limits.preflightBytes - initialBytes else {
                throw ASRInstallPlanningError.metadataBudget
            }
            initialBytes += context.receivedBytes
        }
        guard credentialIDs.isSubset(of: ["asr.hf.official"]),
              credentialID == nil || (credentialID == "asr.hf.official" && credentialIDs == [credentialID!]) else {
            throw ASRInstallPlanningError.invalidCredential
        }
        var preflight = Preflight(read: readMetadata, limits: limits, consumed: initialBytes)
        let prefix = try Self.modelPrefix(repository, variant: variant)
        let manifest = Self.scoped(repository, prefix: prefix)
        let config: Data?
        if let file = manifest["config.json"] { config = try await preflight.read(file, from: repository) }
        else { config = nil }
        let engine: LocalASREngine
        do { engine = try registry.engine(config: config, paths: Array(manifest.keys)) }
        catch let error as ASRInstallPlanningError { throw error }
        catch { throw ASRInstallPlanningError.unsupportedArchitecture }
        var files: [HFPlannedFile] = []
        func planned(_ file: HFRepositoryFile, source: HFResolvedRepository, destination: String) throws -> HFPlannedFile {
            guard HFRepositoryInput.validPath(destination) else { throw ASRInstallPlanningError.invalidPath }
            return .init(source: source.selection, downloadEndpoint: source.downloadEndpoint, resolvedCommit: source.commit,
                         remotePath: file.remotePath, relativeDestination: destination, sizeBytes: file.sizeBytes, digest: file.digest)
        }
        switch engine {
        case .qwenMLX:
            var required = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"]
            let indexes = manifest.keys.filter { !$0.contains("/") && $0.hasSuffix(".safetensors.index.json") }
            guard indexes.count <= 1 else { throw ASRInstallPlanningError.invalidMetadata }
            if let indexPath = indexes.first, let indexFile = manifest[indexPath] {
                let index = try Self.object(try await preflight.read(indexFile, from: repository))
                guard let weights = index["weight_map"] as? [String: String], !weights.isEmpty else {
                    throw ASRInstallPlanningError.invalidMetadata
                }
                required.append(indexPath)
                for path in Set(weights.values).sorted() {
                    guard HFRepositoryInput.validPath(path), !path.contains("/"), path.hasSuffix(".safetensors") else { throw ASRInstallPlanningError.invalidPath }
                    required.append(path)
                }
            } else if manifest["model.safetensors"] != nil { required.append("model.safetensors") }
            else {
                let weights = manifest.keys.filter { !$0.contains("/") && $0.hasSuffix(".safetensors") }
                guard weights.count == 1, let weight = weights.first else { throw ASRInstallPlanningError.incompleteModel }
                required.append(weight)
            }
            for path in required {
                guard let file = manifest[path] else { throw ASRInstallPlanningError.incompleteModel }
                if ["vocab.json", "tokenizer_config.json"].contains(path) {
                    _ = try Self.object(try await preflight.read(file, from: repository))
                } else if path == "merges.txt" {
                    guard String(data: try await preflight.read(file, from: repository), encoding: .utf8) != nil else {
                        throw ASRInstallPlanningError.invalidMetadata
                    }
                }
                files.append(try planned(file, source: repository, destination: path))
            }
        case .whisperCoreML:
            for component in WhisperModelInspector.allComponents {
                let packages = WhisperModelInspector.packageExtensions.map { component + "." + $0 }.filter { package in
                    manifest.keys.contains { $0.hasPrefix(package + "/") }
                }
                if packages.isEmpty && component == "TextDecoderContextPrefill" { continue }
                guard packages.count == 1, let package = packages.first else { throw ASRInstallPlanningError.incompleteModel }
                try await Self.validatePackage(package, manifest: manifest, repository: repository, preflight: &preflight)
                for path in manifest.keys.sorted() where path.hasPrefix(package + "/") {
                    files.append(try planned(manifest[path]!, source: repository, destination: path))
                }
            }
            let embeddedRoots = ["", "tokenizer/"].filter { manifest[$0 + "tokenizer.json"] != nil }
            guard embeddedRoots.count <= 1 else { throw ASRInstallPlanningError.destinationCollision }
            let tokenSource: HFResolvedRepository, tokenFiles: [String: HFRepositoryFile], tokenPrefix: String
            if let root = embeddedRoots.first {
                tokenSource = repository; tokenFiles = manifest; tokenPrefix = root
            } else {
                guard let tokenizer else { throw ASRInstallPlanningError.tokenizerRequired }
                // Known OpenAI variants cannot silently receive another variant's tokenizer.
                if let expected = ASRModelRecipes.tokenizerRepoID(forVariant: prefix.split(separator: "/").last.map(String.init)),
                   tokenizer.selection.repoID.hasPrefix("openai/"), tokenizer.selection.repoID != expected {
                    throw ASRInstallPlanningError.tokenizerMismatch
                }
                tokenSource = tokenizer; tokenFiles = Self.scoped(tokenizer, prefix: tokenizer.selection.subdirectory ?? ""); tokenPrefix = ""
            }
            for name in ["tokenizer.json", "tokenizer_config.json"] {
                guard let file = tokenFiles[tokenPrefix + name] else { throw ASRInstallPlanningError.incompleteModel }
                let object = try Self.object(try await preflight.read(file, from: tokenSource))
                if name == "tokenizer.json" {
                    guard let model = object["model"] as? [String: Any], let vocab = model["vocab"] as? [String: Any], !vocab.isEmpty else {
                        throw ASRInstallPlanningError.invalidMetadata
                    }
                } else if object.isEmpty { throw ASRInstallPlanningError.invalidMetadata }
                files.append(try planned(file, source: tokenSource, destination: "tokenizer/" + name))
            }
            // Optional tokenizer assets are kept local too, without pulling model weights from its source.
            for name in ["special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt", "normalizer.json"] {
                if let file = tokenFiles[tokenPrefix + name] {
                    let data = try await preflight.read(file, from: tokenSource)
                    if name.hasSuffix(".json") { _ = try Self.object(data) }
                    files.append(try planned(file, source: tokenSource, destination: "tokenizer/" + name))
                }
            }
        }
        try Self.validateFilePaths(files.map(\.relativeDestination))
        var total: Int64 = 0
        for file in files {
            let sum = total.addingReportingOverflow(file.sizeBytes)
            guard !sum.overflow else { throw ASRInstallPlanningError.totalSizeOverflow }
            total = sum.partialValue
        }
        guard files.count <= 10_000 else { throw HFRepositoryError.fileLimit }
        let recipe = ASRModelRecipes.match(repository: repository, tokenizer: tokenizer, prefix: prefix, engine: engine)
        return .init(id: UUID(), displayName: recipe?.displayName ?? repository.selection.repoID + (prefix.isEmpty ? "" : "/" + prefix),
                     engine: engine, files: files.sorted { $0.relativeDestination < $1.relativeDestination }, totalBytes: total,
                     recipeID: recipe?.id, recipeVersion: recipe?.version ?? 0, credentialID: credentialIDs.first)
    }

    private struct Preflight {
        let read: @Sendable (HFRepositoryFile, HFResolvedRepository) async throws -> Data
        let limits: HFMetadataLimits
        var consumed: Int
        var cache: [String: Data] = [:]
        mutating func read(_ file: HFRepositoryFile, from repository: HFResolvedRepository) async throws -> Data {
            let key = (repository.resolutionContextID?.uuidString ?? repository.selection.repoID + repository.commit) + ":" + file.remotePath
            if let cached = cache[key] { return cached }
            guard file.sizeBytes >= 0, file.sizeBytes <= Int64(limits.responseBytes),
                  file.sizeBytes <= Int64(limits.preflightBytes - consumed) else { throw ASRInstallPlanningError.metadataBudget }
            try Task.checkCancellation()
            let data = try await read(file, repository)
            guard data.count <= limits.responseBytes, data.count <= limits.preflightBytes - consumed else { throw ASRInstallPlanningError.metadataBudget }
            consumed += data.count
            guard Int64(data.count) == file.sizeBytes else { throw ASRInstallPlanningError.invalidMetadata }
            cache[key] = data
            return data
        }
    }
    /// Conservatively require a portable case-insensitive macOS layout, even on case-sensitive volumes.
    /// A file cannot also name a directory after canonical Unicode normalization and case folding.
    /// Every normalized directory must retain one spelling across all files. Canonically equivalent
    /// Unicode spellings compare equal, matching the publisher's exact Swift String inventory.
    static func validateFilePaths(_ paths: [String]) throws {
        var files = Set<String>()
        var directorySpellings: [String: String] = [:]
        for path in paths {
            guard HFRepositoryInput.validPath(path) else { throw ASRInstallPlanningError.invalidPath }
            let original = path.components(separatedBy: "/")
            let components = original.map {
                $0.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    .precomposedStringWithCanonicalMapping
            }
            for depth in 1..<components.count {
                let key = components.prefix(depth).joined(separator: "/")
                let spelling = original.prefix(depth).joined(separator: "/")
                if let previous = directorySpellings[key], previous != spelling {
                    throw ASRInstallPlanningError.destinationCollision
                }
                directorySpellings[key] = spelling
            }
            guard files.insert(components.joined(separator: "/")).inserted else {
                throw ASRInstallPlanningError.destinationCollision
            }
        }
        // Collect all files first so either enumeration order catches a file/directory conflict.
        for file in files {
            var ancestor = file[...]
            while let slash = ancestor.lastIndex(of: "/") {
                ancestor = ancestor[..<slash]
                guard !files.contains(String(ancestor)) else { throw ASRInstallPlanningError.destinationCollision }
            }
        }
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ASRInstallPlanningError.invalidMetadata }
        return object
    }
    private static func validate(_ repository: HFResolvedRepository) throws {
        guard repository.files.count <= 10_000 else { throw HFRepositoryError.fileLimit }
        for file in repository.files {
            guard HFRepositoryInput.validPath(file.remotePath), file.sizeBytes >= 0,
                  repository.selection.subdirectory.map({ file.remotePath.hasPrefix($0 + "/") }) ?? true else { throw ASRInstallPlanningError.invalidPath }
        }
        try validateFilePaths(repository.files.map(\.remotePath))
    }
    private static func scoped(_ repository: HFResolvedRepository, prefix: String) -> [String: HFRepositoryFile] {
        let start = prefix.isEmpty ? "" : prefix + "/"
        return Dictionary(uniqueKeysWithValues: repository.files.filter { $0.remotePath.hasPrefix(start) }.map {
            (String($0.remotePath.dropFirst(start.count)), $0)
        })
    }
    private static func modelPrefix(_ repository: HFResolvedRepository, variant: String?) throws -> String {
        let base = repository.selection.subdirectory ?? ""
        if let variant {
            guard HFRepositoryInput.validPath(variant) else { throw ASRInstallPlanningError.invalidPath }
            let prefix = base.isEmpty || variant == base || variant.hasPrefix(base + "/") ? variant : base + "/" + variant
            guard repository.files.contains(where: { $0.remotePath.hasPrefix(prefix + "/") }) else { throw ASRInstallPlanningError.invalidVariant }
            return prefix
        }
        let manifest = scoped(repository, prefix: base)
        var parents = Set<String>()
        for path in manifest.keys {
            let parts = path.components(separatedBy: "/")
            for (i, part) in parts.enumerated() where WhisperModelInspector.allComponents.contains(where: { name in
                WhisperModelInspector.packageExtensions.contains { part == name + "." + $0 }
            }) {
                parents.insert(parts.prefix(i).joined(separator: "/"))
            }
        }
        guard parents.count <= 1 else { throw ASRInstallPlanningError.variantRequired }
        guard let parent = parents.first else { return base }
        return [base, parent].filter { !$0.isEmpty }.joined(separator: "/")
    }
    private static func validatePackage(_ package: String, manifest: [String: HFRepositoryFile],
                                        repository: HFResolvedRepository, preflight: inout Preflight) async throws {
        func required(_ path: String) throws -> HFRepositoryFile {
            guard let file = manifest[path], file.sizeBytes > 0 else { throw ASRInstallPlanningError.incompleteModel }
            return file
        }
        if package.hasSuffix(".mlmodelc") {
            _ = try required(package + "/coremldata.bin")
            let data = try await preflight.read(required(package + "/model.mil"), from: repository)
            guard let source = String(data: data, encoding: .utf8), !source.isEmpty else { throw ASRInstallPlanningError.invalidMetadata }
            let regex = try NSRegularExpression(pattern: #"@model_path/([^"\s]+)"#)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let path = String(source[range])
                guard HFRepositoryInput.validPath(path) else { throw ASRInstallPlanningError.invalidPath }
                _ = try required(package + "/" + path)
            }
        } else {
            let object = try object(try await preflight.read(required(package + "/Manifest.json"), from: repository))
            guard let rootID = object["rootModelIdentifier"] as? String,
                  let entries = object["itemInfoEntries"] as? [String: [String: Any]],
                  let rootPath = entries[rootID]?["path"] as? String, rootPath.hasSuffix(".mlmodel") else { throw ASRInstallPlanningError.invalidMetadata }
            for entry in entries.values {
                guard let path = entry["path"] as? String, HFRepositoryInput.validPath(path) else { throw ASRInstallPlanningError.invalidPath }
                let resource = package + "/Data/" + path
                guard manifest[resource] != nil || manifest.keys.contains(where: { $0.hasPrefix(resource + "/") }) else {
                    throw ASRInstallPlanningError.incompleteModel
                }
            }
            _ = try required(package + "/Data/" + rootPath)
        }
        guard !manifest.contains(where: { $0.key.hasPrefix(package + "/") && $0.value.sizeBytes == 0 }) else {
            throw ASRInstallPlanningError.incompleteModel
        }
    }
}
