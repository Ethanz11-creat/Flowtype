import Foundation
import CryptoKit

/// Synthetic manifests and injected metadata only: never reads user state or model payloads.
enum HFInstallPlannerSelfTests {
    static let commit = String(repeating: "a", count: 40)
    static let tokenizerCommit = String(repeating: "b", count: 40)
    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static var qwenConfig: Data { json(["model_type": "qwen3_asr", "quantization": ["bits": 4, "group_size": 64], "thinker_config": ["audio_config": ["d_model": 896, "encoder_layers": 18, "encoder_attention_heads": 14, "encoder_ffn_dim": 3584, "num_mel_bins": 128, "output_dim": 1024, "downsample_hidden_size": 480], "text_config": ["hidden_size": 1024, "num_hidden_layers": 28, "num_attention_heads": 16, "num_key_value_heads": 8, "head_dim": 128, "intermediate_size": 3072, "vocab_size": 151936, "tie_word_embeddings": true]]]) }
    struct Fixture: Sendable {
        let repository: HFResolvedRepository
        let data: [String: Data]
        init(repoID: String = "org/model", commit: String = HFInstallPlannerSelfTests.commit,
             prefix: String? = nil, data: [String: Data], weights: [String] = [], additional: [HFRepositoryFile] = []) {
            self.data = data
            repository = .init(selection: .init(repoID: repoID, requestedRevision: "refs/pr/12", subdirectory: prefix),
                commit: commit, downloadEndpoint: URL(string: "https://mirror.invalid")!,
                files: data.map { .init(remotePath: $0.key, sizeBytes: Int64($0.value.count), digest: .gitBlobSHA1(String(repeating: "c", count: 40))) }
                    + weights.map { .init(remotePath: $0, sizeBytes: 100, digest: .sha256(String(repeating: "d", count: 64))) } + additional,
                licenseURL: nil, resolutionContextID: UUID())
        }
    }
    static func planner(_ fixtures: [Fixture], limit: HFMetadataLimits = .init(), initialBytes: Int = 0,
                        credential: String? = nil) -> ASRInstallPlanner {
        ASRInstallPlanner(readMetadata: { file, repo in
            guard let fixture = fixtures.first(where: { $0.repository.resolutionContextID == repo.resolutionContextID }),
                  fixture.repository.commit == repo.commit, let data = fixture.data[file.remotePath] else {
                throw HFRepositoryError.fileNotInRepository
            }
            return data
        }, metadataContext: { repo in
            guard fixtures.contains(where: { $0.repository.resolutionContextID == repo.resolutionContextID }) else { throw HFRepositoryError.invalidMetadata }
            return .init(credentialID: credential, receivedBytes: initialBytes)
        }, metadataLimits: limit)
    }
    static var qwenData: [String: Data] { ["config.json": qwenConfig, "vocab.json": json(["a": 0]), "merges.txt": Data("#version: 0.2\n".utf8), "tokenizer_config.json": json(["tokenizer_class": "Qwen2Tokenizer"])] }
    static func graphs(_ prefix: String) -> [String: Data] {
        var data: [String: Data] = [:]
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            data[prefix + name + ".mlmodelc/coremldata.bin"] = Data([1])
            data[prefix + name + ".mlmodelc/model.mil"] = Data("func main() {}".utf8)
            data[prefix + name + ".mlmodelc/weights/weight.bin"] = Data([1])
        }
        return data
    }
    static var tokenizerData: [String: Data] { ["tokenizer.json": json(["model": ["vocab": ["a": 0]]]), "tokenizer_config.json": json(["tokenizer_class": "WhisperTokenizer"])] }
    static func run(_ r: SelfTest.Reporter) async {
        await testMinimalModelFileClosure(r)
        await testWhisperTokenizerRecipe(r)
        await testVariantAndBudgetRejections(r)
        await testNativeEngineRegistration(r)
        await testPlannerBoundaries(r)
        await testNormalizedPathCollisions(r)
        await testResolverContextIntegration(r)
    }
    // Break caught: downloading a whole repository or ignoring an index shard dependency.
    static func testMinimalModelFileClosure(_ r: SelfTest.Reporter) async {
        for sharded in [false, true] {
            var data = qwenData
            if sharded { data["model.safetensors.index.json"] = json(["weight_map": ["a": "one.safetensors", "b": "two.safetensors"]]) }
            let weights = sharded ? ["one.safetensors", "two.safetensors", "unused.safetensors"] : ["model.safetensors", "unused.safetensors"]
            data["README.md"] = Data("not needed".utf8)
            let f = Fixture(data: data, weights: weights)
            do {
                let p = try await planner([f], credential: "asr.hf.official").plan(repository: f.repository, variant: nil, tokenizer: nil)
                let expected = sharded ? ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json", "model.safetensors.index.json", "one.safetensors", "two.safetensors"] : ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json", "model.safetensors"]
                r.eq(Set(p.files.map(\.relativeDestination)), Set(expected), "B2 exact Qwen file closure")
                r.eq(p.engine, .qwenMLX, "B2 Qwen engine")
                r.eq(p.totalBytes, p.files.reduce(0) { $0 + $1.sizeBytes }, "B2 exact byte sum")
                r.eq(p.credentialID, "asr.hf.official", "B2 original resolver credential captured")
                r.eq(try JSONDecoder().decode(ASRInstallPlan.self, from: JSONEncoder().encode(p)), p, "B2 plan schema roundtrips")
            } catch { r.check(false, "B2 Qwen plan failed: \(error)") }
        }
        var data = qwenData
        data["model.safetensors.index.json"] = json(["weight_map": ["a": "missing.safetensors"]])
        let f = Fixture(data: data, weights: ["model.safetensors"])
        await rejects(r, f, expected: .incompleteModel, "B2 missing indexed shard rejected")
    }
    // Break caught: tokenizer omitted, mismatched known tokenizer, or unselected graphs included.
    static func testWhisperTokenizerRecipe(_ r: SelfTest.Reporter) async {
        let f = Fixture(data: graphs("openai_whisper-tiny/").merging(graphs("openai_whisper-large/")) { a, _ in a })
        let t = Fixture(repoID: "openai/whisper-tiny", commit: tokenizerCommit, data: tokenizerData)
        do {
            let p = try await planner([f,t]).plan(repository: f.repository, variant: "openai_whisper-tiny", tokenizer: t.repository)
            r.eq(p.engine, .whisperCoreML, "B2 Whisper engine")
            r.eq(Set(p.files.map(\.resolvedCommit)), Set([commit, tokenizerCommit]), "B2 both sources pinned")
            r.check(p.files.allSatisfy { !$0.remotePath.contains("openai_whisper-large") }, "B2 only selected variant")
            r.eq(p.files.count, 11, "B2 complete selected graph packages plus tokenizer")
            r.eq(Set(p.files.map(\.relativeDestination)).count, p.files.count, "B2 no destination collisions")
            r.check(p.files.contains { $0.relativeDestination == "tokenizer/tokenizer.json" }, "B2 tokenizer installed at offline path")
        } catch { r.check(false, "B2 Whisper plan failed: \(error)") }
        await rejects(r, f, expected: .variantRequired, "B2 root multiple variants need selection", tokenizer: t)
        await rejects(r, f, expected: .tokenizerRequired, "B2 absent tokenizer needs explicit source", variant: "openai_whisper-tiny")
        let wrong = Fixture(repoID: "openai/whisper-base", data: tokenizerData)
        await rejects(r, f, expected: .tokenizerMismatch, "B2 known wrong tokenizer rejected", variant: "openai_whisper-tiny", tokenizer: wrong)
        let unknown = Fixture(data: graphs("custom/"))
        await rejects(r, unknown, expected: .tokenizerRequired, "B2 unknown model never borrows tiny tokenizer", variant: "custom")
        let embedded = Fixture(data: graphs("").merging(tokenizerData) { a, _ in a })
        do {
            let p = try await planner([embedded]).plan(repository: embedded.repository, variant: nil, tokenizer: nil)
            r.eq(p.files.count, 11, "B2 embedded tokenizer used offline")
        } catch { r.check(false, "B2 embedded tokenizer failed: \(error)") }
    }
    static func rejects(_ r: SelfTest.Reporter, _ f: Fixture, expected: ASRInstallPlanningError, _ message: String,
                        variant: String? = nil, tokenizer: Fixture? = nil, limit: HFMetadataLimits = .init(), initialBytes: Int = 0) async {
        do { _ = try await planner([f] + (tokenizer.map { [$0] } ?? []), limit: limit, initialBytes: initialBytes).plan(repository: f.repository, variant: variant, tokenizer: tokenizer?.repository); r.check(false, message) }
        catch { r.eq(error as? ASRInstallPlanningError, expected, message) }
    }
    // Break caught: unchecked metadata budgets/path traversal and accepting unsupported architecture.
    static func testVariantAndBudgetRejections(_ r: SelfTest.Reporter) async {
        for config in [json(["model_type": "whisper"]), json(["model_type": "llama"])] {
            let f = Fixture(data: ["config.json": config], weights: ["pytorch_model.bin", "model.gguf"])
            await rejects(r, f, expected: .unsupportedArchitecture, "B2 unsupported architecture directed to service")
        }
        var bad = try! JSONSerialization.jsonObject(with: qwenConfig) as! [String: Any]
        bad["quantization"] = ["bits": 3, "group_size": 64]
        let incompatible = Fixture(data: ["config.json": json(bad)], weights: ["model.safetensors"])
        r.check((try? NativeASRFormatSupport.assessMetadata(config: json(bad), paths: ["model.safetensors"])) == nil, "B2 incompatible MLX rejected")
        await rejects(r, incompatible, expected: .unsupportedArchitecture, "B2 incompatible MLX plan rejected")
        let absolute = Fixture(data: qwenData, weights: ["/model.safetensors"])
        await rejects(r, absolute, expected: .invalidPath, "B2 absolute remote path rejected")
        let collision = Fixture(data: qwenData, weights: ["model.safetensors", "model.safetensors"])
        await rejects(r, collision, expected: .destinationCollision, "B2 duplicate destinations rejected")
        let f = Fixture(data: qwenData, weights: ["model.safetensors"])
        await rejects(r, f, expected: .metadataBudget, "B2 per-file metadata limit enforced", limit: .init(responseBytes: 10))
        let model = Fixture(data: graphs(""))
        let t = Fixture(repoID: "custom/tokenizer", data: tokenizerData)
        await rejects(r, model, expected: .metadataBudget, "B2 aggregate model/tokenizer budgets enforced", tokenizer: t, limit: .init(preflightBytes: 100), initialBytes: 60)
        var malicious = qwenData
        malicious["model.safetensors.index.json"] = json(["weight_map": ["a": "../outside.safetensors"]])
        await rejects(r, Fixture(data: malicious), expected: .invalidPath, "B2 index traversal rejected")
    }
    static func testPlannerBoundaries(_ r: SelfTest.Reporter) async {
        var shardData = qwenData
        shardData["weights.safetensors.index.json"] = json(["weight_map": ["a": "one.safetensors", "b": "two.safetensors"]])
        let indexed = Fixture(data: shardData, weights: ["one.safetensors", "two.safetensors"])
        do {
            let p = try await planner([indexed]).plan(repository: indexed.repository, variant: nil, tokenizer: nil)
            r.check(p.files.contains { $0.relativeDestination == "weights.safetensors.index.json" }, "B2 loader-supported alternate index retained")
            r.eq(p.files.count, 7, "B2 alternate index exact shard closure")
        } catch { r.check(false, "B2 alternate index failed: \(error)") }
        shardData["weights.safetensors.index.json"] = json(["weight_map": ["a": "nested/one.safetensors"]])
        await rejects(r, Fixture(data: shardData, weights: ["nested/one.safetensors"]), expected: .invalidPath, "B2 index cannot broaden loader direct-child layout")
        let prefixed = Fixture(prefix: "nested/model", data: Dictionary(uniqueKeysWithValues: qwenData.map { ("nested/model/" + $0.key, $0.value) }), weights: ["nested/model/model.safetensors"])
        do {
            let p = try await planner([prefixed]).plan(repository: prefixed.repository, variant: nil, tokenizer: nil)
            r.eq(Set(p.files.map(\.relativeDestination)), Set(["config.json", "vocab.json", "merges.txt", "tokenizer_config.json", "model.safetensors"]), "B2 selected model directory maps exactly to installation root")
            r.check(p.files.allSatisfy { $0.remotePath.hasPrefix("nested/model/") }, "B2 original source paths preserved")
        } catch { r.check(false, "B2 selected directory failed: \(error)") }
        var packageData: [String: Data] = tokenizerData
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder", "TextDecoderContextPrefill"] {
            packageData[name + ".mlpackage/Manifest.json"] = json(["rootModelIdentifier": "root", "itemInfoEntries": ["root": ["path": "custom/model.mlmodel"], "weights": ["path": "custom/weights"]]])
            packageData[name + ".mlpackage/Data/custom/model.mlmodel"] = Data([1])
            packageData[name + ".mlpackage/Data/custom/weights/weight.bin"] = Data([1])
        }
        let packages = Fixture(data: packageData)
        do {
            let p = try await planner([packages]).plan(repository: packages.repository, variant: nil, tokenizer: nil)
            r.eq(p.files.count, 14, "B2 selected mlpackages include all resources and optional prefill")
        } catch { r.check(false, "B2 mlpackage plan failed: \(error)") }
        packageData.removeValue(forKey: "AudioEncoder.mlpackage/Data/custom/weights/weight.bin")
        await rejects(r, Fixture(data: packageData), expected: .incompleteModel, "B2 missing package resource rejected")
        var mil = graphs("").merging(tokenizerData) { a, _ in a }
        mil["AudioEncoder.mlmodelc/model.mil"] = Data("@model_path/weights/missing.bin".utf8)
        await rejects(r, Fixture(data: mil), expected: .incompleteModel, "B2 missing MIL graph dependency rejected")
        let model = Fixture(data: graphs(""))
        let tokens = Fixture(repoID: "custom/tokenizer", data: tokenizerData)
        await rejects(r, model, expected: .metadataBudget, "B2 file reads across sources share one budget", tokenizer: tokens, limit: .init(preflightBytes: 64))
        let oversized = Fixture(data: [:], additional: [.init(remotePath: "config.json", sizeBytes: Int64(16 * 1024 * 1024 + 1), digest: .gitBlobSHA1(String(repeating: "c", count: 40)))])
        await rejects(r, oversized, expected: .metadataBudget, "B2 production 16MiB per-file cap preempts read")
        let overflow = Fixture(data: qwenData, additional: [.init(remotePath: "model.safetensors", sizeBytes: Int64.max, digest: .sha256(String(repeating: "d", count: 64)))])
        await rejects(r, overflow, expected: .totalSizeOverflow, "B2 planned byte sum overflow rejected")
        let q = Fixture(data: qwenData, weights: ["model.safetensors"])
        do { _ = try await planner([q]).plan(repository: q.repository, variant: nil, tokenizer: nil, credentialID: "asr.hf.official"); r.check(false, "B2 explicit credential must match source context") }
        catch { r.eq(error as? ASRInstallPlanningError, .invalidCredential, "B2 explicit credential mismatch rejected") }
        for recipe in ASRModelRecipes.all {
            r.check(recipe.sources.allSatisfy { $0.requestedRevision.count == 40 && $0.requestedRevision.allSatisfy { $0.isHexDigit } }, "B2 recipe sources pinned before resolution")
            r.check(!recipe.verified, "B2 metadata candidates never claim native verification")
        }
        r.eq(ModelPreset.qwen306B.installationRecipe?.sources.first?.repoID, "aufklarer/Qwen3-ASR-0.6B-MLX-4bit", "B2 old preset links to pinned installation recipe")
        for recipe in ASRModelRecipes.all {
            let data = recipe.variant.map { graphs($0 + "/") } ?? qwenData
            let f = Fixture(repoID: recipe.sources[0].repoID, commit: recipe.sources[0].requestedRevision, data: data,
                            weights: recipe.engine == .qwenMLX ? ["model.safetensors"] : [])
            let t: Fixture? = recipe.sources.count > 1 ? Fixture(repoID: recipe.sources[1].repoID, commit: recipe.sources[1].requestedRevision, data: tokenizerData) : nil
            do {
                let p = try await planner([f] + (t.map { [$0] } ?? [])).plan(repository: f.repository, variant: recipe.variant, tokenizer: t?.repository)
                r.eq(p.recipeID, recipe.id, "B2 exact source commits stamp recipe identity")
                r.eq(p.recipeVersion, 1, "B2 recipe version captured")
                r.check(p.files.allSatisfy { $0.downloadEndpoint == URL(string: "https://mirror.invalid")! }, "B2 all source endpoints captured")
            } catch { r.check(false, "B2 pinned candidate recipe failed: \(error)") }
        }
    }

    // Break caught: a normalized file name is also an ancestor directory of another file.
    static func testNormalizedPathCollisions(_ r: SelfTest.Reporter) async {
        let pairs = [
            ["AudioEncoder.mlmodelc/weights", "AudioEncoder.mlmodelc/Weights/weight.bin"],
            ["AudioEncoder.mlmodelc/Café", "AudioEncoder.mlmodelc/Cafe\u{301}/weight.bin"],
            ["AudioEncoder.mlmodelc/straße", "AudioEncoder.mlmodelc/STRASSE/weight.bin"],
            ["AudioEncoder.mlmodelc/Café.bin", "AudioEncoder.mlmodelc/Cafe\u{301}.BIN"],
            ["AudioEncoder.mlmodelc/weights/one.bin", "AudioEncoder.mlmodelc/Weights/two.bin"],
            ["AudioEncoder.mlmodelc/resources/deep/one.bin", "AudioEncoder.mlmodelc/Resources/other/two.bin"],
            ["AudioEncoder.mlmodelc/resources/deep/one.bin", "AudioEncoder.mlmodelc/resources/Deep/two.bin"],
            ["AudioEncoder.mlmodelc/straße/one.bin", "AudioEncoder.mlmodelc/STRASSE/two.bin"],
            ["AudioEncoder.mlmodelc/Café/one.bin", "AudioEncoder.mlmodelc/CAFE\u{301}/two.bin"]
        ]
        for pair in pairs {
            for paths in [pair, Array(pair.reversed())] {
                let fixture = Fixture(data: graphs("").merging(tokenizerData) { a, _ in a }, weights: paths)
                await rejects(r, fixture, expected: .destinationCollision, "B2 normalized source file/directory collision rejected in either order")
            }
        }
        // These two manifests are individually safe, but their mapped installation paths collide.
        let model = Fixture(data: graphs(""))
        let tokens = Fixture(repoID: "custom/tokenizer", data: tokenizerData)
        for paths in [["Tokenizer", "tokenizer/tokenizer.json"], ["TOKENIZER/TOKENIZER.JSON", "tokenizer/tokenizer.json"],
                      ["Tokenizer/extra.json", "tokenizer/tokenizer.json"],
                      ["tokenizer/Assets/one.bin", "tokenizer/assets/two.bin"]] {
            let mapped = [HFPlannedFile(source: model.repository.selection, downloadEndpoint: model.repository.downloadEndpoint,
                resolvedCommit: commit, remotePath: "model-resource", relativeDestination: paths[0], sizeBytes: 1,
                digest: .sha256(String(repeating: "d", count: 64))),
                HFPlannedFile(source: tokens.repository.selection, downloadEndpoint: tokens.repository.downloadEndpoint,
                resolvedCommit: tokenizerCommit, remotePath: "tokenizer.json", relativeDestination: paths[1], sizeBytes: 1,
                digest: .sha256(String(repeating: "d", count: 64)))]
            for files in [mapped, Array(mapped.reversed())] {
                do { try ASRInstallPlanner.validateFilePaths(files.map(\.relativeDestination)); r.check(false, "B2 mapped paths across sources cannot collide") }
                catch { r.eq(error as? ASRInstallPlanningError, .destinationCollision, "B2 complete mapped file set rejects cross-source collisions") }
            }
        }
        let siblings = ["AudioEncoder.mlmodelc/weights/one.bin", "AudioEncoder.mlmodelc/weights/two.bin",
                        "AudioEncoder.mlmodelc/weights-extra", "AudioEncoder.mlmodelc/Café/a.bin", "AudioEncoder.mlmodelc/Cafe\u{301}/b.bin"]
        let fixture = Fixture(data: graphs(""), weights: siblings)
        do {
            let p = try await planner([fixture, tokens]).plan(repository: fixture.repository, variant: nil, tokenizer: tokens.repository)
            r.eq(p.files.count, 16, "B2 exact and canonically equivalent directory siblings remain installable")
            r.check(p.files.contains { $0.relativeDestination == "tokenizer/tokenizer.json" }, "B2 noncolliding second-source tokenizer mapping retained")
        } catch { r.check(false, "B2 noncolliding normalized siblings failed: \(error)") }
    }

    // Exercises the real resolver/client path, including context provenance and cumulative initial bytes.
    static func testResolverContextIntegration(_ r: SelfTest.Reporter) async {
        let f = Fixture(data: qwenData, weights: ["model.safetensors"])
        let session = HFRepositorySelfTests.session(); defer { session.invalidateAndCancel() }
        let store = KeychainASRCredentialStore(access: .memory())
        try? store.write("synthetic-B2-token", id: "asr.hf.official")
        HFMetadataFixture.reset { request, _ in
            let path = request.url!.path
            if path.contains("/revision/") { return .init(body: json(["sha": commit])) }
            if path.contains("/tree/") {
                let entries: [[String: Any]] = f.repository.files.map { file in
                    if let data = f.data[file.remotePath] {
                        var payload = Data("blob \(data.count)\0".utf8); payload.append(data)
                        let oid = Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                        return ["type": "file", "path": file.remotePath, "size": data.count, "oid": oid]
                    }
                    return HFRepositorySelfTests.entry(file.remotePath, size: file.sizeBytes, lfs: true)
                }
                return .init(body: json(entries))
            }
            let name = path.components(separatedBy: "/resolve/" + commit + "/").last!
            guard let data = f.data[name] else { return .init(status: 404, body: Data()) }
            return .init(body: data)
        }
        do {
            let client = HFRepositoryClient(session: session, credentialStore: store)
            let repo = try await client.resolve(f.repository.selection, credentialID: "asr.hf.official")
            let context = try await client.preflightContext(for: repo)
            r.eq(context.credentialID, "asr.hf.official", "B2 client context exposes captured credential ID only")
            r.check(context.receivedBytes > 0, "B2 initial resolver metadata counted")
            let p = try await ASRInstallPlanner(client: client).plan(repository: repo, variant: nil, tokenizer: nil)
            r.eq(p.files.count, 5, "B2 real resolver result retained through planner metadata reads")
            r.eq(p.credentialID, "asr.hf.official", "B2 plan infers original auth reference")
            r.check(HFMetadataFixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-B2-token" }, "B2 metadata retains original resolver authorization")
            r.check(!HFMetadataFixture.requests.contains { $0.url!.path.hasSuffix("model.safetensors") }, "B2 planner never reads weight payload")
            let changed = HFResolvedRepository(selection: repo.selection, commit: repo.commit, downloadEndpoint: repo.downloadEndpoint, files: [], licenseURL: nil, resolutionContextID: repo.resolutionContextID)
            do { _ = try await client.preflightContext(for: changed); r.check(false, "B2 altered resolver context rejected") }
            catch { r.eq(error as? HFRepositoryError, .fileNotInRepository, "B2 context validates full immutable source") }
            let fresh = try await client.resolve(f.repository.selection)
            do { _ = try await ASRInstallPlanner(client: client, metadataLimits: .init(preflightBytes: 10)).plan(repository: fresh, variant: nil, tokenizer: nil); r.check(false, "B2 initial metadata alone can exhaust budget") }
            catch { r.eq(error as? ASRInstallPlanningError, .metadataBudget, "B2 resolver initial bytes included in planner budget") }
        } catch { r.check(false, "B2 resolver integration failed: \(error)") }
    }
    struct Provider: ASRProvider {
        let id = "B2-provider", displayName = "B2 provider"
        let capabilities = ASRCapabilities(supportsLanguageHint: false, supportsContextHint: false, requiresNetwork: false, location: .onDevice)
        var isAvailable: Bool { get async { true } }
        func transcribe(_ request: ASRRequest) async throws -> ASRResult { .init(text: "fixture", providerID: id, latencyMs: 0) }
    }
    struct Adapter: LocalASREngineAdapter {
        let engine: LocalASREngine
        let model: ImportedASRModel
        let lease: LocalASRLease
        func assessMetadata(config: Data?, paths: [String]) throws -> Bool { true }
        func inspect(directory: URL) throws -> ImportedASRModel { model }
        func load(model: ImportedASRModel) async throws -> LocalASRLease { lease }
    }
    // Break caught: ordered dispatch, duplicate engines, and factory bypassing injected adapter/reinspection.
    static func testNativeEngineRegistration(_ r: SelfTest.Reporter) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flowtype-B2-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model: ImportedASRModel
        do {
            for (path, data) in graphs("").merging(tokenizerData, uniquingKeysWith: { a, _ in a }) {
                let file = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
            }
            model = try ASRModelInspector.inspect(directory: dir)
        } catch { r.check(false, "B2 isolated native inspection fixture failed: \(error)"); return }
        let lease = LocalASRLease(id: UUID(), identity: .init(id: "B2", displayName: "B2", engine: "qwenMLX", repoID: nil, directory: dir), provider: Provider())
        let a = Adapter(engine: .whisperCoreML, model: model, lease: lease)
        r.check((try? LocalASRRuntimeRegistry(adapters: [a,a])) == nil, "B2 duplicate engine registration rejected")
        do {
            let registry = try LocalASRRuntimeRegistry(adapters: [a, Adapter(engine: .qwenMLX, model: model, lease: lease)])
            do { _ = try registry.engine(config: nil, paths: []); r.check(false, "B2 ambiguous metadata rejected") }
            catch { r.eq(error as? ASRInstallPlanningError, .ambiguousEngine, "B2 ambiguity never uses adapter order") }
            let single = try LocalASRRuntimeRegistry(adapters: [a])
            r.eq(try await LocalASRRuntimeFactory.load(model, registry: single), lease, "B2 factory invokes injected adapter after recheck")
            var changed = model; changed.fileFingerprint = "B"
            do { _ = try await LocalASRRuntimeFactory.load(changed, registry: single); r.check(false, "B2 stale model cannot reach adapter") }
            catch { r.eq((error as? ASRModelInspectionError)?.code, .changedDuringInspection, "B2 unified factory recheck retained") }
            try json(["tokenizer_class": "WhisperTokenizer", "changed": true]).write(to: dir.appendingPathComponent("tokenizer_config.json"))
            do { _ = try await LocalASRRuntimeFactory.load(model, registry: single); r.check(false, "B2 injected adapter cannot bypass real file recheck") }
            catch { r.eq((error as? ASRModelInspectionError)?.code, .changedDuringInspection, "B2 changed on-disk files block injected runtime") }
        } catch { r.check(false, "B2 registry/factory failed: \(error)") }
        r.check((try? NativeASRFormatSupport.assessMetadata(config: nil, paths: ["model.gguf"])) == nil, "B2 unknown metadata rejected")
        r.eq(try? NativeASRFormatSupport.assessMetadata(config: qwenConfig, paths: ["model.safetensors"]), .qwenMLX, "B2 shared exact Qwen metadata assessment")
    }
}
