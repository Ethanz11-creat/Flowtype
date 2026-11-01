import Foundation
import os

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

    /// Exercises the same actions as the settings UI with in-memory configuration and HTTP fixtures.
    @MainActor
    static func runConnectionOwnership(_ r: SelfTest.Reporter) async {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CloudTransportProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let client = CloudASRProvider(session: session, logger: { _ in })
        let checks = CloudASRConnectionCheck(service: client)
        var first = CloudASRVendor.makeProfile(.custom, isActive: true)
        first.baseURL = "https://ownership.invalid/v1"
        first.model = "original-model"
        let second = CloudASRVendor.makeProfile(.openAI, isActive: false)
        var config = CloudASRConfig(providers: [first, second], providerAPIKeys: [first.id.uuidString: "synthetic-original-key"])
        let a = checks.begin(profileID: first.id)
        let b = checks.begin(profileID: second.id)
        r.check(checks.accepts(a) && checks.accepts(b), "ownership: profiles own independent revisions")
        checks.invalidate(profileID: first.id)
        r.check(!checks.accepts(a) && checks.accepts(b), "ownership: invalidation stays within profile")

        // Removing any one invalidation path must allow a stale token and fail this test.
        let edits: [(inout CloudASRProviderConfig) -> Void] = [
            { $0.baseURL = "https://changed.invalid/v1" }, { $0.model = "replacement-model" },
            { $0.name = "renamed" }, { $0.provider = "renamed vendor" }, { $0.isActive.toggle() },
            { $0.protocolKind = .dashScopeRealtime }, { $0.vendorID = .siliconFlow },
            { $0.customFieldCapabilities.sendPrompt.toggle() }, { $0.customFieldCapabilities.sendLanguage.toggle() },
            { $0.customFieldCapabilities.sendTemperature.toggle() }, { $0.customFieldCapabilities.sendResponseFormat.toggle() }
        ]
        for edit in edits {
            config.providers[0] = first
            let token = checks.begin(profileID: first.id)
            var edited = first
            edit(&edited)
            checks.updateProfile(edited, in: &config)
            r.check(!checks.accepts(token), "ownership: every profile field edit rejects previous revision")
            r.eq(checks.state(for: first.id), .idle, "ownership: edited profile is not connected")
        }
        config.providers[0] = first
        let snapshot = CloudASRRequestConfiguration(provider: first, apiKey: config.providerAPIKeys[first.id.uuidString]!, sendContext: false)
        let keyToken = checks.begin(profileID: first.id)
        checks.updateAPIKey("synthetic-replacement-key", profileID: first.id, in: &config)
        r.check(!checks.accepts(keyToken), "ownership: key edit rejects old result")
        var edited = first
        edited.baseURL = "https://changed.invalid/v1"
        edited.model = "replacement-model"
        edited.vendorID = .openAI
        checks.updateProfile(edited, in: &config)
        r.eq(config.providers[0].id, first.id, "ownership: vendor edit preserves UUID")
        r.eq(config.providers[0].baseURL, "https://changed.invalid/v1", "ownership: vendor edit preserves user URL")
        r.eq(config.providers[0].model, "replacement-model", "ownership: vendor edit preserves user model")
        r.eq(config.providerAPIKeys[first.id.uuidString], "synthetic-replacement-key", "ownership: vendor edit preserves key association")
        CloudTransportProtocol.reset()
        _ = try? await client.transcribe(ASRRequest(samples: [0], sampleRate: 16000, language: nil, context: nil,
            timeout: 2, cloudConfiguration: snapshot))
        let captured = CloudTransportProtocol.snapshot().requests.first!
        r.eq(captured.url?.host, "ownership.invalid", "ownership: prior recording retains endpoint after UI edit")
        r.eq(captured.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-original-key", "ownership: prior recording retains key after UI edit")
        r.check(String(decoding: captured.httpBody!, as: UTF8.self).contains("original-model"), "ownership: prior recording retains model after UI edit")

        CloudTransportProtocol.reset()
        checks.checkConfiguration(provider: first, apiKey: "synthetic-key")
        r.eq(checks.state(for: first.id), .configurationValid, "ownership: pure check does not claim connected")
        var missingModel = first
        missingModel.model = "  "
        checks.checkConfiguration(provider: missingModel, apiKey: "synthetic-key")
        if case .failure = checks.state(for: first.id) { r.check(true, "ownership: model required by UI check") }
        else { r.check(false, "ownership: model required by UI check") }
        var readiness = Configuration.default
        readiness.cloudASRConfig = CloudASRConfig(providers: [missingModel], providerAPIKeys: [first.id.uuidString: "synthetic-key"])
        func cloudReadiness() -> EngineReadiness {
            ReadinessSnapshotBuilder.make(config: readiness, modelStatus: .notLoaded, accessibility: .granted,
                microphone: .granted, speechRecognition: .denied, networkReachable: true,
                appleAvailable: false, computedAt: Date()).cloudASR
        }
        r.check(cloudReadiness() != .ready, "ownership: whitespace model cannot be ready")
        readiness.cloudASRConfig.providers[0] = first
        readiness.cloudASRConfig.providers[0].baseURL = "http://ownership.invalid/v1"
        r.check(cloudReadiness() != .ready, "ownership: invalid endpoint cannot be ready")
        readiness.cloudASRConfig.providers[0] = first
        readiness.cloudASRConfig.providerAPIKeys[first.id.uuidString] = "  "
        r.check(cloudReadiness() != .ready, "ownership: whitespace key cannot be ready")
        let wss = CloudASRVendor.makeProfile(.dashScope, isActive: false)
        await checks.testRecognition(provider: wss, apiKey: "synthetic-key")?.value
        r.eq(checks.state(for: wss.id), .configurationValid, "ownership: WSS check never claims handshake")
        r.eq(CloudTransportProtocol.snapshot().requests.count, 0, "ownership: UI configuration checks perform zero HTTP I/O")

        CloudTransportProtocol.reset()
        let queuedBeforeEdit = checks.testRecognition(provider: first, apiKey: "synthetic-key")!
        checks.updateAPIKey("edited-before-task-start", profileID: first.id, in: &config)
        await queuedBeforeEdit.value
        r.eq(checks.state(for: first.id), .idle, "ownership: click reserves revision before queued task can race an edit")
        r.eq(CloudTransportProtocol.snapshot().requests.count, 0, "ownership: edit before queued action suppresses obsolete upload")
        r.check(!checks.isTesting(first.id), "ownership: skipped queued action releases busy slot")

        for status in [200, 401] {
            CloudTransportProtocol.reset(status: status, delay: 0.08)
            let running = checks.testRecognition(provider: first, apiKey: "synthetic-key")!
            for _ in 0..<100 {
                if !CloudTransportProtocol.snapshot().requests.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(2))
            }
            r.check(checks.isTesting(first.id), "ownership: real test owns busy state")
            await checks.testRecognition(provider: first, apiKey: "synthetic-key")?.value
            checks.updateAPIKey("edited-while-testing-\(status)", profileID: first.id, in: &config)
            await checks.testRecognition(provider: first, apiKey: "synthetic-key")?.value
            r.eq(CloudTransportProtocol.snapshot().requests.count, 1, "ownership: duplicate clicks and edits cannot start concurrent tests")
            await running.value
            r.eq(checks.state(for: first.id), .idle, "ownership: late success or failure cannot update edited configuration")
            r.check(!checks.isTesting(first.id), "ownership: obsolete completion releases its busy slot")
        }
        CloudTransportProtocol.reset()
        await checks.testRecognition(provider: first, apiKey: "synthetic-key")?.value
        r.eq(checks.state(for: first.id), .connected, "ownership: current successful recognition can claim connection")
        var renamed = config.providers.first(where: { $0.id == first.id })!
        renamed.name = "edited after success"
        checks.updateProfile(renamed, in: &config)
        r.eq(checks.state(for: first.id), .idle, "ownership: completed connection badge clears on edit")
        let activationA = checks.begin(profileID: first.id)
        let activationB = checks.begin(profileID: second.id)
        checks.setActive(true, profileID: second.id, in: &config)
        r.check(!checks.accepts(activationA) && !checks.accepts(activationB), "ownership: activation invalidates each changed profile")
        r.eq(config.providers.filter(\.isActive).map(\.id), [second.id], "ownership: activation resolves by UUID")
        let externalToken = checks.begin(profileID: second.id)
        let beforeExternalEdit = config
        config.providers[1].model = "externally-edited-model"
        checks.synchronize(old: beforeExternalEdit, new: config)
        r.check(!checks.accepts(externalToken), "ownership: external configuration edits invalidate results")
        checks.setActive(true, profileID: first.id, in: &config)
        CloudTransportProtocol.reset(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        await checks.testRecognition(provider: first, apiKey: "synthetic-key")?.value
        r.eq(checks.state(for: first.id), .idle, "ownership: cancellation is not a connection result")

        CloudTransportProtocol.reset(delay: 0.08)
        let deletedTest = checks.testRecognition(provider: first, apiKey: "synthetic-key")!
        for _ in 0..<100 {
            if !CloudTransportProtocol.snapshot().requests.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let deletedToken = checks.begin(profileID: first.id)
        checks.deleteProfile(first.id, in: &config)
        await deletedTest.value
        r.check(!checks.accepts(deletedToken), "ownership: deletion rejects old revision")
        r.eq(checks.state(for: first.id), .idle, "ownership: deleted profile result stays absent")
        r.eq(config.providers.map(\.id), [second.id], "ownership: deleting preceding profile shifts safely")
        r.check(config.providers[0].isActive, "ownership: deleting active profile activates remaining UUID")
        r.eq(config.providerAPIKeys[first.id.uuidString], nil, "ownership: deletion removes only deleted key association")
        var shifted = second
        shifted.model = "shifted-model"
        checks.updateProfile(shifted, in: &config)
        checks.updateProfile(first, in: &config)
        checks.updateAPIKey("must-not-recreate", profileID: first.id, in: &config)
        r.eq(config.providers.first?.model, "shifted-model", "ownership: UUID editing targets shifted profile and ignores deleted binding")
        r.eq(config.providerAPIKeys[first.id.uuidString], nil, "ownership: deleted key binding cannot recreate association")
    }

    /// Tests exercise the real provider; only HTTP I/O is replaced. Every host is synthetic.
    static func runTransport(_ r: SelfTest.Reporter) async {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CloudTransportProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let logs = OSAllocatedUnfairLock<[String]>(initialState: [])
        let client = CloudASRProvider(session: session, logger: { message in logs.withLock { $0.append(message) } })
        let key = "arbitrary.synthetic.secret+987"
        let context = ASRContext(phrases: ["private-context-987"], foreground: nil)
        let samples: [Float] = [0, 1, -1, 0.5]
        func profile(_ vendor: CloudASRVendorID) -> CloudASRProviderConfig {
            var value = CloudASRVendor.makeProfile(vendor, isActive: true)
            value.baseURL = "https://asr-transport.invalid/v1"
            if vendor == .custom { value.model = "captured-model" }
            return value
        }
        func request(_ profile: CloudASRProviderConfig, sendContext: Bool = true) -> ASRRequest {
            ASRRequest(samples: samples, sampleRate: 16000, language: "zh", context: context, timeout: 2,
                       cloudConfiguration: .init(provider: profile, apiKey: key, sendContext: sendContext))
        }
        for vendor in [CloudASRVendorID.siliconFlow, .openAI, .custom] {
            CloudTransportProtocol.reset()
            do {
                let result = try await client.transcribe(request(profile(vendor)))
                r.eq(result.text, "fixture transcript", "transport: JSON text is decoded")
                let captured = CloudTransportProtocol.snapshot().requests.first!
                let body = String(decoding: captured.httpBody!, as: UTF8.self)
                r.eq(captured.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)", "transport: Bearer credential")
                r.eq(captured.httpMethod, "POST", "transport: multipart POST")
                r.eq(captured.url?.absoluteString, "https://asr-transport.invalid/v1/audio/transcriptions", "transport: base endpoint")
                r.check(body.contains("name=\"model\"\r\n\r\n\(profile(vendor).model)\r\n"), "transport: selected model")
                for field in ["language", "prompt", "temperature"] {
                    r.check(!body.contains("name=\"\(field)\""), "transport: \(vendor) excludes unsupported \(field)")
                }
                r.eq(body.contains("name=\"response_format\""), vendor == .openAI, "transport: JSON field only with capability")
                let boundary = captured.value(forHTTPHeaderField: "Content-Type")!.components(separatedBy: "boundary=").last!
                r.check(body.hasPrefix("--\(boundary)\r\n") && body.hasSuffix("--\(boundary)--\r\n"), "transport: multipart boundaries match header")
                r.check(body.contains("name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav"), "transport: WAV file disposition")
                let data = captured.httpBody!
                if let wavStart = data.range(of: Data("RIFF".utf8))?.lowerBound {
                    let wav = data.subdata(in: wavStart..<(wavStart + 52))
                    r.eq(Array(wav[0..<12]), [82,73,70,70,44,0,0,0,87,65,86,69], "transport: WAV RIFF size and signature")
                    r.eq(Array(wav[20..<36]), [1,0,1,0,128,62,0,0,0,125,0,0,2,0,16,0], "transport: WAV PCM16 mono 16kHz")
                    r.eq(Array(wav[36..<52]), [100,97,116,97,8,0,0,0,0,0,255,127,1,128,255,63], "transport: exact WAV sample bytes preserved")
                } else { r.check(false, "transport: WAV payload present") }
            } catch { r.check(false, "transport: valid fixture transcribes") }
        }
        var custom = profile(.custom)
        custom.customFieldCapabilities = .init(sendLanguage: true, sendPrompt: true, sendTemperature: true, sendResponseFormat: true)
        for sendContext in [true, false] {
            CloudTransportProtocol.reset()
            _ = try? await client.transcribe(request(custom, sendContext: sendContext))
            let body = String(decoding: CloudTransportProtocol.snapshot().requests.first!.httpBody!, as: UTF8.self)
            r.eq(body.contains("private-context-987"), sendContext, "transport: global context opt-out dominates capability")
            for field in ["language", "temperature", "response_format"] {
                r.check(body.contains("name=\"\(field)\""), "transport: custom explicit \(field) capability")
            }
        }
        let capturedRequest = request(custom)
        let oldIdentity = CloudASRHealthIdentity(provider: custom)
        var health = RouterHealthSnapshot()
        health.synchronizeIdentity(oldIdentity)
        let token = health.token
        let oldRoute = ASRRouteSnapshot(policy: .cloudOnly, selectedProviderID: ASRProviderID.cloud,
            localAvailable: false, cloudAvailable: true, cloudConfiguration: capturedRequest.cloudConfiguration,
            healthGeneration: token.generation)
        custom.customFieldCapabilities.sendPrompt = false
        health.synchronizeIdentity(CloudASRHealthIdentity(provider: custom))
        health.recordProbe(token: token, latencyMs: 12, now: Date())
        r.check(health.probeLatencyMs == nil, "transport: capability edit invalidates stale probe")
        r.check(health.generation != token.generation, "transport: capability edit advances health generation")
        health.recordSuccess(route: oldRoute, latencyMs: 12, now: Date())
        health.recordFailure(route: oldRoute)
        r.eq(health.cloudLatencyEWMA, 0, "transport: stale capability response cannot update latency")
        r.eq(health.cloudConsecutiveFailures, 0, "transport: stale capability failure cannot poison health")
        var vendorOnly = custom
        vendorOnly.customFieldCapabilities = .init()
        let customIdentity = CloudASRHealthIdentity(provider: vendorOnly)
        vendorOnly.vendorID = .siliconFlow
        r.check(CloudASRHealthIdentity(provider: vendorOnly) != customIdentity, "transport: vendor identity belongs to health even with identical effective capabilities")
        custom.vendorID = .siliconFlow
        custom.baseURL = "https://changed.invalid/v2"
        custom.model = "changed-model"
        CloudTransportProtocol.reset()
        _ = try? await client.transcribe(capturedRequest)
        let snapshot = CloudTransportProtocol.snapshot().requests.first!
        r.eq(snapshot.url?.host, "asr-transport.invalid", "transport: snapshot retains original endpoint")
        r.eq(snapshot.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)", "transport: snapshot retains original key")
        r.check(String(decoding: snapshot.httpBody!, as: UTF8.self).contains("captured-model"), "transport: snapshot retains original model")
        r.check(String(decoding: snapshot.httpBody!, as: UTF8.self).contains("private-context-987"), "transport: snapshot retains captured capabilities")

        var fullURL = profile(.custom)
        fullURL.baseURL += "/audio/transcriptions/"
        CloudTransportProtocol.reset()
        _ = try? await client.transcribe(request(fullURL))
        r.eq(CloudTransportProtocol.snapshot().requests.first?.url?.absoluteString,
             "https://asr-transport.invalid/v1/audio/transcriptions", "transport: full URL and base use same endpoint")
        CloudTransportProtocol.reset()
        do {
            _ = try await client.transcribe(request(CloudASRVendor.makeProfile(.dashScope, isActive: true)))
            r.check(false, "transport: WSS cannot use multipart")
        } catch { r.eq(CloudTransportProtocol.snapshot().requests.count, 0, "transport: WSS sends no multipart") }

        for body in ["<html>login</html>", "plain transcript", "{}", #"{"text":3}"#, "{bad", #"{"error":{"message":"private-context-987"}}"#] {
            CloudTransportProtocol.reset(body: body)
            do { _ = try await client.transcribe(request(profile(.custom))); r.check(false, "transport: unknown response rejected") }
            catch { r.check(error is CloudASRError, "transport: malformed response classified safely") }
        }
        CloudTransportProtocol.reset(nonHTTP: true)
        do { _ = try await client.transcribe(request(profile(.custom))); r.check(false, "transport: non-HTTP rejected") }
        catch { r.check(error is CloudASRError, "transport: non-HTTP classified") }

        for code in [400, 401, 403, 404, 429, 500, 503] {
            CloudTransportProtocol.reset(status: code, body: #"{"message":""# + key + " private-context-987 https://secret.invalid/?token=" + key + #""}"#)
            do { _ = try await client.transcribe(request(profile(.custom))); r.check(false, "transport: HTTP failure rejected") }
            catch {
                r.eq((error as? CloudASRError)?.statusCode, code, "transport: preserves HTTP status category")
                let safe = error.localizedDescription
                r.check(!safe.contains(key) && !safe.contains("private-context") && !safe.contains("secret.invalid"), "transport: error body never exposed")
            }
        }
        for code in [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCancelled] {
            CloudTransportProtocol.reset(error: NSError(domain: NSURLErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: "\(key) private-context-987 https://secret.invalid/?token=\(key)"]))
            do { _ = try await client.transcribe(request(profile(.custom))); r.check(false, "transport: network failure rejected") }
            catch {
                if code == NSURLErrorCancelled { r.check(error is CancellationError, "transport: network cancellation stays cancellation") }
                else if code == NSURLErrorTimedOut { r.eq(fallbackReason(for: error), "timeout", "transport: timeout classified") }
                else {
                    r.check(!error.localizedDescription.contains(key) && !error.localizedDescription.contains("private-context"), "transport: network detail never exposed")
                }
            }
        }
        CloudTransportProtocol.reset(redirect: URL(string: "https://redirect-target.invalid/stolen")!)
        _ = try? await client.transcribe(request(profile(.custom)))
        let followed = CloudTransportProtocol.snapshot().requests.filter { $0.url?.host == "redirect-target.invalid" }.count
        r.eq(followed, 0, "transport: no credential/audio redirect")

        CloudTransportProtocol.reset()
        for vendor in [CloudASRVendorID.custom, .siliconFlow, .openAI, .dashScope] {
            var value = profile(vendor)
            if vendor == .dashScope { value.baseURL = "wss://asr-transport.invalid/realtime" }
            if case .failure = client.validateConfiguration(provider: value, apiKey: key) {
                r.check(false, "transport: valid local configuration accepted")
            }
            value.baseURL += "?token=\(key)"
            if case .success = client.validateConfiguration(provider: value, apiKey: key) {
                r.check(false, "transport: query credentials rejected locally")
            }
        }
        for (url, expected) in [
            ("wss://asr-transport.invalid/realtime", true),
            (" wss://asr-transport.invalid/realtime", false),
            ("wss://asr-transport.invalid/realtime ", false),
            (" wss://asr-transport.invalid/realtime ", false),
            ("\twss://asr-transport.invalid/realtime\t", false),
            ("\nwss://asr-transport.invalid/realtime\n", false)
        ] {
            var realtime = profile(.dashScope)
            realtime.baseURL = url
            let runtimeAccepts = (try? RealtimeASRConfiguration(provider: realtime, apiKey: key, language: nil)) != nil
            let validationAccepts = (try? client.validateConfiguration(provider: realtime, apiKey: key).get()) != nil
            let connectionResult = await client.testConnection(provider: realtime, apiKey: key)
            let connectionAccepts = (try? connectionResult.get()) != nil
            r.eq(runtimeAccepts, expected, "transport: realtime runtime keeps strict whitespace contract")
            r.eq(validationAccepts, runtimeAccepts, "transport: WSS pure validation agrees with runtime on whitespace")
            r.eq(connectionAccepts, runtimeAccepts, "transport: WSS connection check agrees with runtime on whitespace")
        }
        r.eq(CloudTransportProtocol.snapshot().requests.count, 0, "transport: configuration validation performs zero I/O")
        for invalid in ["", "   ", "\n"] {
            if case .success = client.validateConfiguration(provider: profile(.custom), apiKey: invalid) {
                r.check(false, "transport: blank credentials invalid")
            }
            var noModel = profile(.custom)
            noModel.model = invalid
            if case .success = client.validateConfiguration(provider: noModel, apiKey: key) {
                r.check(false, "transport: blank model invalid")
            }
        }
        CloudTransportProtocol.reset(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        if case .failure(.cancelled) = await client.testConnection(provider: profile(.custom), apiKey: key) {
            r.check(true, "transport: connection-test cancellation is explicit")
        } else { r.check(false, "transport: connection-test cancellation stays cancelled") }
        let cancelledRequest = request(profile(.custom))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.transcribe(cancelledRequest)
        }
        CloudTransportProtocol.reset()
        do { _ = try await cancelled.value; r.check(false, "transport: pre-cancelled request cannot succeed") }
        catch { r.check(error is CancellationError, "transport: pre-cancelled request stays cancelled") }
        r.eq(CloudTransportProtocol.snapshot().requests.count, 0, "transport: pre-cancelled task sends no audio")
        CloudTransportProtocol.reset(delay: 0.1)
        let inflightRequest = request(profile(.custom))
        let inflight = Task { try await client.transcribe(inflightRequest) }
        for _ in 0..<200 {
            if !CloudTransportProtocol.snapshot().requests.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        r.eq(CloudTransportProtocol.snapshot().requests.count, 1, "transport: cancellation fixture reaches real transport")
        inflight.cancel()
        do { _ = try await inflight.value; r.check(false, "transport: cancelled request cannot deliver late transcript") }
        catch { r.check(error is CancellationError, "transport: in-flight cancellation stays cancelled") }
        let safeLogs = logs.withLock { $0.joined(separator: "\n") }
        r.check(!safeLogs.contains(key) && !safeLogs.contains("private-context") && !safeLogs.contains("secret.invalid"),
                "transport: logs exclude raw body, URL query, key and context")

        CloudTransportProtocol.reset()
        let testResult = await client.testConnection(provider: profile(.siliconFlow), apiKey: key)
        if case .failure = testResult { r.check(false, "transport: synthetic connection succeeds") }
        let testBody = String(decoding: CloudTransportProtocol.snapshot().requests.first!.httpBody!, as: UTF8.self)
        r.check(!testBody.contains("name=\"response_format\"") && !testBody.contains("name=\"temperature\""), "transport: connection test uses vendor field contract")
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

private final class CloudTransportProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture {
        var status = 200
        var body = #"{"text":"fixture transcript"}"#
        var nonHTTP = false
        var error: NSError?
        var redirect: URL?
        var delay: TimeInterval = 0
        var requests: [URLRequest] = []
    }
    static let state = OSAllocatedUnfairLock(initialState: Fixture())
    static func reset(status: Int = 200, body: String = #"{"text":"fixture transcript"}"#,
                      nonHTTP: Bool = false, error: NSError? = nil, redirect: URL? = nil, delay: TimeInterval = 0) {
        state.withLock { $0 = Fixture(status: status, body: body, nonHTTP: nonHTTP, error: error, redirect: redirect, delay: delay) }
    }
    static func snapshot() -> Fixture { state.withLock { $0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = bytes
        }
        let recorded = captured
        let fixture = Self.state.withLock { value in value.requests.append(recorded); return value }
        if let error = fixture.error { client?.urlProtocol(self, didFailWithError: error); return }
        if let target = fixture.redirect, request.url?.host != target.host {
            var redirected = request
            redirected.url = target
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        if fixture.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + fixture.delay) { [self] in
                if !stopped.withLock({ $0 }) { complete(fixture) }
            }
        } else { complete(fixture) }
    }
    private func complete(_ fixture: Fixture) {
        let response: URLResponse = fixture.nonHTTP
            ? URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: fixture.body.utf8.count, textEncodingName: "utf-8")
            : HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}
