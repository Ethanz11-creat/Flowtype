import Foundation

enum DistributionVerificationSelfTests {
    static var passed = 0, failed = 0
    static func check(_ value: Bool, _ name: String) { if value { passed += 1 } else { failed += 1; print("FAIL: \(name)") } }
    static func testDistributionIdentityAndEvidence(root: URL) throws {
        let fm = FileManager.default, app = root.appendingPathComponent("FlowType.app"), manifest = root.appendingPathComponent("manifest.json")
        let dmg = root.appendingPathComponent("FlowType.dmg"), evidence = root.appendingPathComponent("notary.json")
        let binary = app.appendingPathComponent("Contents/MacOS/FlowType")
        let info = app.appendingPathComponent("Contents/Resources/FlowTypeBuild.json")
        let shader = app.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib")
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: shader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("signed fixture".utf8).write(to: binary); try Data("shader".utf8).write(to: shader)
        let metadata = PackagingMetadata(schemaVersion: 1, version: "1.0.0", buildNumber: "1", gitSHA: String(repeating: "a", count: 40), sourceTree: String(repeating: "b", count: 40), builtAt: "2026-11-10T00:00:00Z", dirty: false)
        try JSONEncoder().encode(metadata).write(to: info)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let m = try PackagingManifest(schemaVersion: 1, buildInfo: metadata, architecture: "arm64", binarySHA256: packagingHash(binary), buildInfoSHA256: packagingHash(info), shaderSHA256: packagingHash(shader), resources: resourceDigests(app))
        try JSONEncoder().encode(m).write(to: manifest)
        for name in ["FlowType.dmg", "app-submitted.zip", "dmg-submitted.dmg"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let appID = "11111111-1111-1111-1111-111111111111", dmgID = "22222222-2222-2222-2222-222222222222"
        let identity = "Developer ID Application: Fixture (ABCDEFGHIJ)"
        func writeEvidence(_ scenario: String) throws {
            func submission(_ id: String, _ file: String, _ final: String) throws -> DistributionSubmission {
                let status = scenario == "rejected" ? "Invalid" : "Accepted"
                return DistributionSubmission(acceptedOutput: "{\"id\":\"\(id)\",\"status\":\"\(status)\",\"message\":\"Processing complete\"}", submittedSHA256: try packagingHash(root.appendingPathComponent(file)), finalSHA256: final)
            }
            try JSONEncoder().encode(DistributionNotaryEvidence(schemaVersion: 1, signingIdentity: scenario == "wrong-identity" ? "Developer ID Application: Other (ABCDEFGHIJ)" : identity, teamID: "ABCDEFGHIJ",
                app: submission(appID, "app-submitted.zip", packagingFingerprint(app)), dmg: submission(dmgID, "dmg-submitted.dmg", scenario == "wrong-final" ? String(repeating: "0", count: 64) : packagingHash(dmg)))).write(to: evidence)
        }
        var successfulReport: Data!
        for (scenario, expected) in [("adhoc", VerificationStatus.pending), ("no-profile", .pending), ("rejected", .fail), ("wrong-final", .fail), ("wrong-identity", .fail), ("forged-log", .fail), ("bad-signature", .fail), ("changed-dmg-signature", .fail), ("no-runtime", .fail), ("bad-staple", .fail), ("bad-gatekeeper", .fail), ("good", .pass)] {
            try writeEvidence(scenario)
            var calls: [[String]] = []
            let report = try DistributionVerification.evaluate(app: app, manifest: manifest, dmg: dmg, evidence: evidence, profile: scenario == "no-profile" ? nil : "fixture-profile", command: { exe, args in
                calls.append([exe] + args)
                if args.contains("--display") {
                    let text = scenario == "adhoc" ? "Signature=adhoc\nTeamIdentifier=not set\n" : "Authority=\(identity)\nTeamIdentifier=ABCDEFGHIJ\nCodeDirectory v=20500 flags=0x10000(runtime) hashes=1\nCDHash=0123456789012345678901234567890123456789\n"
                    let displayed = scenario == "changed-dmg-signature" && args.last?.hasSuffix("dmg-submitted.dmg") == true ? text.replacingOccurrences(of: "0123456789012345678901234567890123456789", with: "ffffffffffffffffffffffffffffffffffffffff") : text
                    return DistributionCommandResult(exitCode: 0, output: Data((scenario == "no-runtime" ? displayed.replacingOccurrences(of: "(runtime)", with: "") : displayed).utf8))
                }
                if exe == "/usr/bin/ditto", args.contains("-x") { try fm.copyItem(at: app, to: URL(fileURLWithPath: args.last!).appendingPathComponent("FlowType.app")) }
                if args.first == "attach", let i = args.firstIndex(of: "-mountpoint") { try fm.copyItem(at: app, to: URL(fileURLWithPath: args[i + 1]).appendingPathComponent("FlowType.app")) }
                if args.starts(with: ["notarytool", "log"]) {
                    let file = args[2] == appID ? "app-submitted.zip" : "dmg-submitted.dmg"
                    let hash = scenario == "forged-log" ? String(repeating: "0", count: 64) : try packagingHash(root.appendingPathComponent(file))
                    return DistributionCommandResult(exitCode: 0, output: Data("{\"jobId\":\"\(args[2])\",\"status\":\"Accepted\",\"sha256\":\"\(hash)\"}".utf8))
                }
                let bad = scenario == "bad-signature" && args.contains("--verify") || scenario == "bad-staple" && args.starts(with: ["stapler", "validate"]) || scenario == "bad-gatekeeper" && exe == "/usr/sbin/spctl"
                return DistributionCommandResult(exitCode: bad ? 1 : 0, output: Data())
            })
            check(report.status == expected, "distribution \(scenario) is \(expected.rawValue)")
            if scenario == "adhoc" || scenario == "no-profile" { check(!calls.contains(where: { $0.contains("notarytool") }), "missing distribution conditions never access profile") }
            if scenario == "good" {
                successfulReport = try JSONEncoder().encode(report)
                check(report.candidate.packageSHA256 == report.dmgSHA256 && report.appNotarizationID == appID && report.dmgNotarizationID == dmgID && report.issues.isEmpty, "Pass binds package and both Accepted IDs")
                check(calls.filter { $0.contains("log") }.count == 2, "Pass authenticates both raw submissions with fresh logs")
            }
        }
        // The production orchestrator must own the sequence and capture real command output.
        for scenario in ["good", "rejected", "source-change", "cancelled", "late-evaluation", "report-write"] {
            let rejected = scenario == "rejected", shouldFail = scenario != "good"
            let releaseRoot = root.appendingPathComponent("release-\(UUID())")
            try fm.createDirectory(at: releaseRoot, withIntermediateDirectories: false)
            let final = releaseRoot.appendingPathComponent("FlowType.dmg"), record = releaseRoot.appendingPathComponent("evidence/notary.json")
            try Data("old package".utf8).write(to: final)
            var calls: [[String]] = []
            let fake: DistributionCommand = { exe, args in
                calls.append([exe] + args)
                if args.contains("--display") { return DistributionCommandResult(exitCode: 0, output: Data("Authority=\(identity)\nTeamIdentifier=ABCDEFGHIJ\nCodeDirectory v=20500 flags=0x10000(runtime) hashes=1\nCDHash=0123456789012345678901234567890123456789\n".utf8)) }
                if exe == "/usr/bin/ditto" {
                    if args.contains("-c") { try Data("submitted app archive".utf8).write(to: URL(fileURLWithPath: args.last!)) }
                    else if args.contains("-x") { try fm.copyItem(at: app, to: URL(fileURLWithPath: args.last!).appendingPathComponent("FlowType.app")) }
                    else { try fm.copyItem(at: app, to: URL(fileURLWithPath: args.last!)) }
                }
                if exe == "/usr/bin/hdiutil", args.first == "create" { try Data("signed submitted dmg".utf8).write(to: URL(fileURLWithPath: args.last!)) }
                if args.first == "attach", let i = args.firstIndex(of: "-mountpoint") { try fm.copyItem(at: app, to: URL(fileURLWithPath: args[i + 1]).appendingPathComponent("FlowType.app")) }
                if args.starts(with: ["notarytool", "submit"]) {
                    let id = args[2].hasSuffix(".zip") ? appID : dmgID
                    return DistributionCommandResult(exitCode: rejected ? 1 : 0, output: Data("{\"id\":\"\(id)\",\"status\":\"\(rejected ? "Invalid" : "Accepted")\"}".utf8))
                }
                if args.starts(with: ["notarytool", "log"]) {
                    let file = record.deletingLastPathComponent().appendingPathComponent(args[2] == appID ? "app-submitted.zip" : "dmg-submitted.dmg")
                    return DistributionCommandResult(exitCode: 0, output: Data("{\"jobId\":\"\(args[2])\",\"status\":\"Accepted\",\"sha256\":\"\(try packagingHash(file))\"}".utf8))
                }
                return DistributionCommandResult(exitCode: scenario == "late-evaluation" && exe == "/usr/sbin/spctl" && args.contains("open") ? 1 : 0, output: Data())
            }
            do {
                try DistributionVerification.distribute(repository: root, app: app, manifest: manifest, dmg: final, evidence: record, identity: identity, profile: "fixture", command: fake, beforePublish: {
                    if scenario == "source-change" { throw VerificationFailure.sourceChanged }
                    if scenario == "cancelled" { throw PackagingFailure.interrupted }
                }, publishReport: { _ in if scenario == "report-write" { throw VerificationFailure.outputUnavailable } })
                check(!shouldFail, "late failure blocks distribution: \(scenario)")
                if !shouldFail {
                    let data = try JSONDecoder().decode(DistributionNotaryEvidence.self, from: Data(contentsOf: record))
                    check(try data.dmg.finalSHA256 == packagingHash(final) && data.app.finalSHA256 == packagingFingerprint(app), "release captures final app and package hashes")
                    let submit = calls.indices.filter { calls[$0].contains("submit") }, staple = calls.indices.filter { calls[$0].contains("staple") }
                    let checkIndex = calls.firstIndex { $0[0].hasSuffix("scripts/check-app.sh") }
                    check(submit.count == 2 && staple.count == 2 && submit[0] < staple[0] && staple[0] < (checkIndex ?? -1) && (checkIndex ?? Int.max) < submit[1] && submit[1] < staple[1], "release orders app acceptance staple resource check before DMG acceptance and staple")
                    check(!calls.contains { $0[0].hasSuffix("build-app.sh") || $0.contains("--sign") && $0.last == app.path }, "distribution never rebuilds or resigns accepted app")
                }
            } catch { check(shouldFail, "release pipeline completes only accepted fixture") }
            if shouldFail { check(try Data(contentsOf: final) == Data("old package".utf8), "failure preserves previous final package: \(scenario)") }
            if rejected {
                check(try Data(contentsOf: final) == Data("old package".utf8), "notary rejection preserves previous final package")
                check(!calls.contains { $0.contains("staple") }, "notary rejection never staples")
                let raw = try? String(contentsOf: record.deletingLastPathComponent().appendingPathComponent("app-submit.json"), encoding: .utf8)
                check(raw?.contains("Invalid") == true, "nonzero notary rejection preserves named raw response")
            }
        }
        // Run the actual CLI only on inputs that fail before signing/profile/network commands.
        let output = root.appendingPathComponent("cli-report.json"), badPackage = root.appendingPathComponent("unreadable.dmg")
        try fm.createDirectory(at: badPackage, withIntermediateDirectories: false)
        let originalManifest = try Data(contentsOf: manifest)
        for scenario in ["package-read", "malformed-manifest", "app-path", "preflight"] {
            try successfulReport.write(to: output)
            if scenario == "malformed-manifest" { try Data("malformed".utf8).write(to: manifest) }
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "FLOWTYPE_SIGNING_IDENTITY"); env.removeValue(forKey: "FLOWTYPE_NOTARY_PROFILE")
            if scenario == "preflight" { env["FLOWTYPE_SIGNING_IDENTITY"] = identity; env["FLOWTYPE_NOTARY_PROFILE"] = "not-a-real-profile" }
            let args = (scenario == "preflight" ? ["--distribute"] : []) + ["--app", scenario == "app-path" ? root.appendingPathComponent("missing.app").path : app.path,
                "--manifest", manifest.path, "--dmg", scenario == "package-read" ? badPackage.path : dmg.path, "--notary-evidence", evidence.path, "--output", output.path]
            let result = try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: CommandLine.arguments[0]), arguments: args,
                workingDirectory: URL(fileURLWithPath: fm.currentDirectoryPath), environment: env,
                stdoutURL: root.appendingPathComponent("cli-\(scenario).stdout"), stderrURL: root.appendingPathComponent("cli-\(scenario).stderr"), timeoutSeconds: 15))
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
            check(result.cliExitCode != 0 && saved?["status"] as? String == "Fail", "actual CLI failure invalidates previous Pass: \(scenario)")
            if ["package-read", "preflight"].contains(scenario) {
                check((saved?["candidate"] as? [String: Any])?["binarySHA256"] as? String == m.binarySHA256, "actual CLI failure keeps established candidate: \(scenario)")
            } else { check(saved?["candidate"] == nil, "unknown candidate failure invents no hashes: \(scenario)") }
            try originalManifest.write(to: manifest)
        }
        let pending = try DistributionVerification.evaluate(app: app, manifest: manifest, dmg: root.appendingPathComponent("missing.dmg"), evidence: evidence, profile: nil, command: { _, args in
            DistributionCommandResult(exitCode: 0, output: args.contains("--display") ? Data("Signature=adhoc\nTeamIdentifier=not set\n".utf8) : Data())
        })
        let pendingFile = root.appendingPathComponent("nil-package.json"), ledger = root.appendingPathComponent("pending-ledger.json")
        try JSONEncoder().encode(pending).write(to: pendingFile)
        try ModelCenterAcceptance.templateData().write(to: ledger)
        check(try pending.status == .pending && pending.candidate.packageSHA256 == nil && pending.dmgSHA256 == nil && ModelCenterAcceptance.evaluate(report: ledger, manifest: manifest, distributionReport: pendingFile) == .pending, "nil-package Pending producer roundtrips through real D2 consumer")
        try Data("changed binary".utf8).write(to: binary)
        let invalid = try? DistributionVerification.evaluate(app: app, manifest: manifest, dmg: dmg, evidence: evidence, profile: nil, command: { _, _ in fatalError("invalid manifest must not run commands") })
        check(invalid?.status == .fail, "changed signed binary returns Fail report without commands")

    }
    static func testNestedSigning(root: URL) throws {
        let app = root.appendingPathComponent("Nested.app"), deep = app.appendingPathComponent("Contents/Frameworks/Inner.framework/Versions/A/Inner"), main = app.appendingPathComponent("Contents/MacOS/FlowType")
        for file in [deep, main] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try Data([0xcf, 0xfa, 0xed, 0xfe, 0]).write(to: file) }
        let identity = "Developer ID Application: Fixture (ABCDEFGHIJ)"
        var calls: [[String]] = []
        try PackagingSigning.sign(app: app, identity: identity) { _, args in calls.append(args) }
        check(calls.first?.last == deep.path && calls.last?.last == app.path, "nested code signed inside out with app last")
        check(calls.count >= 3 && calls.allSatisfy { $0.contains("--timestamp") && $0.contains("runtime") && $0.contains(identity) && !$0.contains("--deep") }, "Developer ID signing uses timestamp and hardened runtime without deep signing")
        for invalid in ["-", "Apple Development: Fixture (ABCDEFGHIJ)", "Developer ID Application: Fake", ""] {
            do { try PackagingSigning.sign(app: app, identity: invalid) { _, _ in check(false, "invalid identity cannot execute signing") }; check(false, "invalid identity rejected") }
            catch { check(true, "invalid identity rejected") }
        }
    }
    static func testCLIOptions() {
        let valid = ["--app", "/fixture/FlowType.app", "--manifest", "/fixture/manifest.json", "--dmg", "/fixture/FlowType.dmg", "--notary-evidence", "/fixture/evidence/notary.json", "--output", "/fixture/report.json"]
        for prefix in [[], ["--distribute"]] {
            do { let options = try DistributionOptions.parse(prefix + valid); check(options.distribute == !prefix.isEmpty && options.output.path == "/fixture/report.json", "distribution CLI parses explicit mode and absolute pairs") }
            catch { check(false, "distribution CLI parses explicit mode and absolute pairs") }
        }
        for args in [Array(valid.dropLast()), valid + ["--app", "/other.app"], valid + ["--unknown", "/other"], ["--app", "relative"] + Array(valid.dropFirst(2)), ["--distribute", "--distribute"] + valid] {
            do { _ = try DistributionOptions.parse(args); check(false, "distribution malformed option rejected") } catch { check(true, "distribution malformed option rejected") }
        }
    }
    static func run() -> Int32 {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/D4-selftest-\(UUID())")
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }; try testDistributionIdentityAndEvidence(root: root); try testNestedSigning(root: root); testCLIOptions() }
        catch { failed += 1; print("FAIL: distribution fixture \(error)") }
        print("Distribution verification self-test: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
