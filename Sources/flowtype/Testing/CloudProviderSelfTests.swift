import Foundation

/// Pure configuration fixtures: no configuration store, credentials, or transport.
enum CloudProviderSelfTests {
    static func runConfiguration(_ r: SelfTest.Reporter) {
        let sf = CloudASRVendor.makeProfile(.siliconFlow, isActive: true)
        let openai = CloudASRVendor.makeProfile(.openAI, isActive: false)
        let realtime = CloudASRVendor.makeProfile(.dashScope, isActive: false)
        let custom = CloudASRVendor.makeProfile(.custom, isActive: false)
        r.eq(sf.model, "FunAudioLLM/SenseVoiceSmall", "vendor: default ASR model is ready")
        r.eq(sf.baseURL, "https://api.siliconflow.cn/v1", "vendor: preserves SiliconFlow region")
        r.eq(sf.vendorID, .siliconFlow, "vendor: stable SiliconFlow identity")
        r.check(sf.isActive && !openai.isActive, "vendor: creation honors active selection")
        r.eq(openai.model, "whisper-1", "vendor: OpenAI default visible")
        r.eq(openai.baseURL, "https://api.openai.com/v1", "vendor: OpenAI base URL")
        r.eq(realtime.baseURL, "wss://dashscope.aliyuncs.com/api-ws/v1/inference", "vendor: existing WSS URL")
        r.eq(realtime.model, "paraformer-realtime-v2", "vendor: existing realtime model")
        r.eq(realtime.protocolKind, .dashScopeRealtime, "vendor: WSS transport explicit")
        r.eq(custom.baseURL, "", "vendor: custom requires a user URL")
        r.eq(custom.model, "", "vendor: custom requires a user model")
        r.eq(custom.protocolKind, .openAICompatible, "vendor: custom uses HTTP adapter")
        r.eq(CloudASRProviderConfig.defaultSiliconFlow().model, "FunAudioLLM/SenseVoiceSmall", "vendor: legacy factory uses new creation default")

        let minimal = CloudASRFieldCapabilities()
        r.eq(CloudASRVendor.capabilities(for: sf), minimal, "capabilities: SiliconFlow only file/model")
        r.eq(CloudASRVendor.capabilities(for: realtime), minimal, "capabilities: WSS has no multipart fields")
        r.eq(CloudASRVendor.capabilities(for: custom), minimal, "capabilities: custom opt-in required")
        r.eq(CloudASRVendor.capabilities(for: openai), CloudASRFieldCapabilities(sendResponseFormat: true),
             "capabilities: OpenAI minimum verified contract excludes optional hints")
        var unknownModel = openai
        unknownModel.model = "unverified-model"
        r.eq(CloudASRVendor.capabilities(for: unknownModel), minimal, "capabilities: unknown models gain no implied optional fields")
        var optedIn = custom
        optedIn.customFieldCapabilities = CloudASRFieldCapabilities(sendLanguage: true, sendPrompt: true,
                                                                   sendTemperature: true, sendResponseFormat: true)
        r.eq(CloudASRVendor.capabilities(for: optedIn), optedIn.customFieldCapabilities, "capabilities: custom explicit opt-in honored")
        unknownModel.customFieldCapabilities = optedIn.customFieldCapabilities
        r.eq(CloudASRVendor.capabilities(for: unknownModel), minimal, "capabilities: custom flags do not override built-in restrictions")

        do {
            let oldNames: [(String, CloudASRVendorID)] = [
                ("SiliconFlow", .siliconFlow), ("OpenAI", .openAI), ("DashScope", .dashScope),
                ("Custom", .custom), ("siliconflow", .custom), ("My OpenAI", .custom), ("私人服务", .custom)
            ]
            var profiles: [[String: Any]] = []
            var keys: [String: String] = [:]
            for (index, entry) in oldNames.enumerated() {
                let id = UUID()
                // A known domain must never identify an unknown vendor.
                let url = "https://api.siliconflow.cn/legacy/\(index)"
                let model = index == 0 ? "" : "my-existing-model-\(index)"
                let legacy: [String: Any] = ["id": id.uuidString, "name": "saved-\(index)", "provider": entry.0,
                                           "baseURL": url, "model": model, "isActive": index == 2]
                profiles.append(legacy)
                keys[id.uuidString] = "synthetic-key-\(index)"
                let migrated = try JSONDecoder().decode(CloudASRProviderConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
                r.eq(migrated.id, id, "migration: profile identity retained \(index)")
                r.eq(migrated.name, "saved-\(index)", "migration: display name retained \(index)")
                r.eq(migrated.provider, entry.0, "migration: original provider retained \(index)")
                r.eq(migrated.vendorID, entry.1, "migration: exact old provider mapping \(index)")
                r.eq(migrated.baseURL, url, "migration: user URL retained \(index)")
                r.eq(migrated.model, model, "migration: existing model not overwritten \(index)")
                r.eq(migrated.isActive, index == 2, "migration: activation retained \(index)")
                r.eq(migrated.protocolKind, .openAICompatible, "migration: missing protocol remains HTTP \(index)")
                r.eq(migrated.customFieldCapabilities, minimal, "migration: no optional fields silently enabled \(index)")
            }
            // Preserve orphaned key associations as well as the current profiles' keys.
            keys[UUID().uuidString] = "synthetic-orphan-key"
            let oldConfig: [String: Any] = ["providers": profiles, "providerAPIKeys": keys]
            let migrated = try JSONDecoder().decode(CloudASRConfig.self, from: JSONSerialization.data(withJSONObject: oldConfig))
            r.eq(migrated.providerAPIKeys, keys, "migration: all old ASR key associations retained")
            let roundTrip = try JSONDecoder().decode(CloudASRConfig.self, from: JSONEncoder().encode(migrated))
            r.eq(roundTrip, migrated, "migration: migrated profile and keys round-trip")
            var explicit = optedIn
            explicit.provider = "OpenAI"
            explicit.baseURL = "https://api.openai.com/v1"
            let back = try JSONDecoder().decode(CloudASRProviderConfig.self, from: JSONEncoder().encode(explicit))
            r.eq(back.vendorID, .custom, "migration: encoded stable vendor wins over display name/domain")
            r.eq(back.customFieldCapabilities, optedIn.customFieldCapabilities, "migration: explicit custom flags persist")
        } catch {
            r.check(false, "vendor: in-memory migration fixtures decode: \(error)")
        }

        runEndpoints(r)
    }

    private static func runEndpoints(_ r: SelfTest.Reporter) {
        let validHTTP: [(String, String)] = [
            ("https://example.test/v1", "https://example.test/v1/audio/transcriptions"),
            ("https://example.test/v1///", "https://example.test/v1/audio/transcriptions"),
            ("https://example.test/v1/audio/transcriptions/", "https://example.test/v1/audio/transcriptions"),
            ("https://example.test/v1/audio/transcriptions", "https://example.test/v1/audio/transcriptions"),
            ("https://example.test/proxy%2Ftenant/v1", "https://example.test/proxy%2Ftenant/v1/audio/transcriptions"),
            ("https://example.test", "https://example.test/audio/transcriptions"),
            ("https://[::1]/v1", "https://[::1]/v1/audio/transcriptions"),
            ("https://[2001:db8::1]:8443/v1", "https://[2001:db8::1]:8443/v1/audio/transcriptions"),
            ("https://example.test:1/v1", "https://example.test:1/v1/audio/transcriptions"),
            ("https://example.test:65535/v1", "https://example.test:65535/v1/audio/transcriptions"),
            ("https://example.test:8443/proxy/v1", "https://example.test:8443/proxy/v1/audio/transcriptions")
        ]
        for (input, expected) in validHTTP {
            do {
                let result = try CloudASREndpoint.transcriptionURL(input)
                r.eq(result.absoluteString, expected, "endpoint: base/full URL normalized once")
                r.eq(try CloudASREndpoint.transcriptionURL(result.absoluteString), result, "endpoint: normalization idempotent")
            } catch { r.check(false, "endpoint: valid HTTPS input rejected") }
        }
        let invalidCommon = ["", "https:///v1", "https://", "https://user:pass@example.test/v1",
                             "https://@example.test/v1", "https://example.test/v1?key=synthetic",
                             "https://example.test/v1?", "https://example.test/v1#fragment", "https://example.test/v1#",
                             "https://example.test:0/v1", "https://example.test:65536/v1", "https://example.test:-1/v1",
                             "https://example.test:abc/v1", "https://example.test:/v1", "https://bad host/v1",
                             "https://example.test:9999999999999999999999/v1",
                             "https://[::1]:9999999999999999999999/v1", "https://[::1]:/v1",
                             "https://[::1]:0/v1", "https://[::1]:65536/v1",
                             "https://{workspace}/v1", "https://example.test/%7Bworkspace%7D"]
        for input in invalidCommon + ["http://example.test/v1", "wss://example.test/v1", "/v1"] {
            do {
                _ = try CloudASREndpoint.transcriptionURL(input)
                r.check(false, "endpoint: invalid HTTP input must throw")
            } catch { r.check(true, "endpoint: invalid HTTP input rejected") }
        }
        for input in invalidCommon.map({ $0.replacingOccurrences(of: "https:", with: "wss:") }) +
            ["ws://example.test/inference", "https://example.test/inference"] {
            do {
                _ = try CloudASREndpoint.validateRealtimeURL(input)
                r.check(false, "endpoint: invalid WSS input must throw")
            } catch { r.check(true, "endpoint: invalid WSS input rejected") }
        }
        let wss = "wss://example.test:8443/api-ws/v1/inference"
        r.eq(try? CloudASREndpoint.validateRealtimeURL(wss).absoluteString, wss, "endpoint: WSS keeps its own path")
        for valid in ["wss://[::1]/api-ws/v1/inference", "wss://[2001:db8::1]:8443/api-ws/v1/inference",
                      "wss://example.test:1/inference", "wss://example.test:65535/inference"] {
            r.eq(try? CloudASREndpoint.validateRealtimeURL(valid).absoluteString, valid, "endpoint: valid WSS host/port retained")
        }
    }
}
