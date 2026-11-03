import Foundation

/// Catches developer fallback, escaped resources, and success inferred from an earlier stage.
enum M5ArtifactSelfTests {
    @MainActor static func run(_ r: SelfTest.Reporter) async {
        do { try testNoDeveloperResourceFallback(r); try testResourceValidation(r) }
        catch { r.check(false, "M5 artifact fixture setup failed") }
        await testArtifactStageTruth(r)
    }

    static func fixture(_ body: (Bundle, URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = RuntimeEnvironment.current.paths.temporaryDirectory.appendingPathComponent("m5-artifact-\(UUID())")
        let app = root.appendingPathComponent("Synthetic.app")
        let resources = app.appendingPathComponent("Contents/Resources/FlowType_FlowType.bundle")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.flowtype.synthetic", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("{\"swift ui\":\"SwiftUI\"}".utf8).write(to: resources.appendingPathComponent("tech_terms.json"))
        try Data("[\"嗯\"]".utf8).write(to: resources.appendingPathComponent("filler_words.json"))
        try fm.copyItem(at: Bundle.module.url(forResource: "status_bar_icon", withExtension: "png")!, to: resources.appendingPathComponent("status_bar_icon.png"))
        try body(Bundle(url: app)!, resources, root)
    }

    static func failure(in app: Bundle) -> ValidationFailureCode? {
        do { _ = try AppResources.validateArtifactResources(in: app); return nil }
        catch let ArtifactCheckError.failure(code) { return code }
        catch { return .unexpectedFailure }
    }

    // Ignoring the app bundle and using Bundle.module must break both cases.
    static func testNoDeveloperResourceFallback(_ r: SelfTest.Reporter) throws {
        for file in ["tech_terms.json", ""] {
            try fixture { app, resources, _ in
                try FileManager.default.removeItem(at: file.isEmpty ? resources : resources.appendingPathComponent(file))
                r.eq(failure(in: app), .resourceMissing, "M5 missing packaged resources never use development fallback")
            }
        }
    }

    // Removing containment, parsing, nonempty or icon checks breaks independent fixtures.
    static func testResourceValidation(_ r: SelfTest.Reporter) throws {
        try fixture { app, _, _ in r.eq(failure(in: app), nil, "M5 valid synthetic app resources") }
        for (file, value) in [("tech_terms.json", "{"), ("tech_terms.json", "{}"), ("tech_terms.json", "{\"\":\"SwiftUI\"}"),
                              ("filler_words.json", "[]"), ("filler_words.json", "{}"), ("filler_words.json", "[\"\"]"),
                              ("status_bar_icon.png", "invalid image")] {
            try fixture { app, resources, _ in
                try Data(value.utf8).write(to: resources.appendingPathComponent(file))
                r.eq(failure(in: app), .resourceMalformed, "M5 rejects malformed or empty \(file)")
            }
        }
        for file in ["status_bar_icon.png", "filler_words.json"] {
            try fixture { app, resources, _ in
                try FileManager.default.removeItem(at: resources.appendingPathComponent(file))
                r.eq(failure(in: app), .resourceMissing, "M5 rejects missing \(file)")
            }
        }
        for escape in ["file", "bundle", "metal", "dangling file", "dangling metal"] {
            try fixture { app, resources, root in
                let fm = FileManager.default
                let outside = root.appendingPathComponent("outside")
                let target: URL
                switch escape {
                case "file": target = resources.appendingPathComponent("tech_terms.json"); try fm.moveItem(at: target, to: outside)
                case "bundle": target = resources; try fm.moveItem(at: target, to: outside)
                case "dangling file":
                    target = resources.appendingPathComponent("tech_terms.json")
                    try fm.removeItem(at: target)
                case "dangling metal":
                    target = app.bundleURL.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle")
                default:
                    target = app.bundleURL.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle")
                    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
                }
                try fm.createSymbolicLink(at: target, withDestinationURL: outside)
                r.eq(failure(in: app), .resourceOutsideBundle, "M5 rejects \(escape) symlink escaping app")
            }
        }
    }

    @MainActor static func testArtifactStageTruth(_ r: SelfTest.Reporter) async {
        let context = RuntimeContext(role: .smokeTest, mode: .artifact, runID: UUID(), paths: RuntimeEnvironment.current.paths, defaultsSuiteName: nil, selfTestFilter: nil)
        let good = BuildIdentity(origin: .packaged, metadata: M5BuildInfoSelfTests.metadata, failureCode: nil)
        let dirty = BuildMetadata(schemaVersion: 1, version: "1.2.3", buildNumber: "42", gitSHA: String(repeating: "a", count: 40), sourceTree: String(repeating: "b", count: 40), builtAt: "2026-11-03T08:09:10Z", dirty: true)
        let invalid = [BuildIdentity(origin: .invalid, metadata: nil, failureCode: .missingMetadata),
                       BuildIdentity(origin: .development, metadata: nil, failureCode: nil),
                       BuildIdentity(origin: .packaged, metadata: nil, failureCode: nil),
                       BuildIdentity(origin: .packaged, metadata: dirty, failureCode: nil)]
        let cases: [(String, BuildIdentity, ValidationFailureCode?, [Int32], ValidationFailureCode?, [String], [Bool])] = [
            ("success", good, nil, [2, 3], nil, ["resources", "metal", "mlx"], [true, true, true, true]),
            ("MLX failed", good, .mlxOperationFailed, [], .mlxOperationFailed, ["resources", "metal", "mlx"], [true, true, false, true]),
            ("no GPU", good, .metalUnavailable, [], .metalUnavailable, ["resources", "metal"], [true, false, false, true]),
            ("bad library", good, .metalLibraryInvalid, [], .metalLibraryInvalid, ["resources", "metal"], [true, false, false, true]),
            ("wrong output", good, nil, [2, 4], .mlxOperationFailed, ["resources", "metal", "mlx"], [true, true, false, true]),
            ("missing resources", good, .resourceMissing, [], .resourceMissing, ["resources"], [false, false, false, false])
        ] + invalid.map { ("invalid identity", $0, nil, [], .invalidBuildInfo, [], [false, false, false, false]) }
        for (name, identity, injected, values, expected, expectedCalls, flags) in cases {
            var calls: [String] = []
            // These are the only dependencies used by focused/full tests. No live GPU/model work.
            let dependencies = ArtifactCheckDependencies(resolveResources: {
                calls.append("resources")
                if injected == .resourceMissing { throw ArtifactCheckError.failure(.resourceMissing) }
                return URL(fileURLWithPath: "/synthetic/Synthetic.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib")
            }, loadMetalLibrary: { _ in
                calls.append("metal")
                if injected == .metalUnavailable || injected == .metalLibraryInvalid { throw ArtifactCheckError.failure(injected!) }
            }, mlxOperation: {
                calls.append("mlx")
                if injected == .mlxOperationFailed { throw ArtifactCheckError.failure(.mlxOperationFailed) }
                return values
            })
            let report = await RuntimeArtifactCheck.run(context: context, identity: identity, dependencies: dependencies)
            r.eq(report.failureCode, expected, "M5 artifact closed failure: \(name)")
            r.eq(report.ok, expected == nil, "M5 artifact truthful success: \(name)")
            r.eq([report.appResources, report.metalLibrary, report.mlxOperation, report.resolvedInsideApp], flags, "M5 artifact only completed stages are true: \(name)")
            r.eq(calls, expectedCalls, "M5 artifact stops before later effects: \(name)")
            let data = try! JSONEncoder().encode(report)
            let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            r.eq(json["mode"] as? String, "artifact", "M5 artifact mode")
            r.eq(json["role"] as? String, "smokeTest", "M5 artifact role")
            r.eq(json["runID"] as? String, context.runID.uuidString, "M5 artifact run identity")
            r.check(report.durationMs >= 0 && report.schemaVersion == 1, "M5 artifact common fields")
            if expected == nil { r.check(json["failureCode"] is NSNull, "M5 artifact explicit null on success") }
            r.check(!String(decoding: data, as: UTF8.self).contains("/synthetic"), "M5 artifact no path leakage")
        }
    }
}
