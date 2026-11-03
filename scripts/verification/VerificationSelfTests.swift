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
    static func evidenceFixture() throws -> (URL, URL, VerificationReport, String) {
        let fm = FileManager.default, repo = root.appendingPathComponent("evidence-\(UUID())")
        try fm.createDirectory(at: repo, withIntermediateDirectories: false)
        let run = try VerificationPaths.prepare(repository: repo).appendingPathComponent(UUID().uuidString)
        let child = "children/11111111-1111-4111-8111-111111111111"
        try fm.createDirectory(at: run.appendingPathComponent(child), withIntermediateDirectories: true)
        try Data("synthetic build stdout\n".utf8).write(to: run.appendingPathComponent(child + "/stdout"))
        try Data("synthetic build stderr\n".utf8).write(to: run.appendingPathComponent(child + "/stderr"))
        let diagnostic = child + "/validation-22222222-2222-4222-8222-222222222222/Logs/diagnostic-selftest.log"
        try fm.createDirectory(at: run.appendingPathComponent(diagnostic).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic isolated diagnostic\n".utf8).write(to: run.appendingPathComponent(diagnostic))
        let report = VerificationReport(schemaVersion: 1, runID: run.lastPathComponent, lane: .code, status: .fail,
            sourceIdentity: nil, artifactIdentity: nil, phases: [VerificationPhase(name: "code-full", status: .fail, exitCode: 1,
                evidence: [child + "/stdout", child + "/stderr", child + "/process-result.json"])], manualStatus: .pending, ciStatus: .pending)
        try JSONEncoder().encode(report).write(to: run.appendingPathComponent("verify-report.json"))
        let output = repo.appendingPathComponent("export"); try fm.createDirectory(at: output, withIntermediateDirectories: false)
        return (run, output, report, diagnostic)
    }
    static func testEvidenceAllowlist() throws {
        let fm = FileManager.default
        let (run, output, report, diagnostic) = try evidenceFixture()
        for canary in [".env", "user.sqlite", "weights.bin", "defaults.json", "production.log", "audio.wav"] {
            try Data("synthetic canary".utf8).write(to: run.appendingPathComponent(canary))
        }
        let external = root.appendingPathComponent("external-canary"); try Data("external synthetic".utf8).write(to: external)
        try fm.createSymbolicLink(at: run.appendingPathComponent("external-link"), withDestinationURL: external)
        do {
            let files = try VerificationEvidence.exportAllowlisted(report: report, runRoot: run, destination: output)
            check(Set(files) == Set(["verify-report.json", "children/11111111-1111-4111-8111-111111111111/stdout", "children/11111111-1111-4111-8111-111111111111/stderr", diagnostic]), "allowlist copies only report, streams, isolated diagnostic")
            check(try Data(contentsOf: output.appendingPathComponent(diagnostic)) == Data("synthetic isolated diagnostic\n".utf8), "diagnostic copy preserves synthetic bytes")
        } catch { check(false, "allowlisted failed report exports available evidence") }
        for path in ["../.env", "/tmp/outside", "children/11111111-1111-4111-8111-111111111111/defaults.json", "children/not-a-uuid/stdout", "children/11111111-1111-4111-8111-111111111111/validation-22222222-2222-4222-8222-222222222222/Logs/production.log"] {
            let (owned, out, source, _) = try evidenceFixture()
            var changed = source; changed.phases[0].evidence = [path]
            try JSONEncoder().encode(changed).write(to: owned.appendingPathComponent("verify-report.json"))
            do { _ = try VerificationEvidence.exportAllowlisted(report: changed, runRoot: owned, destination: out); check(false, "unknown or escaped evidence reference rejected") }
            catch { check(true, "unknown or escaped evidence reference rejected") }
            check(try fm.contentsOfDirectory(atPath: out.path).isEmpty, "rejected evidence leaves destination empty")
        }
        for target in ["stream", "diagnostic", "ancestor"] {
            let (owned, out, source, log) = try evidenceFixture()
            let link = owned.appendingPathComponent(target == "stream" ? source.phases[0].evidence[0] : target == "diagnostic" ? log : "children")
            try fm.removeItem(at: link); try fm.createSymbolicLink(at: link, withDestinationURL: target == "ancestor" ? owned.deletingLastPathComponent() : external)
            do { _ = try VerificationEvidence.exportAllowlisted(report: source, runRoot: owned, destination: out); check(false, "allowlisted symlink rejected") }
            catch { check(true, "allowlisted symlink rejected") }
        }
        let (partialRoot, partialOut, older, _) = try evidenceFixture()
        var partial = older; partial.status = .fail
        partial.phases.append(VerificationPhase(name: "report-write", status: .fail, failureCode: .outputUnavailable))
        try JSONEncoder().encode(partial).write(to: partialRoot.appendingPathComponent("verify-report.partial.json"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: partialRoot.appendingPathComponent("verify-report.partial.json").path)
        do {
            let files = try VerificationEvidence.exportRun(runRoot: partialRoot, destination: partialOut)
            check(files.contains("verify-report.partial.json") && !files.contains("verify-report.json"), "genuine Fail partial takes precedence even with older timestamp")
            let decoded = try JSONDecoder().decode(VerificationReport.self, from: Data(contentsOf: partialOut.appendingPathComponent("verify-report.partial.json")))
            check(decoded.phases.last?.name == "report-write", "partial export preserves late failure phase")
        } catch { check(false, "newer partial report exports") }
        let (missingRoot, missingOut, missing, _) = try evidenceFixture()
        try fm.removeItem(at: missingRoot.appendingPathComponent(missing.phases[0].evidence[1]))
        do { let files = try VerificationEvidence.exportRun(runRoot: missingRoot, destination: missingOut); check(files.count == 3, "partial failed run tolerates missing permitted files") }
        catch { check(false, "partial failed run tolerates missing permitted files") }
        let (foreignRoot, foreignOut, foreign, _) = try evidenceFixture()
        var wrong = foreign; wrong.phases[0] = VerificationPhase(name: "unknown-phase", status: .fail)
        try JSONEncoder().encode(wrong).write(to: foreignRoot.appendingPathComponent("verify-report.json"))
        do { _ = try VerificationEvidence.exportRun(runRoot: foreignRoot, destination: foreignOut); check(false, "unknown phase rejected") }
        catch { check(true, "unknown phase rejected") }
        let (bootstrapRoot, bootstrapOut, _, _) = try evidenceFixture()
        try fm.removeItem(at: bootstrapRoot.appendingPathComponent("verify-report.json"))
        try Data("{\"schemaVersion\":1,\"status\":\"Fail\",\"failureCode\":\"bootstrapFailed\"}\n".utf8).write(to: bootstrapRoot.appendingPathComponent("bootstrap-failure.json"))
        try Data("compiler private canary".utf8).write(to: bootstrapRoot.appendingPathComponent("bootstrap-compile.log"))
        do { let files = try VerificationEvidence.exportRun(runRoot: bootstrapRoot, destination: bootstrapOut); check(Set(files) == Set(["bootstrap-failure.json", "bootstrap.stderr"]), "bootstrap export excludes raw compiler output") }
        catch { check(false, "bootstrap export accepts actual wrapper schema") }
        let invalidOut = bootstrapOut.deletingLastPathComponent().appendingPathComponent("invalid-bootstrap-export")
        try fm.createDirectory(at: invalidOut, withIntermediateDirectories: false)
        try Data("{\"schemaVersion\":true,\"status\":\"Fail\",\"failureCode\":\"bootstrapFailed\"}\n".utf8).write(to: bootstrapRoot.appendingPathComponent("bootstrap-failure.json"))
        do { _ = try VerificationEvidence.exportRun(runRoot: bootstrapRoot, destination: invalidOut); check(false, "bootstrap rejects Boolean schema masquerading as integer") }
        catch { check(true, "bootstrap rejects Boolean schema masquerading as integer") }
        let (conflictRoot, conflictOut, original, _) = try evidenceFixture()
        var conflict = original
        conflict = VerificationReport(schemaVersion: 1, runID: original.runID, lane: .artifact, status: .fail, sourceIdentity: nil, artifactIdentity: nil,
            phases: [VerificationPhase(name: "report-write", status: .fail, failureCode: .outputUnavailable)], manualStatus: .pending, ciStatus: .pending)
        try JSONEncoder().encode(conflict).write(to: conflictRoot.appendingPathComponent("verify-report.partial.json"))
        do { _ = try VerificationEvidence.exportRun(runRoot: conflictRoot, destination: conflictOut); check(false, "partial conflicts with original lane are rejected") }
        catch { check(true, "partial conflicts with original lane are rejected") }
    }
    static func testCICapabilityAndUploadContract() {
        check(VerificationCapability.operatingSystem("15.8.2\n") && VerificationCapability.operatingSystem("26.0\n"), "CI supports documented macOS capability")
        check(!VerificationCapability.operatingSystem("14.9\n") && !VerificationCapability.operatingSystem("15oops"), "CI refuses macOS14 and malformed versions")
        check(VerificationCapability.architecture("arm64\n") && !VerificationCapability.architecture("x86_64\n"), "CI refuses Intel capability")
        check(VerificationCapability.swiftVersion("Apple Swift version 6.2.1 (swiftlang-test)\n") && !VerificationCapability.swiftVersion("Apple Swift version 6.1.2\n"), "CI requires actual Swift6.2 capability")
    }
    static func testCIInvocationFallbacks() throws {
        let fm = FileManager.default, scripts = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("scripts")
        for scenario in ["late-write", "bootstrap"] {
            let repo = root.appendingPathComponent("ci-invocation-\(scenario)"), helper = repo.appendingPathComponent("scripts/export-ci-evidence.sh")
            try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: scripts.appendingPathComponent("export-ci-evidence.sh"), to: helper)
            let console = repo.appendingPathComponent("build/ci-verify.stdout")
            try fm.createDirectory(at: console.deletingLastPathComponent(), withIntermediateDirectories: true)
            if scenario == "late-write" {
                var emitted: [String] = [], writer = dependencies("good")
                writer.writeReport = { data, destination in
                    let value = try JSONDecoder().decode(VerificationReport.self, from: data)
                    if value.phases.contains(where: { $0.name == "code-build" && $0.status == .pass }) { throw VerificationFailure.outputUnavailable }
                    try data.write(to: destination, options: .atomic)
                }
                do { _ = try VerificationCLI.verify(VerificationOptions.parse([]), repository: repo, dependencies: writer, announce: { emitted.append($0) }); check(false, "late CLI write must fail") }
                catch { check(true, "late CLI write must fail") }
                check(emitted.count == 1 && emitted[0].hasSuffix("/verify-report.json"), "CLI emits owned path once even on late write failure")
                try Data((emitted.joined(separator: "\n") + "\n").utf8).write(to: console)
                let tool = repo.appendingPathComponent("build/tools/flowtype-verify")
                try fm.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: tool)
            } else {
                let verify = repo.appendingPathComponent("scripts/verify.sh")
                try fm.copyItem(at: scripts.appendingPathComponent("verify.sh"), to: verify)
                let result = try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [verify.path, "--lane", "code"], workingDirectory: repo,
                    environment: ProcessInfo.processInfo.environment, stdoutURL: console, stderrURL: repo.appendingPathComponent("build/ci-verify.stderr"), timeoutSeconds: 30))
                check(result.cliExitCode == 1, "actual copied wrapper compile failure is nonzero")
            }
            let result = try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [helper.path, console.path], workingDirectory: repo,
                environment: ProcessInfo.processInfo.environment, stdoutURL: repo.appendingPathComponent("helper.stdout"), stderrURL: repo.appendingPathComponent("helper.stderr"), timeoutSeconds: 30))
            check(result.cliExitCode == 0, "actual CI helper exports \(scenario) evidence")
            if result.cliExitCode == 0 {
                let destination = repo.appendingPathComponent("build/ci-evidence")
                if scenario == "late-write" {
                    let partial = try JSONDecoder().decode(VerificationReport.self, from: Data(contentsOf: destination.appendingPathComponent("verify-report.partial.json")))
                    check(partial.status == .fail && partial.phases.last?.name == "report-write", "CLI plus helper uploads genuine late partial failure")
                    check(!fm.fileExists(atPath: destination.appendingPathComponent("verify-report.json").path), "CI helper excludes stale full report")
                } else {
                    check(Set(try fm.contentsOfDirectory(atPath: destination.path)) == Set(["bootstrap-failure.json", "bootstrap.stderr"]), "compile-unavailable fallback contains only safe status stderr")
                }
            }
        }
    }
    static func manualObject(app: URL) -> [String: Any] {
        let identity: [String: Any] = ["gitSHA": metadata.gitSHA, "sourceTree": metadata.sourceTree, "binarySHA256": manifest.binarySHA256, "appPath": app.path]
        let rows = ManualCaseID.allCases.map { id -> [String: Any] in
            var row = identity
            row.merge(["id": id.rawValue, "status": "Pass", "testedAt": "2026-11-03T01:02:03Z", "tester": "Synthetic fixture only",
                "environment": ["macOS": "15.8.2", "hardware": "synthetic arm64", "target": "synthetic app1.0"],
                "observation": ["actions": "Synthetic action fixture", "result": "Synthetic expected result", "count": id == .sessions20 ? 20 : 10, "durationMs": 6000], "evidence": ["observation.txt"]]) { _, value in value }
            return row
        }
        return ["schemaVersion": 1, "candidate": identity, "cases": rows]
    }
    static func testManualIdentityAndRequiredCases() throws {
        let fm = FileManager.default, evidence = root.appendingPathComponent("manual fixture")
        try fm.createDirectory(at: evidence, withIntermediateDirectories: false)
        try Data("synthetic observation only".utf8).write(to: evidence.appendingPathComponent("observation.txt"))
        let app = root.appendingPathComponent("fixed/FlowType.app"), source = SourceIdentity(gitSHA: metadata.gitSHA, sourceTree: metadata.sourceTree, dirty: false)
        let good = manualObject(app: app)
        func evaluate(_ object: [String: Any]) -> ManualValidationResult {
            ManualValidation.evaluate(data: try! JSONSerialization.data(withJSONObject: object), manifest: manifest, expectedSourceIdentity: source, expectedAppPath: app, evidenceRoot: evidence)
        }
        check(ManualCaseID.allCases.count == 41, "manual contract contains exactly41 required leaves")
        check(evaluate(good).status == .pass, "synthetic complete manual structure passes only fixture validation")
        let rows = good["cases"] as! [[String: Any]]
        for index in rows.indices {
            var changed = good; var missing = rows; missing.remove(at: index); changed["cases"] = missing
            let result = evaluate(changed)
            check(result.status == .pending && result.cases.contains(where: { $0.id.rawValue == rows[index]["id"] as? String && $0.status == .pending }), "missing required leaf remains visible Pending")
        }
        for key in ["gitSHA", "sourceTree", "binarySHA256", "appPath"] {
            var changed = good, candidate = good["candidate"] as! [String: Any]; candidate[key] = "wrong"; changed["candidate"] = candidate
            check(evaluate(changed).status == .fail, "wrong top candidate identity fails")
            var leaves = rows; leaves[0][key] = "wrong"; changed = good; changed["cases"] = leaves
            check(evaluate(changed).status == .fail, "wrong leaf identity fails")
        }
        for key in ["testedAt", "tester", "environment", "observation", "evidence"] {
            var changed = good, leaves = rows; leaves[0].removeValue(forKey: key); changed["cases"] = leaves
            check(evaluate(changed).status == .fail, "Pass without required details fails")
        }
        for (name, value) in [("testedAt", "2026-11-03T01:02:03+08:00" as Any), ("testedAt", "2026-02-30T00:00:00Z"), ("environment", ["macOS": "", "hardware": "synthetic", "target": "fixture"]), ("observation", ["actions": "", "result": "ok", "count": 1, "durationMs": 1]), ("evidence", ["../observation.txt"]), ("evidence", ["/tmp/outside"]), ("evidence", ["missing.txt"])] {
            var changed = good, leaves = rows; leaves[0][name] = value; changed["cases"] = leaves
            check(evaluate(changed).status == .fail, "malformed Pass detail or escaped evidence fails")
        }
        let linked = evidence.appendingPathComponent("linked.txt"); try fm.createSymbolicLink(at: linked, withDestinationURL: evidence.appendingPathComponent("observation.txt"))
        var changed = good, leaves = rows; leaves[0]["evidence"] = ["linked.txt"]; changed["cases"] = leaves
        check(evaluate(changed).status == .fail, "linked manual evidence fails")
        changed = good; changed["cases"] = rows + [rows[0]]; check(evaluate(changed).status == .fail, "duplicate manual ID fails")
        changed = good; leaves = rows; leaves[0]["id"] = "R1.unknown"; changed["cases"] = leaves; check(evaluate(changed).status == .fail, "unknown manual ID fails")
        changed = good; changed["schemaVersion"] = 0; check(evaluate(changed).status == .fail, "old manual schema fails")
        changed = good; changed["cases"] = [["id": "R1", "status": "Pass"]]; check(evaluate(changed).status == .fail, "parent Pass cannot replace missing leaves")
        for status in ["Fail", "Pending"] {
            changed = good; leaves = rows; leaves[0]["status"] = status; changed["cases"] = leaves
            check(evaluate(changed).status == (status == "Fail" ? .fail : .pending), "any required Fail or Pending prevents Pass")
        }
        let template = try ManualValidation.templateData()
        let pending = ManualValidation.evaluate(data: template, manifest: manifest, expectedSourceIdentity: source, expectedAppPath: app, evidenceRoot: evidence)
        check(pending.status == .pending && pending.cases.count == 41 && pending.cases.allSatisfy { $0.status == .pending }, "empty candidate template remains all41 Pending")
        let decoded = try JSONSerialization.jsonObject(with: template) as? [String: Any]
        check((decoded?["cases"] as? [[String: Any]])?.count == 41 && (decoded?["cases"] as? [[String: Any]])?.allSatisfy { $0["status"] as? String == "Pending" } == true, "written template contains41 actual Pending rows")
        let templateFile = evidence.appendingPathComponent("template.json"); try ManualValidation.writeTemplate(to: templateFile)
        do { try ManualValidation.writeTemplate(to: templateFile); check(false, "manual template refuses existing file") } catch { check(true, "manual template refuses existing file") }
        let ci: [String: Any] = ["schemaVersion": 1, "status": "Pass", "gitSHA": metadata.gitSHA, "sourceTree": metadata.sourceTree, "lane": "code",
            "runURL": "https://github.com/synthetic/repo/actions/runs/123", "evidence": ["https://github.com/synthetic/repo/actions/runs/123/artifacts/456"]]
        func ciStatus(_ object: [String: Any]) -> VerificationStatus { CIValidation.evaluate(data: try! JSONSerialization.data(withJSONObject: object), expectedGitSHA: metadata.gitSHA, expectedSourceTree: metadata.sourceTree) }
        check(ciStatus(ci) == .pass, "synthetic matching remote CI structure passes")
        for (key, value) in [("gitSHA", "old" as Any), ("sourceTree", "old"), ("schemaVersion", 0), ("lane", "artifact"), ("runURL", "file:///tmp/local"), ("evidence", ["local-selftest.stdout"]), ("evidence", [] as [String])] {
            var changed = ci; changed[key] = value; check(ciStatus(changed) == .fail, "old or local CI evidence cannot attest remote Pass")
        }
        check(CIValidation.evaluate(data: nil, expectedGitSHA: metadata.gitSHA, expectedSourceTree: metadata.sourceTree) == .pending, "missing remote CI remains Pending")
        for (index, count) in [(0, 9), (1, 19)] {
            var changed = good, leaves = rows, observation = rows[index]["observation"] as! [String: Any]
            observation["count"] = count; leaves[index]["observation"] = observation; changed["cases"] = leaves
            check(evaluate(changed).status == .fail, "launch/session minimum repeat counts are required")
        }
        check(ManualValidation.evaluate(data: template, manifest: nil, expectedSourceIdentity: source, expectedAppPath: app, evidenceRoot: evidence).status == .pending, "empty Pending template needs no artifact")
        let ciFile = evidence.appendingPathComponent("ci.json"); try JSONSerialization.data(withJSONObject: ci).write(to: ciFile)
        let independent = ManualValidation.evaluate(manualReport: nil, ciReport: ciFile, artifact: nil, expectedSourceIdentity: source, expectedAppPath: app)
        check(independent.0.status == .pending && independent.1 == .pass, "CI identity validation remains independent of artifact availability")
        let repo = root.appendingPathComponent("manual-release-repo")
        try fm.createDirectory(at: repo, withIntermediateDirectories: false)
        let manualFile = repo.appendingPathComponent("manual.json"), remoteFile = repo.appendingPathComponent("ci.json")
        try Data("synthetic release observation".utf8).write(to: repo.appendingPathComponent("observation.txt"))
        try JSONSerialization.data(withJSONObject: manualObject(app: repo.appendingPathComponent("build/FlowType.app"))).write(to: manualFile)
        try JSONSerialization.data(withJSONObject: ci).write(to: remoteFile)
        let output = try VerificationPaths.prepare(repository: repo).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let release = try VerificationRunner.run(lane: .release, repository: repo, output: output, manualReport: manualFile, ciReport: remoteFile, dependencies: dependencies("good"))
        check(release.status == .pass && release.manualStatus == .pass && release.ciStatus == .pass && release.manualCases?.count == 41, "synthetic release requires all technical/manual/CI stages")
        let (oldRoot, oldOut, oldReport, _) = try evidenceFixture()
        var historical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldReport)) as! [String: Any]
        historical.removeValue(forKey: "manualCases"); historical.removeValue(forKey: "manualIssues")
        try JSONSerialization.data(withJSONObject: historical).write(to: oldRoot.appendingPathComponent("verify-report.json"))
        do { let files = try VerificationEvidence.exportRun(runRoot: oldRoot, destination: oldOut); check(files.contains("verify-report.json"), "historical schema1 reports without manual detail remain exportable") }
        catch { check(false, "historical schema1 reports without manual detail remain exportable") }
    }
    static func run() -> Int32 {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("flowtype-verification-\(UUID())")
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            root = try canonicalExisting(root) // macOS /var is an OS alias; owned fixtures use the canonical root.
            fixture = root.appendingPathComponent("fixture-tool"); config = root.appendingPathComponent("metadata.json")
            try JSONEncoder().encode(metadata).write(to: config)
            let source = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("scripts/verification/VerificationFixture.swift")
            let compiled = try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: "/usr/bin/swiftc"), arguments: ["-parse-as-library", source.path, "-o", fixture.path], workingDirectory: root,
                environment: ProcessInfo.processInfo.environment, stdoutURL: root.appendingPathComponent("compile.stdout"), stderrURL: root.appendingPathComponent("compile.stderr"), timeoutSeconds: 30))
            guard compiled.cliExitCode == 0 else { throw VerificationFailure.toolFailed }
            for test in [testExitZeroCannotForgeArtifactPass, testPartialReportAndSkipAggregation, testCheckTimeoutUsesOwnedRecovery, testRecoveryPreservesInUseCandidate, testSourceAndOutputBoundaries, testEvidenceAllowlist, testCIInvocationFallbacks, testManualIdentityAndRequiredCases] {
                do { try test() } catch { failed += 1; print("FAIL: fixture \((error as? VerificationFailure)?.rawValue ?? String((error as NSError).code))") }
            }
            testFullRunnerRequired()
            testCICapabilityAndUploadContract()
        } catch { failed += 1; print("FAIL: fixture setup") }
        print("=== verification self-test: \(passed) passed, \(failed) failed ===")
        if failed == 0 { try? fm.removeItem(at: root) } else { print("Retained synthetic evidence: \(root.path)") }
        return failed == 0 ? 0 : 1
    }
}
