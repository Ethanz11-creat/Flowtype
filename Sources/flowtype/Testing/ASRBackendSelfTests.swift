import Foundation

enum ASRBackendSelfTests {
    static func run(_ r: SelfTest.Reporter) async {
        await ASRBackendTransportSelfTests.run(r)
        await ASRBackendValidationSelfTests.run(r)
        await ASRBackendRoutingSelfTests.run(r)
        await ASRSettingsActionSelfTests.run(r)
        testLegacySelectionAndStableIdentity(r)
        testValidationSampleContract(r)
        testBindingIdentity(r)
        await ASRCredentialSelfTests.run(r)
        await ProviderDraftSelfTests.run(r)
        await ProviderDraftCheckSelfTests.run(r)
        await SettingsChangeSelfTests.run(r)
        await CloudProviderSelfTests.runConnectionOwnership(r)
    }

    // Catches policy inversion, default replacement of custom profiles, and identity tied to rows/names.
    static func testLegacySelectionAndStableIdentity(_ r: SelfTest.Reporter) {
        do {
            let profileID = "11111111-2222-3333-4444-555555555555"
            let importedID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            for policy in ["auto", "localOnly", "cloudOnly"] {
                let json = """
                {"asrRoutingPolicy":"\(policy)","selectedLocalModelID":"missing-preset",
                 "cloudASRConfig":{"providers":[
                   {"id":"99999999-2222-3333-4444-555555555555","name":"Disabled","provider":"Custom","baseURL":"https://disabled.example/v1","model":"old","isActive":false},
                   {"id":"\(profileID)","name":"Custom","provider":"Custom","baseURL":"https://custom.example/asr/v1","model":"","isActive":true}],
                   "providerAPIKeys":{"orphan":"fixture-only"}}}
                """
                let config = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
                r.eq(config.asrBackendSelection, nil, "legacy selection remains marked unmigrated")
                r.eq(config.localASRServices, [], "legacy services default empty")
                let selection = ASRBackendMigration.selection(from: config)
                r.eq(selection.primary?.rawValue, policy == "localOnly" ? "native:preset:missing-preset" : "cloud:" + profileID,
                     "\(policy): preserves selected reference even without model files")
                r.eq(selection.fallback?.rawValue, policy == "auto" ? "native:preset:missing-preset" : nil,
                     "\(policy): only auto retains native fallback")
                r.eq(selection.allowsCloudFallback, policy == "auto", "\(policy): legacy fallback consent")
                r.eq(config.cloudASRConfig.providers[1].baseURL, "https://custom.example/asr/v1", "custom URL retained")
                r.eq(config.cloudASRConfig.providers[1].model, "", "empty model retained")
                r.eq(config.cloudASRConfig.providers.map(\.isActive), [false, true], "disabled flags retained")
                r.eq(config.cloudASRConfig.providerAPIKeys["orphan"], "fixture-only", "orphan key not discarded")
                let back = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
                r.eq(back.cloudASRConfig, config.cloudASRConfig, "generated legacy revisions persist on round-trip")
                var reordered = config
                reordered.cloudASRConfig.providers.reverse()
                reordered.cloudASRConfig.providers[0].name = "Renamed"
                r.eq(ASRBackendMigration.selection(from: reordered), selection, "rename/reorder does not change stable IDs")
                var imported = config
                imported.asrRoutingPolicy = .localOnly
                imported.activeImportedASRModelID = UUID(uuidString: importedID)!
                r.eq(ASRBackendMigration.selection(from: imported).primary?.rawValue, "native:import:" + importedID,
                     "missing import reference survives without consulting disk")
            }
            var unresolved = Configuration()
            unresolved.asrRoutingPolicy = .localOnly
            r.eq(ASRBackendMigration.selection(from: unresolved).primary, nil, "automatic native intent never invents a preset")
            unresolved.customLocalModelPath = "/nonexistent/custom-model"
            r.eq(ASRBackendMigration.selection(from: unresolved).primary, nil, "legacy path-only intent waits for resolved lease")
            r.eq(unresolved.customLocalModelPath, "/nonexistent/custom-model", "pure migration preserves unresolved path")
            var disabled = Configuration()
            disabled.asrRoutingPolicy = .cloudOnly
            disabled.cloudASRConfig.providers = [.defaultSiliconFlow(isActive: false)]
            r.eq(ASRBackendMigration.selection(from: disabled).primary?.rawValue,
                 "cloud:" + disabled.cloudASRConfig.providers[0].id.uuidString, "legacy first-disabled fallback reference retained")
            var fresh = Configuration()
            fresh.asrBackendSelection = .init(primary: .init(rawValue: "native:preset:new"), fallback: nil, allowsCloudFallback: false)
            r.eq(ASRBackendMigration.selection(from: fresh), fresh.asrBackendSelection, "explicit new native choice keeps cloud fallback off")
            let service = LocalASRServiceProfile(id: UUID(), revision: UUID(), name: "Local",
                baseURL: "http://127.0.0.1:8000/v1", protocolKind: .openAICompatible,
                modelID: nil, authentication: .bearer(credentialID: "fixture-key-id"), fieldCapabilities: .init())
            fresh.localASRServices = [service]
            fresh.asrBackendSelection = .init(primary: .init(rawValue: "service:" + service.id.uuidString), fallback: nil, allowsCloudFallback: false)
            let back = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(fresh))
            r.eq(back.localASRServices, [service], "service profile persists protocol, capabilities and credential reference")
            r.eq(ASRBackendMigration.selection(from: back), fresh.asrBackendSelection, "explicit service selection overrides old policy")
        } catch { r.check(false, "backend migration fixture: \(error)") }
    }

    // Catches accepted empty/wrong-rate samples and unstable/incorrect Float32 fingerprints.
    static func testValidationSampleContract(_ r: SelfTest.Reporter) {
        do {
            let sample = try ASRValidationSample(samples: [0], sampleRate: 16_000, label: "synthetic silence")
            r.eq(sample.samples, [0], "sample preserves PCM")
            r.eq(sample.sampleRate, 16_000, "sample preserves rate")
            r.eq(sample.label, "synthetic silence", "sample preserves label")
            r.eq(sample.sha256, "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119", "hash is canonical little-endian Float32 PCM")
            let pcm: [Float] = [1, -0.5]
            // Hand-checked bytes: 00 00 80 3f 00 00 00 bf (little-endian Float32).
            let digest = "e5e0ce39fac89cd93af5ba8bcad2fe35d88c75417c7e44941fe5ee4e48f1cf75"
            let computed = try ASRValidationSample(samples: pcm, sampleRate: 16_000, label: "nonzero PCM")
            let supplied = try ASRValidationSample(samples: pcm, sampleRate: 16_000, sha256: digest, label: "verified PCM")
            r.eq(computed.sha256, digest, "nonzero PCM fingerprint uses canonical byte ordering")
            r.eq(supplied.sha256, computed.sha256, "both initializers give identical PCM the same identity")
            r.check((try? ASRValidationSample(samples: pcm, sampleRate: 16_000, sha256: String(repeating: "0", count: 64), label: "incorrect")) == nil,
                    "incorrect 64-digit PCM fingerprint rejected")
            r.check((try? ASRValidationSample(samples: pcm, sampleRate: 16_000, sha256: "trusted-resource-hash", label: "malformed")) == nil,
                    "malformed resource fingerprint rejected")
            r.check((try? ASRValidationSample(samples: pcm, sampleRate: 16_000, sha256: String(repeating: "g", count: 64), label: "nonhex")) == nil,
                    "nonhex 64-character fingerprint rejected")
            r.check((try? ASRValidationSample(samples: [], sampleRate: 16_000, sha256: digest, label: "empty explicit")) == nil,
                    "explicit initializer rejects empty PCM")
            r.check((try? ASRValidationSample(samples: pcm, sampleRate: 48_000, sha256: digest, label: "wrong explicit rate")) == nil,
                    "explicit initializer rejects non-16kHz PCM")
            r.check((try? ASRValidationSample(samples: [], sampleRate: 16_000, label: "empty")) == nil, "empty sample rejected")
            r.check((try? ASRValidationSample(samples: [0], sampleRate: 48_000, label: "wrong rate")) == nil, "non-16kHz sample rejected")
        } catch { r.check(false, "validation sample fixture: \(error)") }
    }

    // Catches provider-object equality, dropped native leases and revision/generation conflation.
    static func testBindingIdentity(_ r: SelfTest.Reporter) {
        let first = Provider(id: "first")
        let second = Provider(id: "second")
        let lease = LocalASRLease(id: UUID(), identity: .init(id: "fixture", displayName: "Fixture", engine: "fixture",
            repoID: nil, directory: URL(fileURLWithPath: "/nonexistent/asr-fixture")), provider: first)
        let descriptor = ASRBackendDescriptor(nativeLease: lease, id: .init(rawValue: "native:preset:fixture"))
        r.eq(descriptor.revision, lease.id, "native revision is retained lease identity")
        r.eq(descriptor.requiresInternet, false, "native descriptor requires no internet")
        let binding = ASRBackendBinding(descriptor: descriptor, provider: first, nativeLease: lease, credentialGeneration: nil)
        r.eq(binding.nativeLease?.id, lease.id, "binding retains native lease")
        r.eq(binding, ASRBackendBinding(descriptor: descriptor, provider: second, nativeLease: lease, credentialGeneration: nil), "binding equality ignores provider object")
        r.check(binding != ASRBackendBinding(descriptor: descriptor, provider: first, nativeLease: nil, credentialGeneration: nil), "binding equality includes lease")
        r.check(binding != ASRBackendBinding(descriptor: descriptor, provider: first, nativeLease: lease, credentialGeneration: UUID()), "binding equality includes credential generation")
        let service = ASRBackendDescriptor(id: .init(rawValue: "service:fixture"), revision: UUID(), displayName: "Service", modelID: nil,
            location: .loopbackService, requiresInternet: false,
            capabilities: .init(supportsLanguageHint: false, supportsContextHint: false, requiresNetwork: true, location: .localService), maxUploadBytes: nil)
        r.check(service.capabilities.requiresNetwork && !service.requiresInternet, "loopback socket use independent from internet")
    }

    private struct Provider: ASRProvider {
        let id: String
        let displayName = "Fixture"
        let capabilities = ASRCapabilities(supportsLanguageHint: false, supportsContextHint: false, requiresNetwork: false, location: .onDevice)
        var isAvailable: Bool { get async { true } }
        func transcribe(_ request: ASRRequest) async throws -> ASRResult { throw SpeechProviderError.notAvailable }
    }
}
