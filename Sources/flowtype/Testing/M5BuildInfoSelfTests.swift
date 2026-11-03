import Foundation

/// Catches trusting malformed release identity and losing queued diagnostics at exit.
enum M5BuildInfoSelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) async {
        testMetadataValidation(r)
        do { try testBundleOrigins(r); try await testIdentityAndConcurrentFlush(r) }
        catch { r.check(false, "M5 identity/log fixture operation failed") }
    }

    static let metadata = BuildMetadata(schemaVersion: 1, version: "1.2.3", buildNumber: "42",
        gitSHA: String(repeating: "a", count: 40), sourceTree: String(repeating: "b", count: 40),
        builtAt: "2026-11-03T08:09:10Z", dirty: false)
    static let plist: [String: String] = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"]

    // Removing any field/format/plist/dirty check must fail one independent fixture.
    static func testMetadataValidation(_ r: SelfTest.Reporter) {
        let data = try! JSONEncoder().encode(metadata)
        let good = BuildInfo.validate(json: data, infoPlist: plist)
        r.eq(good.origin, .packaged, "M5 valid packaged identity")
        r.eq(good.metadata, metadata, "M5 metadata preserved")
        r.eq(good.failureCode, nil, "M5 valid identity has no failure")
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        var invalid: [(String, Data)] = [("bad JSON", Data("{".utf8)), ("array", Data("[]".utf8))]
        for field in object.keys.sorted() {
            var changed = object; changed.removeValue(forKey: field)
            invalid.append(("missing \(field)", try! JSONSerialization.data(withJSONObject: changed)))
        }
        let mutations: [(String, Any)] = [
            ("schemaVersion", 2), ("schemaVersion", true), ("version", "1.2"), ("version", "1.2.3\n"),
            ("version", "-1.2.3"), ("version", "1.2.<3>"), ("buildNumber", "-1"),
            ("buildNumber", "42\n"), ("buildNumber", 42), ("gitSHA", String(repeating: "a", count: 39)),
            ("gitSHA", String(repeating: "g", count: 40)), ("sourceTree", "bad"),
            ("builtAt", "2026-11-03T08:09:10+08:00"), ("builtAt", "2026-02-30T08:09:10Z"),
            ("builtAt", "2026-11-03T08:09:10Z\n"), ("dirty", true), ("dirty", "false")]
        for (field, value) in mutations {
            var changed = object; changed[field] = value
            invalid.append(("malformed \(field)", try! JSONSerialization.data(withJSONObject: changed)))
        }
        for (name, fixture) in invalid {
            let identity = BuildInfo.validate(json: fixture, infoPlist: plist)
            r.eq(identity.origin, .invalid, "M5 rejects \(name)")
            r.eq(identity.metadata, nil, "M5 invalid identity hides untrusted metadata")
            r.check(identity.failureCode != nil, "M5 invalid identity has closed failure")
        }
        for changed in [["CFBundleShortVersionString": "1.2.4", "CFBundleVersion": "42"],
                        ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "43"], [:]] {
            r.eq(BuildInfo.validate(json: data, infoPlist: changed).origin, .invalid, "M5 rejects plist mismatch/missing")
        }
        let development = BuildIdentity(origin: .development, metadata: nil, failureCode: nil)
        let encoded = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(development)) as! [String: Any]
        r.check(encoded["metadata"] is NSNull && encoded["failureCode"] is NSNull,
                "M5 development identity encodes explicit null metadata and failure")
        let packagedJSON = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as! [String: Any]
        r.check(packagedJSON["failureCode"] is NSNull, "M5 packaged identity encodes null failure")
        r.check(good.aboutDescription.contains("1.2.3") && good.aboutDescription.contains("42") &&
                good.aboutDescription.contains("aaaaaaaa") && good.aboutDescription.contains("2026-11-03T08:09:10Z"),
                "M5 about derives version build SHA and UTC from identity")
    }

    // An .app with absent/bad JSON must never impersonate a development invocation.
    static func testBundleOrigins(_ r: SelfTest.Reporter) throws {
        let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("m5-build-bundles-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Broken.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        var info = plist
        info["CFBundleIdentifier"] = "com.flowtype.synthetic"
        info["CFBundlePackageType"] = "APPL"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let bundle = Bundle(url: app.deletingLastPathComponent())!
        r.eq(BuildInfo.load(bundle: bundle).origin, .invalid, "M5 missing app metadata is invalid")
        try Data("{}".utf8).write(to: app.appendingPathComponent("Resources/FlowTypeBuild.json"))
        r.eq(BuildInfo.load(bundle: bundle).origin, .invalid, "M5 malformed app is never development")
        try JSONEncoder().encode(metadata).write(to: app.appendingPathComponent("Resources/FlowTypeBuild.json"))
        r.eq(BuildInfo.load(bundle: bundle).origin, .packaged, "M5 loads app resource identity")
        let dev = root.appendingPathComponent("Development.bundle")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        let identity = BuildInfo.load(bundle: Bundle(url: dev)!)
        r.eq(identity.origin, .development, "M5 non-app development identity")
        r.eq(identity.metadata, nil, "M5 development never guesses metadata")
        r.check(identity.aboutDescription.contains("development") && identity.aboutDescription.contains("unknown"),
                "M5 development about is explicit")
    }

    // Missing sync header, rotation, per-line prefixes or queue-aware flush breaks actual files.
    static func testIdentityAndConcurrentFlush(_ r: SelfTest.Reporter) async throws {
        let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("m5-log-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = BuildInfo.validate(json: try JSONEncoder().encode(metadata), infoPlist: plist)
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let file = root.appendingPathComponent("run-one.log")
        let writer = try DiagnosticLogWriter(fileURL: file, role: .selfTest, runID: id, identity: identity,
                                             maxLogSize: 1400, maxRotatedFiles: 3)
        let first = try String(contentsOf: file, encoding: .utf8)
        r.check(first.contains("BuildIdentity") && first.contains("aaaaaaaa") && first.contains("1.2.3"),
                "M5 synchronous startup header before first log")
        DispatchQueue.concurrentPerform(iterations: 120) { index in writer.log("synthetic \(index)\nsecond line") }
        writer.log("final-sentinel")
        writer.flush()
        let current = try String(contentsOf: file, encoding: .utf8)
        r.check(current.split(separator: "\n").last?.hasSuffix("final-sentinel") == true, "M5 immediate flush retains final sentinel")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        r.eq(files.count, 4, "M5 rotation caps current plus three archives")
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            r.check(text.split(separator: "\n").first?.contains("BuildIdentity") == true, "M5 rotated header remains locatable")
            let lines = text.split(separator: "\n")
            r.check(!lines.isEmpty && lines.allSatisfy { $0.contains("role=selfTest") && $0.contains("runID=\(id.uuidString)") && $0.contains("[SelfTest]") },
                    "M5 every physical line carries role run and self-test marker")
            r.check(lines.allSatisfy { $0.range(of: #"^\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\]"#, options: .regularExpression) != nil },
                    "M5 every log line has UTC timestamp")
        }
        let completeFile = root.appendingPathComponent("complete.log")
        let complete = try DiagnosticLogWriter(fileURL: completeFile, role: .selfTest, runID: id, identity: identity)
        DispatchQueue.concurrentPerform(iterations: 120) { index in complete.log("record-\(index)") }
        complete.log("complete-sentinel"); complete.flush()
        let completeLines = try String(contentsOf: completeFile, encoding: .utf8).split(separator: "\n")
        r.eq(completeLines.count, 122, "M5 concurrent flush preserves all records plus header and sentinel")
        r.check((0..<120).allSatisfy { index in completeLines.filter { $0.hasSuffix(" record-\(index)") }.count == 1 },
                "M5 each concurrent record written exactly once")
        let queue = DispatchQueue(label: "com.flowtype.synthetic-log")

        let other = root.appendingPathComponent("run-two.log")
        let second = try DiagnosticLogWriter(fileURL: other, role: .smokeTest, runID: UUID(), identity: identity, queue: queue)
        let completed = await withCheckedContinuation { continuation in
            queue.async { second.log("inside-queue-sentinel"); second.flush(); continuation.resume(returning: true) }
        }
        r.check(completed, "M5 flush called from writer queue returns")
        second.flush()
        let secondText = try String(contentsOf: other, encoding: .utf8)
        r.check(secondText.contains("inside-queue-sentinel") && !secondText.contains(id.uuidString), "M5 different runs do not mix logs")
        r.check(!current.contains("inside-queue-sentinel"), "M5 second writer preserves first run")
        let before = AppLogger.logFileURL
        do { try AppLogger.configure(context: RuntimeEnvironment.current, identity: identity)
            r.check(false, "M5 configure twice must fail")
        } catch { r.check(true, "M5 configure twice fails") }
        r.eq(AppLogger.logFileURL, before, "M5 configure conflict preserves original log")
        let blocked = root.appendingPathComponent("regular-file")
        try Data().write(to: blocked)
        do { _ = try DiagnosticLogWriter(fileURL: blocked.appendingPathComponent("diagnostic.log"), role: .selfTest,
                                         runID: id, identity: identity)
            r.check(false, "M5 startup header write failure throws")
        } catch { r.check(true, "M5 startup header write failure throws") }
    }
}
