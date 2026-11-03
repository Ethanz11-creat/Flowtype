import Foundation
import Darwin

/// These tests launch only an independent synthetic executable; no product/business/GPU calls.
enum VerificationSelfTests {
    static var passed = 0; static var failed = 0
    static var fixture: URL!; static var root: URL!; static var config: URL!
    static var lastRepository: URL!; static var lastOutput: URL!
    static let metadata = BuildMetadataRecord(schemaVersion: 1, version: "1.0.0", buildNumber: "1", gitSHA: String(repeating: "a", count: 40), sourceTree: String(repeating: "b", count: 40), builtAt: "2026-11-03T00:00:00Z", dirty: false)
    static var manifest: ArtifactManifest { ArtifactManifest(schemaVersion: 1, buildInfo: metadata, architecture: "arm64", binarySHA256: String(repeating: "d", count: 64), buildInfoSHA256: String(repeating: "e", count: 64), shaderSHA256: String(repeating: "c", count: 64), resources: []) }
    static func check(_ value: Bool, _ name: String) { if value { passed += 1 } else { failed += 1; print("FAIL: \(name)") } }
    static func object(mode: String = "smoke") -> [String: Any] {
        var value: [String: Any] = ["schemaVersion": 1, "mode": mode, "ok": true, "role": "smokeTest", "runID": UUID().uuidString, "durationMs": 6001, "failureCode": NSNull(),
            "buildInfo": ["origin": "packaged", "metadata": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)), "failureCode": NSNull()]]
        if mode == "artifact" { value.merge(["appResources": true, "metalLibrary": true, "mlxOperation": true, "resolvedInsideApp": true]) { _, new in new } }
        else { value.merge(["readiness": "blocked", "ax": "denied", "mic": "notDetermined", "speech": "denied", "probeTimerTicks": 1, "windowHealthTicks": 1, "tap": "disabledForValidation"]) { _, new in new } }
        return value
    }
    static func bytes(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) + Data("\n".utf8) }
    static func testExitZeroCannotForgeArtifactPass() throws {
        var cases: [(String, Data, String)] = []
        let good = object()
        for (key, value) in [("mode", "artifact" as Any), ("role", "app"), ("durationMs", 5900), ("probeTimerTicks", 0), ("windowHealthTicks", 0),
                             ("tap", "enabled"), ("schemaVersion", true), ("ok", 1), ("probeTimerTicks", true)] {
            var changed = good; changed[key] = value; cases.append((key, bytes(changed), "smoke"))
        }
        var missing = good; missing.removeValue(forKey: "mic"); cases.append(("missing", bytes(missing), "smoke"))
        var identity = good["buildInfo"] as! [String: Any]
        var old = identity["metadata"] as! [String: Any]; old["gitSHA"] = String(repeating: "f", count: 40); identity["metadata"] = old
        var changed = good; changed["buildInfo"] = identity; cases.append(("old SHA", bytes(changed), "smoke"))
        cases.append(("multiple JSON", bytes(good) + bytes(good), "smoke"))
        var artifact = object(mode: "artifact"); artifact["mlxOperation"] = false; cases.append(("Metal true MLX false", bytes(artifact), "artifact"))
        for (name, data, mode) in cases {
            var seen: Set<String> = []
            do { _ = try VerificationValidation.runtime(data, mode: mode, manifest: manifest, exit: 0, seen: &seen); check(false, "reject forged \(name)") }
            catch { check(true, "reject forged \(name)") }
        }
        var seen: Set<String> = []
        _ = try VerificationValidation.runtime(bytes(good), mode: "smoke", manifest: manifest, exit: 0, seen: &seen)
        do { _ = try VerificationValidation.runtime(bytes(good), mode: "smoke", manifest: manifest, exit: 0, seen: &seen); check(false, "duplicate runtime runID") }
        catch { check(true, "duplicate runtime runID") }
        let output = root.appendingPathComponent("old-hash-check"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try bytes(object(mode: "artifact")).write(to: output.appendingPathComponent("artifact.stdout"))
        let badHash: [String: Any] = ["schemaVersion": 1, "ok": true, "failureCode": NSNull(), "signature": true, "resourcesHidden": true, "resourcesRestored": true,
            "hashesBefore": ["binary": "old", "metadata": "old", "shader": "old"], "hashesAfter": ["binary": "old", "metadata": "old", "shader": "old"], "sourceCommit": metadata.gitSHA, "artifact": object(mode: "artifact")]
        try JSONSerialization.data(withJSONObject: badHash).write(to: output.appendingPathComponent("check-result.json"))
        do { try VerificationValidation.check(output, manifest: manifest, seen: &seen); check(false, "old copied hash cannot pass") }
        catch { check(true, "old copied hash cannot pass") }
    }
    static func testFullRunnerRequired() {
        for value in ["=== M5 runtime self-test: 12 passed, 0 failed ===\n", "=== self-test: 0 passed, 0 failed ===\n", "=== self-test: 4 passed, 1 failed ===\n", "finished\n", "=== self-test: 4 passed, 0 failed ===\n=== self-test: 4 passed, 0 failed ===\n"] {
            check(!VerificationValidation.fullSummary(Data(value.utf8)), "full summary cannot be forged")
        }
        check(VerificationValidation.fullSummary(Data("=== FlowType --self-test ===\n=== self-test: 42 passed, 0 failed ===\n".utf8)), "accept actual full summary")
    }
    static func dependencies(_ scenario: String, recovery: @escaping () -> Void = {}) -> VerificationDependencies {
        var snapshots = 0
        return VerificationDependencies(execute: { request in
            let command = request.command
            let timeout = scenario == "full-timeout" && request.phase == "code-full" ? 0.1 : 15.0
            let actual = try BoundedProcess.run(BoundedCommand(executable: fixture,
                arguments: [request.phase, scenario, config.path, request.checkOutput.path] + command.arguments,
                workingDirectory: command.workingDirectory, environment: command.environment, stdoutURL: command.stdoutURL, stderrURL: command.stderrURL, timeoutSeconds: timeout))
            if request.phase.hasPrefix("smoke-"), scenario != "instant-duration", actual.termination == .normal {
                return BoundedResult(schemaVersion: 1, exitCode: actual.exitCode, termination: actual.termination, durationMs: 6100, timedOut: actual.timedOut, failureCode: actual.failureCode)
            }
            return actual
        }, snapshot: { _, _ in
            snapshots += 1
            let sha = scenario == "source-change" && snapshots > 1 ? String(repeating: "f", count: 40) : metadata.gitSHA
            return SourceSnapshot(identity: SourceIdentity(gitSHA: sha, sourceTree: metadata.sourceTree, dirty: false), fingerprint: sha, shallow: false)
        }, manifest: { _ in manifest }, recover: { _ in recovery() }, ciCode: false)
    }
    static func runFixture(_ scenario: String, lane: VerificationLane, recovery: @escaping () -> Void = {}) throws -> VerificationReport {
        let repo = root.appendingPathComponent("仓库 with spaces ; literal $(touch sentinel)-\(UUID())")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let output = try VerificationPaths.prepare(repository: repo).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        lastRepository = repo; lastOutput = output
        return try VerificationRunner.run(lane: lane, repository: repo, output: output, manualReport: nil, ciReport: nil, dependencies: dependencies(scenario, recovery: recovery))
    }
    static func testPartialReportAndSkipAggregation() throws {
        let code = try runFixture("good", lane: .code)
        check(code.status == .pass && code.phases.contains(where: { $0.name == "code-full" && $0.status == .pass }), "code executes full")
        check(!code.phases.contains(where: { $0.name == "artifact-build" }), "code never builds app")
        let full = code.phases.first { $0.name == "code-full" }!
        let argvFile = lastOutput.appendingPathComponent(full.evidence[0]).deletingLastPathComponent().appendingPathComponent("argv.json")
        let argv = try JSONDecoder().decode([String].self, from: Data(contentsOf: argvFile))
        check(argv.count == 3 && argv[0] == "--self-test" && argv[1] == "--validation-root" && argv[2].contains("仓库 with spaces ; literal $(touch sentinel)"), "Unicode and shell syntax preserved as literal argv")
        let childIDs = code.phases.flatMap(\.evidence).filter { $0.hasSuffix("/stdout") }.map { $0.split(separator: "/")[1] }
        check(Set(childIDs).count == childIDs.count, "every child has a fresh evidence root")
        for scenario in ["build-fail", "full-timeout", "focused", "no-summary", "source-change"] {
            let report = try runFixture(scenario, lane: .code)
            check(report.status == .fail && report.exitCode == 1, "partial fail \(scenario)")
            if scenario == "build-fail" { check(report.phases.contains(where: { $0.name == "code-full" && $0.status == .pending }), "failed build leaves full pending") }
            if scenario == "full-timeout" { check(report.phases.contains(where: { $0.name == "code-full" && $0.timedOut }), "record full actual timeout") }
        }
        let signature = try runFixture("signature-fail", lane: .artifact)
        check(signature.status == .fail && signature.phases.contains(where: { $0.name == "artifact-check" && $0.status == .pending }), "bad signature blocks check")
        let skipped = try runFixture("skip", lane: .artifact)
        check(skipped.status != .pass && skipped.exitCode == 2, "WindowServer Skip never overall Pass")
        let crashed = try runFixture("seventh-crash", lane: .artifact)
        check(crashed.status == .fail && crashed.phases.contains(where: { $0.name == "smoke-07" && $0.status == .fail }), "seventh crash retained")
        for scenario in ["instant-duration", "inflated-duration"] {
            let report = try runFixture(scenario, lane: .artifact)
            check(report.status == .fail && report.phases.contains(where: { $0.name == "smoke-01" && $0.status == .fail }), "external duration rejects \(scenario)")
        }
        let release = try runFixture("good", lane: .release)
        check(release.status == .pending && release.exitCode == 2 && release.manualStatus == .pending && release.ciStatus == .pending, "manual CI stubs cannot attest release")
        check(release.phases.filter { $0.name == "code-build" }.count == 1 && release.phases.filter { $0.name == "artifact-build" }.count == 1, "release stages run once")
        var recovered = 0
        _ = try runFixture("build-fail", lane: .artifact, recovery: { recovered += 1 })
        check(recovered >= 2, "owned recovery before and after failed packaging")
        let repo = root.appendingPathComponent("write-failure-repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let out = try VerificationPaths.prepare(repository: repo).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        var writer = dependencies("good")
        writer.writeReport = { data, destination in
            let report = try JSONDecoder().decode(VerificationReport.self, from: data)
            if report.phases.contains(where: { $0.name == "code-build" && $0.status == .pass }) { throw VerificationFailure.outputUnavailable }
            try data.write(to: destination, options: .atomic)
        }
        do { _ = try VerificationRunner.run(lane: .code, repository: repo, output: out, manualReport: nil, ciReport: nil, dependencies: writer); check(false, "parent write failure cannot pass") }
        catch { check(true, "parent write failure cannot pass") }
        let partial = try JSONDecoder().decode(VerificationReport.self, from: Data(contentsOf: out.appendingPathComponent("verify-report.partial.json")))
        check(partial.status == .fail && partial.phases.contains(where: { $0.name == "code-build" && $0.status == .pass }) && partial.phases.contains(where: { $0.name == "code-full" && $0.status == .pending }), "late write failure preserves completed phase and pending dependency")
    }
    static func testCheckTimeoutUsesOwnedRecovery() throws {
        let fm = FileManager.default, repo = root.appendingPathComponent("check-timeout-repo")
        let bin = repo.appendingPathComponent(".build/synthetic/release")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let original = bin.appendingPathComponent("Fixture.bundle")
        try fm.createDirectory(at: original, withIntermediateDirectories: false)
        let payload = Data("owned synthetic resource".utf8)
        try payload.write(to: original.appendingPathComponent("payload"))
        let expected = try packagingFingerprint(original), token = UUID().uuidString
        let hidden = bin.appendingPathComponent(".m5-hidden-\(token)-Fixture.bundle")
        let out = try VerificationPaths.prepare(repository: repo).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: out, withIntermediateDirectories: false)
        let marker = repo.appendingPathComponent("build/.m5-resources.json"), base = dependencies("good")
        let injected = VerificationDependencies(execute: { request in
            guard request.phase == "artifact-check" else { return try base.execute(request) }
            try fm.moveItem(at: original, to: hidden)
            let command = request.command
            return try BoundedProcess.run(BoundedCommand(executable: fixture,
                arguments: [request.phase, "check-timeout", config.path, request.checkOutput.path] + command.arguments,
                workingDirectory: command.workingDirectory, environment: command.environment,
                stdoutURL: command.stdoutURL, stderrURL: command.stderrURL, timeoutSeconds: 0.1), onLaunch: { pid in
                    let journal = HidingJournal(token: token, releaseDirectory: bin.path, ownerPID: getpid(), innerPID: pid,
                        resources: [HiddenResource(name: "Fixture.bundle", fingerprint: expected)])
                    try JSONEncoder().encode(journal).write(to: marker, options: .atomic)
                })
        }, snapshot: base.snapshot, manifest: base.manifest, recover: { try ArtifactPackager.recoverOwned(repository: $0) }, ciCode: false)
        let report = try VerificationRunner.run(lane: .artifact, repository: repo, output: out, manualReport: nil, ciReport: nil, dependencies: injected)
        check(report.status == .fail && report.phases.contains(where: { $0.name == "artifact-check" && $0.timedOut }), "actual check timeout cannot pass")
        check(report.phases.contains(where: { $0.name == "artifact-recovery-after" && $0.status == .pass }), "check timeout runs actual owned recovery core")
        check(try packagingFingerprint(original) == expected && Data(contentsOf: original.appendingPathComponent("payload")) == payload,
            "check timeout restores exact synthetic resource bytes")
        check(!fm.fileExists(atPath: hidden.path) && !fm.fileExists(atPath: marker.path), "check timeout leaves no hidden resource or marker")
        check(report.phases.filter { $0.name.hasPrefix("smoke-") }.allSatisfy { $0.status == .pending }, "check timeout blocks dependent smoke")
    }
    static func testRecoveryPreservesInUseCandidate() throws {
        for active in ["current", "backup", "none", "live"] {
        let repo = root.appendingPathComponent("recovery in use-\(active)"), build = repo.appendingPathComponent("build")
        let fm = FileManager.default, token = UUID().uuidString
        let app = build.appendingPathComponent("FlowType.app"), backup = build.appendingPathComponent(".m5-backup-\(token).app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true); try fm.createDirectory(at: backup.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("running candidate".utf8).write(to: app.appendingPathComponent("Contents/MacOS/FlowType")); try Data("old candidate".utf8).write(to: backup.appendingPathComponent("Contents/MacOS/FlowType"))
        let current = try packagingFingerprint(app), old = try packagingFingerprint(backup)
        let manifestURL = build.appendingPathComponent("FlowType.manifest.json"); try Data("manifest".utf8).write(to: manifestURL)
        let journal = try PublicationJournal(token: token, committed: false, oldApp: old, oldManifest: packagingFingerprint(manifestURL), newApp: current, newManifest: "unused")
        try JSONEncoder().encode(journal).write(to: build.appendingPathComponent(".m5-publication.json"))
        var calls: [URL] = []
        let adapters = PackagingAdapters(releaseBuild: { _, _ in throw PackagingFailure.toolFailed }, releaseDirectory: { _, _ in throw PackagingFailure.toolFailed },
            generateIdentity: { _, _, _, _ in throw PackagingFailure.toolFailed }, writeManifest: { _, _, _ in throw PackagingFailure.toolFailed },
            sign: { _, _ in throw PackagingFailure.toolFailed }, verify: { _, _ in throw PackagingFailure.toolFailed }, inUse: { url, _ in
                calls.append(url)
                return active == "current" && url.lastPathComponent == "FlowType.app" || active == "backup" && url.lastPathComponent.hasPrefix(".m5-backup-")
            }, artifact: { _, _, _, _ in throw PackagingFailure.toolFailed })
        if active == "current" || active == "backup" {
            do { try ArtifactPackager(repo: repo, adapters: adapters).recover(); check(false, "in-use recovery refuses mutation") }
            catch { check((error as? PackagingFailure) == .inUse, "in-use recovery refuses mutation") }
            let expected = try canonicalExisting(active == "current" ? app : backup).path
            check(calls.contains(where: { (try? canonicalExisting($0).path) == expected }), "recovery invokes correct downstream in-use guard")
            check(try packagingFingerprint(app) == current && packagingFingerprint(backup) == old, "running candidate and old backup retained")
        } else {
            if active == "live" { try ArtifactPackager.recoverOwned(repository: repo) }
            else { try ArtifactPackager(repo: repo, adapters: adapters).recover() }
            check(try packagingFingerprint(app) == old, "legal recovery succeeds with real recovery integration")
            check(!fm.fileExists(atPath: backup.path), "legal recovery completes backup ownership")
        }
        }
    }
    static func testSourceAndOutputBoundaries() throws {
        let fm = FileManager.default, repo = root.appendingPathComponent("snapshot repo"), logs = root.appendingPathComponent("snapshot logs")
        try fm.createDirectory(at: repo.appendingPathComponent("Sources/subdir"), withIntermediateDirectories: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: false)
        let source = repo.appendingPathComponent("Sources/subdir/main.swift")
        try Data("tracked source".utf8).write(to: source)
        for args in [["init", "--quiet"], ["add", "."], ["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "commit", "--quiet", "-m", "fixture"]] { _ = try packagingGit(args, repo: repo, logs: logs) }
        let env = repo.appendingPathComponent(".env"); try Data("synthetic one".utf8).write(to: env)
        let capture = VerificationDependencies.live().snapshot
        let first = try capture(repo, logs)
        try Data("synthetic two".utf8).write(to: env)
        let second = try capture(repo, logs)
        check(first == second && first.identity.dirty, "untracked config content is excluded from fingerprint")
        try Data("changed tracked source".utf8).write(to: source)
        check(try capture(repo, logs).fingerprint != second.fingerprint, "tracked source mutation changes fingerprint")
        let outside = root.appendingPathComponent("outside source"); try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("foreign synthetic".utf8).write(to: outside.appendingPathComponent("main.swift"))
        try fm.removeItem(at: source.deletingLastPathComponent()); try fm.createSymbolicLink(at: source.deletingLastPathComponent(), withDestinationURL: outside)
        do { _ = try capture(repo, logs); check(false, "ancestor source symlink rejected") } catch { check(true, "ancestor source symlink rejected") }
        for component in ["build", "verification"] {
            let candidate = root.appendingPathComponent("escape-\(component)")
            try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
            let target = root.appendingPathComponent("external-\(component)"); try fm.createDirectory(at: target, withIntermediateDirectories: false)
            let link: URL
            if component == "build" { link = candidate.appendingPathComponent("build") }
            else { try fm.createDirectory(at: candidate.appendingPathComponent("build"), withIntermediateDirectories: false); link = candidate.appendingPathComponent("build/verification") }
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
            do { _ = try VerificationPaths.prepare(repository: candidate); check(false, "evidence ancestor escape rejected") } catch { check(true, "evidence ancestor escape rejected") }
            check(try fm.contentsOfDirectory(atPath: target.path).isEmpty, "external evidence directory untouched")
        }
        for args in [["--lane", "code", "--lane", "release"], ["--unknown", "value"], ["--lane", "bogus"], ["--lane"], ["--run-id", UUID().uuidString], ["--self-test", "--lane", "release"]] {
            do { _ = try VerificationOptions.parse(args); check(false, "invalid verifier argv rejected") } catch { check((error as? VerificationFailure) == .usage, "invalid verifier argv rejected") }
        }
        check(try VerificationOptions.parse([]).lane == .code, "default verifier lane is code")
    }
    static func run() -> Int32 {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("flowtype-verification-\(UUID())")
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            fixture = root.appendingPathComponent("fixture-tool"); config = root.appendingPathComponent("metadata.json")
            try JSONEncoder().encode(metadata).write(to: config)
            let source = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("scripts/verification/VerificationFixture.swift")
            let compiled = try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: "/usr/bin/swiftc"), arguments: ["-parse-as-library", source.path, "-o", fixture.path], workingDirectory: root,
                environment: ProcessInfo.processInfo.environment, stdoutURL: root.appendingPathComponent("compile.stdout"), stderrURL: root.appendingPathComponent("compile.stderr"), timeoutSeconds: 30))
            guard compiled.cliExitCode == 0 else { throw VerificationFailure.toolFailed }
            for test in [testExitZeroCannotForgeArtifactPass, testPartialReportAndSkipAggregation, testCheckTimeoutUsesOwnedRecovery, testRecoveryPreservesInUseCandidate, testSourceAndOutputBoundaries] {
                do { try test() } catch { failed += 1; print("FAIL: fixture \((error as? VerificationFailure)?.rawValue ?? String((error as NSError).code))") }
            }
            testFullRunnerRequired()
        } catch { failed += 1; print("FAIL: fixture setup") }
        print("=== verification self-test: \(passed) passed, \(failed) failed ===")
        if failed == 0 { try? fm.removeItem(at: root) } else { print("Retained synthetic evidence: \(root.path)") }
        return failed == 0 ? 0 : 1
    }
}
