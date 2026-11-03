import Foundation
import Darwin

@main enum ArtifactPackagingSelfTests {
    static var passed = 0; static var failed = 0
    static func check(_ value: Bool, _ name: String) {
        if value { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    static func run(_ executable: String, _ arguments: [String], cwd: URL, logs: URL, timeout: Double = 30) throws -> BoundedResult {
        let id = UUID().uuidString
        return try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: executable), arguments: arguments, workingDirectory: cwd,
            environment: ProcessInfo.processInfo.environment, stdoutURL: logs.appendingPathComponent(id + ".out"), stderrURL: logs.appendingPathComponent(id + ".err"), timeoutSeconds: timeout))
    }
    static func fixture(_ body: (URL, URL, URL, URL) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("m5 packaging \(UUID())")
        let repo = root.appendingPathComponent("repo with spaces")
        let bin = repo.appendingPathComponent(".build/arm64-apple-macosx/release")
        let build = repo.appendingPathComponent("build")
        try fm.createDirectory(at: bin.appendingPathComponent("FlowType_FlowType.bundle"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: build.appendingPathComponent("FlowType.app/Contents/MacOS"), withIntermediateDirectories: true)
        var completed = false
        defer { if completed { try? fm.removeItem(at: root) } else { print("Retained synthetic fixture: \(root.path)") } }
        try Data("old binary".utf8).write(to: build.appendingPathComponent("FlowType.app/Contents/MacOS/FlowType"))
        try Data("old manifest".utf8).write(to: build.appendingPathComponent("FlowType.manifest.json"))
        try Data("new binary".utf8).write(to: bin.appendingPathComponent("FlowType"))
        try Data("resource".utf8).write(to: bin.appendingPathComponent("FlowType_FlowType.bundle/resource"))
        try Data("source".utf8).write(to: repo.appendingPathComponent("Sources/main.swift"))
        try Data("build/\n.build/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        for args in [["init", "--quiet"], ["add", "."], ["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "commit", "--quiet", "-m", "fixture"]] {
            guard try run("/usr/bin/git", args, cwd: repo, logs: root).cliExitCode == 0 else { throw PackagingFailure.toolFailed }
        }
        var data = Data("MTLB".utf8); data.append(Data(repeating: 0, count: 1_048_576 - 4))
        let shader = root.appendingPathComponent("local shader.metallib"); try data.write(to: shader)
        try body(repo, bin, shader, root)
        completed = true
    }
    static func adapters(repo: URL, bin: URL, root: URL, scenario: String = "good") -> PackagingAdapters {
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return PackagingAdapters(releaseBuild: { _, _ in
            if scenario == "build" { throw PackagingFailure.buildFailed }
            if scenario == "HEAD" {
                _ = try run("/usr/bin/git", ["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "commit", "--allow-empty", "--quiet", "-m", "changed"], cwd: repo, logs: root)
            }
            return bin
        }, releaseDirectory: { _, _ in bin }, generateIdentity: { repo, out, version, logs in
            let r = try run("/usr/bin/swift", [source.appendingPathComponent("scripts/generate-build-info.swift").path, "--repo", repo.path, "--output", out.path, "--version", version], cwd: repo, logs: logs)
            guard r.cliExitCode == 0 else { throw PackagingFailure.sourceInvalid }
        }, writeManifest: { app, output, logs in
            let r = try run("/usr/bin/swift", [source.appendingPathComponent("scripts/write-artifact-manifest.swift").path, "--app", app.path, "--output", output.path], cwd: root, logs: logs)
            guard r.cliExitCode == 0 else { throw PackagingFailure.manifestInvalid }
        }, sign: { app, _ in
            if scenario == "sign" { throw PackagingFailure.signFailed }
            let file = app.appendingPathComponent("Contents/MacOS/FlowType")
            var data = try Data(contentsOf: file); data.append(Data(" signed".utf8)); try data.write(to: file)
        }, verify: { _, _ in }, inUse: { _, _ in scenario == "inUse" }, artifact: { app, validation, logs, launched in
            let result = try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
                arguments: ["--fixture-artifact", scenario, app.path], workingDirectory: root,
                environment: ProcessInfo.processInfo.environment, stdoutURL: logs.appendingPathComponent("artifact.stdout"),
                stderrURL: logs.appendingPathComponent("artifact.stderr"), timeoutSeconds: scenario == "timeout" ? 0.15 : 3),
                shouldCancel: { packagingCancellation.isCancelled() }, onLaunch: launched)
            _ = validation
            return result
        })
    }
    static func testStagingFailurePreservesCandidate() throws {
        for scenario in ["missing", "short", "invalid", "build", "sign", "HEAD", "inUse"] {
            try fixture { repo, bin, shader, root in
                if scenario == "short" { try Data("MTLB".utf8).write(to: shader) }
                if scenario == "invalid" { try Data(repeating: 1, count: 1_048_576).write(to: shader) }
                let final = repo.appendingPathComponent("build/FlowType.app")
                let manifest = repo.appendingPathComponent("build/FlowType.manifest.json")
                let before = try packagingFingerprint(final); let oldManifest = try packagingHash(manifest)
                let packager = ArtifactPackager(repo: repo, adapters: adapters(repo: repo, bin: bin, root: root, scenario: scenario))
                do { try packager.buildApp(shader: scenario == "missing" ? nil : shader, version: "1.2.3"); check(false, "reject \(scenario)") }
                catch {
                    let expected: PackagingFailure = ["missing", "short", "invalid"].contains(scenario) ? .shaderInvalid :
                        scenario == "build" ? .buildFailed : scenario == "sign" ? .signFailed : scenario == "inUse" ? .inUse : .sourceInvalid
                    check((error as? PackagingFailure) == expected, "reject correct stage \(scenario)")
                }
                check(try packagingFingerprint(final) == before, "preserve candidate after \(scenario)")
                check(try packagingHash(manifest) == oldManifest, "preserve manifest after \(scenario)")
                if ["build", "sign", "HEAD"].contains(scenario) {
                    let stages = try FileManager.default.contentsOfDirectory(at: repo.appendingPathComponent("build"), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".m5-stage-") }
                    check(stages.count == 1 && FileManager.default.fileExists(atPath: stages[0].appendingPathComponent(".owner").path), "failed staging retained for diagnosis")
                }
            }
        }
    }
    static func testManifestAndRestore() throws {
        for scenario in ["good", "artifact", "timeout", "schemaBool", "stageInt"] {
            try fixture { repo, bin, shader, root in
                let packager = ArtifactPackager(repo: repo, adapters: adapters(repo: repo, bin: bin, root: root, scenario: scenario))
                try packager.buildApp(shader: shader, version: "1.2.3")
                let app = repo.appendingPathComponent("build/FlowType.app")
                guard let manifest = try? JSONDecoder().decode(PackagingManifest.self, from: Data(contentsOf: repo.appendingPathComponent("build/FlowType.manifest.json"))) else {
                    check(false, "build emits a parseable manifest"); return
                }
                check(try manifest.binarySHA256 == packagingHash(app.appendingPathComponent("Contents/MacOS/FlowType")), "manifest uses post-sign bytes")
                check(try manifest.shaderSHA256 == packagingHash(shader), "manifest shader bytes match copied source")
                let independent = try packagingCommand("/usr/bin/shasum", ["-a", "256", app.appendingPathComponent("Contents/MacOS/FlowType").path], cwd: root, logs: root)
                check(independent.0.cliExitCode == 0 && String(decoding: independent.1, as: UTF8.self).hasPrefix(manifest.binarySHA256 + " "), "manifest matches independent SHA256 of signed binary")
                check(manifest.architecture == "arm64" && manifest.buildInfo.version == "1.2.3", "manifest schema identity")
                for row in manifest.resources {
                    check(row.path.hasPrefix("Contents/Resources/"), "manifest relative resource path")
                    check(try row.sha256 == packagingHash(app.appendingPathComponent(row.path)), "manifest resource digest \(row.path)")
                }
                let before = try packagingFingerprint(bin.appendingPathComponent("FlowType_FlowType.bundle"))
                let output = root.appendingPathComponent("check output"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                do { try packager.checkApp(app: app, output: output); check(scenario == "good", "artifact failure gate") }
                catch { check(scenario != "good" && (error as? PackagingFailure) == .artifactFailed, "artifact failure gate") }
                check(FileManager.default.fileExists(atPath: bin.appendingPathComponent("FlowType_FlowType.bundle").path), "restore bundle after \(scenario)")
                if FileManager.default.fileExists(atPath: bin.appendingPathComponent("FlowType_FlowType.bundle").path) {
                    check(try packagingFingerprint(bin.appendingPathComponent("FlowType_FlowType.bundle")) == before, "restore exact resource bytes")
                }
            }
        }
    }
    static func testRestoreOnArtifactFailure() throws {
        for scenario in ["artifact", "timeout"] {
            try fixture { repo, bin, shader, root in
                try ArtifactPackager(repo: repo, adapters: adapters(repo: repo, bin: bin, root: root)).buildApp(shader: shader, version: "1.2.3")
                let packager = ArtifactPackager(repo: repo, adapters: adapters(repo: repo, bin: bin, root: root, scenario: scenario))
                let output = root.appendingPathComponent("restore output")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                do { try packager.checkApp(app: repo.appendingPathComponent("build/FlowType.app"), output: output); check(false, "reject artifact \(scenario)") }
                catch { check(true, "reject artifact \(scenario)") }
                check(FileManager.default.fileExists(atPath: bin.appendingPathComponent("FlowType_FlowType.bundle/resource").path), "restore owned resources after \(scenario)")
            }
        }
    }
    static func testRecoveryAndConflicts() throws {
        try fixture { repo, bin, _, root in
            let fm = FileManager.default
            let packager = ArtifactPackager(repo: repo, adapters: adapters(repo: repo, bin: bin, root: root))
            let original = bin.appendingPathComponent("FlowType_FlowType.bundle")
            let before = try packagingFingerprint(original)
            // A real killed child leaves its marker and hidden files for the next invocation.
            let killed = try run(CommandLine.arguments[0], ["--fixture-abandon", repo.path, bin.path], cwd: root, logs: root)
            check(killed.termination == .signal, "abandoned fixture actually killed")
            try packager.recover()
            check(try packagingFingerprint(original) == before, "recover exact owned bytes after SIGKILL")
            check(!packager.exists(packager.hidingURL), "successful recovery removes marker")
            let token = UUID().uuidString
            let hidden = bin.appendingPathComponent(".m5-hidden-\(token)-FlowType_FlowType.bundle")
            let marker = HidingJournal(token: token, releaseDirectory: bin.path, ownerPID: getpid(), innerPID: nil,
                resources: [HiddenResource(name: "FlowType_FlowType.bundle", fingerprint: before)])
            try fm.moveItem(at: original, to: hidden); try packager.write(marker, to: packager.hidingURL)
            try fm.createDirectory(at: original, withIntermediateDirectories: false)
            try Data("unknown".utf8).write(to: original.appendingPathComponent("unknown"))
            do { try packager.recover(); check(false, "conflicting original fails") } catch { check(true, "conflicting original fails") }
            check(try Data(contentsOf: original.appendingPathComponent("unknown")) == Data("unknown".utf8), "recovery never overwrites unknown original")
            check(try packagingFingerprint(hidden) == before, "conflict retains owned backup")
            try fm.removeItem(at: original)
            var active = marker; active.innerPID = getpid(); try packager.write(active, to: packager.hidingURL)
            do { try packager.recover(); check(false, "active inner ownership fails") } catch { check(true, "active inner ownership fails") }
            check(packager.exists(hidden), "live-group conflict preserves hidden resources")
            try packager.write(marker, to: packager.hidingURL); try packager.recover()
            check(try packagingFingerprint(original) == before, "recover once conflict resolved")
            let lock = try PackagingLock(packager.build)
            do { _ = try PackagingLock(packager.build); check(false, "exclusive writer lock") } catch { check(true, "exclusive writer lock") }
            withExtendedLifetime(lock) {}
        }
        try fixture { repo, bin, _, root in
            let fm = FileManager.default
            let packager = ArtifactPackager(repo: repo, adapters: adapters(repo: repo, bin: bin, root: root))
            let token = UUID().uuidString
            let app = packager.build.appendingPathComponent("FlowType.app")
            let manifest = packager.build.appendingPathComponent("FlowType.manifest.json")
            let oldApp = try packagingFingerprint(app), oldManifest = try packagingFingerprint(manifest)
            try fm.moveItem(at: app, to: packager.build.appendingPathComponent(".m5-backup-\(token).app"))
            try fm.moveItem(at: manifest, to: packager.build.appendingPathComponent(".m5-backup-\(token).manifest.json"))
            try fm.createDirectory(at: app, withIntermediateDirectories: false)
            try Data("new".utf8).write(to: app.appendingPathComponent("new"))
            try Data("new manifest".utf8).write(to: manifest)
            let j = try PublicationJournal(token: token, committed: false, oldApp: oldApp, oldManifest: oldManifest,
                newApp: packagingFingerprint(app), newManifest: packagingFingerprint(manifest))
            try packager.write(j, to: packager.publicationURL)
            try packager.recover()
            check(try packagingFingerprint(app) == oldApp, "recover interrupted candidate rename")
            check(try packagingFingerprint(manifest) == oldManifest, "recover matching old manifest")
            check(!packager.exists(packager.publicationURL), "publication recovery removes journal")
            check(packager.exists(packager.stage(token).appendingPathComponent("FlowType.app/new")), "rollback retains failed new candidate for diagnosis")
        }
    }
    static func testExternalBuildAndTerm() throws {
        try fixture { repo, bin, shader, root in
            let fm = FileManager.default
            let packager = ArtifactPackager(repo: repo, adapters: adapters(repo: repo, bin: bin, root: root))
            try packager.buildApp(shader: shader, version: "1.2.3")
            let external = root.appendingPathComponent("external build")
            try fm.moveItem(at: repo.appendingPathComponent(".build"), to: external)
            try fm.createSymbolicLink(at: repo.appendingPathComponent(".build"), withDestinationURL: external)
            let original = external.appendingPathComponent("arm64-apple-macosx/release/FlowType_FlowType.bundle")
            let before = try packagingFingerprint(original)
            let output = root.appendingPathComponent("external output"); try fm.createDirectory(at: output, withIntermediateDirectories: false)
            do { try packager.checkApp(app: repo.appendingPathComponent("build/FlowType.app"), output: output); check(false, "reject external .build") }
            catch { check((error as? PackagingFailure) == .journalInvalid, "reject external .build") }
            check(try packagingFingerprint(original) == before, "external worktree resources never moved")
        }
        try fixture { repo, bin, shader, root in
            let packager = ArtifactPackager(repo: repo, adapters: adapters(repo: repo, bin: bin, root: root))
            try packager.buildApp(shader: shader, version: "1.2.3")
            let output = root.appendingPathComponent("term output"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            var owner: Int32 = 0; var sent = false
            let result = try BoundedProcess.run(BoundedCommand(executable: URL(fileURLWithPath: CommandLine.arguments[0]), arguments: ["--fixture-term", repo.path, bin.path, root.path, output.path],
                workingDirectory: root, environment: ProcessInfo.processInfo.environment, stdoutURL: root.appendingPathComponent("term.out"), stderrURL: root.appendingPathComponent("term.err"), timeoutSeconds: 5),
                shouldCancel: {
                    if !sent, owner > 1, let data = try? Data(contentsOf: packager.hidingURL), let marker = try? JSONDecoder().decode(HidingJournal.self, from: data), marker.innerPID != nil {
                        sent = true; kill(owner, SIGTERM)
                    }
                    return false
                }, onLaunch: { owner = $0 })
            check(sent && result.termination == .normal && result.exitCode == 1, "TERM observed by signal-safe owner")
            check(packager.exists(bin.appendingPathComponent("FlowType_FlowType.bundle/resource")), "TERM owner restores resources outside inner watchdog")
            check(!packager.exists(packager.hidingURL), "TERM recovery clears owned marker")
        }
    }
    static func testBoundedCancellation() throws {
        try fixture { _, _, _, root in
            let start = DispatchTime.now().uptimeNanoseconds
            var pid: Int32 = 0
            let command = BoundedCommand(executable: URL(fileURLWithPath: CommandLine.arguments[0]), arguments: ["--fixture-artifact", "timeout", root.path], workingDirectory: root,
                environment: ProcessInfo.processInfo.environment, stdoutURL: root.appendingPathComponent("cancel.out"), stderrURL: root.appendingPathComponent("cancel.err"), timeoutSeconds: 5)
            let result = try BoundedProcess.run(command, shouldCancel: { DispatchTime.now().uptimeNanoseconds - start > 150_000_000 }, onLaunch: { pid = $0 })
            check(result.termination == .signal && result.failureCode == .childSignaled, "cancellation returns closed signal result")
            check(pid > 1 && kill(pid, 0) != 0 && kill(-pid, 0) != 0, "cancelled owned process and group reaped")
            let failCommand = BoundedCommand(executable: command.executable, arguments: command.arguments, workingDirectory: root, environment: command.environment,
                stdoutURL: root.appendingPathComponent("launch.out"), stderrURL: root.appendingPathComponent("launch.err"), timeoutSeconds: 5)
            do { _ = try BoundedProcess.run(failCommand, onLaunch: { pid = $0; throw PackagingFailure.interrupted }); check(false, "launch-journal failure propagates") }
            catch { check(true, "launch-journal failure propagates") }
            check(kill(pid, 0) != 0 && kill(-pid, 0) != 0, "launch-journal failure cleans owned child")
            let early = BoundedCommand(executable: command.executable, arguments: command.arguments, workingDirectory: root, environment: command.environment,
                stdoutURL: root.appendingPathComponent("early.out"), stderrURL: root.appendingPathComponent("early.err"), timeoutSeconds: 5)
            let earlyResult = try BoundedProcess.run(early, shouldCancel: { true }, onLaunch: { pid = $0 })
            check(earlyResult.termination == .signal && earlyResult.failureCode == .childSignaled, "handshake cancellation retains closed cleanup result")
            check(kill(pid, 0) != 0 && kill(-pid, 0) != 0, "handshake cancellation reaps owned child")
        }
    }
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        try BoundedProcess.dispatchChildIfNeeded(arguments: args)
        if args.first == "--fixture-term" {
            try packagingCancellation.install()
            let repo = URL(fileURLWithPath: args[1]), bin = URL(fileURLWithPath: args[2]), root = URL(fileURLWithPath: args[3])
            let packager = ArtifactPackager(repo: repo, adapters: adapters(repo: repo, bin: bin, root: root, scenario: "waitterm"))
            do { try packager.checkApp(app: repo.appendingPathComponent("build/FlowType.app"), output: URL(fileURLWithPath: args[4])); exit(0) }
            catch { exit(1) }
        }
        if args.first == "--fixture-abandon" {
            let repo = URL(fileURLWithPath: args[1]), bin = URL(fileURLWithPath: args[2])
            let bundle = bin.appendingPathComponent("FlowType_FlowType.bundle"), token = UUID().uuidString
            let marker = try HidingJournal(token: token, releaseDirectory: bin.path, ownerPID: getpid(), innerPID: nil,
                resources: [HiddenResource(name: bundle.lastPathComponent, fingerprint: packagingFingerprint(bundle))])
            try JSONEncoder().encode(marker).write(to: repo.appendingPathComponent("build/.m5-resources.json"))
            try FileManager.default.moveItem(at: bundle, to: bin.appendingPathComponent(".m5-hidden-\(token)-\(bundle.lastPathComponent)"))
            kill(getpid(), SIGKILL); exit(1)
        }
        if args.first == "--fixture-artifact" {
            if args[1] == "timeout" || args[1] == "waitterm" { Thread.sleep(forTimeInterval: 5); exit(0) }
            if args[1] == "artifact" { exit(1) }
            let app = URL(fileURLWithPath: args[2])
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: app.appendingPathComponent("Contents/Resources/FlowTypeBuild.json")))
            var object: [String: Any] = ["schemaVersion": 1, "mode": "artifact", "ok": true, "role": "smokeTest", "runID": UUID().uuidString,
                "durationMs": 1, "failureCode": NSNull(), "buildInfo": ["origin": "packaged", "metadata": metadata, "failureCode": NSNull()],
                "appResources": true, "metalLibrary": true, "mlxOperation": true, "resolvedInsideApp": true]
            if args[1] == "schemaBool" { object["schemaVersion"] = true }
            if args[1] == "stageInt" { object["metalLibrary"] = 1 }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: object) + Data("\n".utf8)); return
        }
        for test in [testStagingFailurePreservesCandidate, testRestoreOnArtifactFailure, testManifestAndRestore, testRecoveryAndConflicts, testExternalBuildAndTerm, testBoundedCancellation] {
            do { try test() } catch { failed += 1; print("FAIL: fixture operation \((error as? PackagingFailure)?.rawValue ?? String((error as NSError).code))") }
        }
        print("=== packaging self-test: \(passed) passed, \(failed) failed ===")
        exit(failed == 0 ? 0 : 1)
    }
}
