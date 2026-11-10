import Foundation

enum ModelCenterAcceptanceSelfTests {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ name: String) {
            if condition { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }
        do {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/D2-selftest-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("Synthetic evidence for validator tests only; never manual acceptance.\n".utf8).write(to: root.appendingPathComponent("evidence.txt"))
            let candidate = ModelCenterCandidate(gitSHA: String(repeating: "a", count: 40), sourceTree: String(repeating: "b", count: 40), binarySHA256: String(repeating: "c", count: 64), appPath: root.appendingPathComponent("FlowType.app").path, packageSHA256: String(repeating: "d", count: 64))
            let identity = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as! [String: Any]
            var valid = try JSONSerialization.jsonObject(with: ModelCenterAcceptance.templateData()) as! [String: Any]
            let file = root.appendingPathComponent("ledger.json")
            func evaluate(_ value: [String: Any], expected: ModelCenterCandidate? = nil) throws -> VerificationStatus {
                try JSONSerialization.data(withJSONObject: value).write(to: file)
                return try ModelCenterAcceptance.evaluate(report: file, candidate: expected ?? candidate)
            }
            func rejects(_ value: [String: Any], _ name: String, expected: ModelCenterCandidate? = nil) {
                do { check(try evaluate(value, expected: expected) == .fail, name) }
                catch { check(true, name) }
            }
            check(try evaluate(valid) == .pending, "empty template is Pending, never acceptance")
            valid["candidate"] = identity; valid["status"] = "Pass"
            let ids = ["H1.repo", "H1.variant", "H1.tokenizer", "H1.gated", "H2.resume", "H2.restart", "H2.integrity", "H2.disk", "H3.qwen06", "H3.qwen17", "H3.whisperTiny", "H3.whisperBase", "H3.offlineLong", "H4.mlxAudio", "H4.whisperKit", "H4.whisperCpp", "H4.disconnect", "H5.siliconCN", "H5.openAI", "H5.custom", "H5.errors", "H6.switch", "H6.cancel", "H6.delete", "H6.credentials", "H7.layout", "H7.keyboard", "H7.accessibility", "H8.fresh", "H8.upgrade"]
            let rows: [[String: Any]] = ids.map { id in
                let recognition = id.hasPrefix("H3.") || ["H4.mlxAudio", "H4.whisperKit", "H4.whisperCpp", "H5.siliconCN", "H5.openAI", "H5.custom"].contains(id)
                return ["id": id, "status": "Pass", "candidate": identity, "attestation": [
                    "kind": "realManual", "verification": recognition ? "realRecognition" : id == "H7.accessibility" ? "realAccessibility" : "realInteraction",
                    "tester": "Fixture Tester", "testedAt": "2026-11-10T00:00:00Z", "hardware": "Apple Silicon fixture", "macOS": "15.0",
                    "modelCommitOrServiceVersion": "fixture-version", "actions": "Explicit manual actions", "observation": "Observed real result", "evidence": ["evidence.txt"]]]
            }
            valid["cases"] = rows
            check(try evaluate(valid) == .pass, "all 30 complete candidate-bound attestations Pass")
            func changedRow(_ key: String, _ value: Any, index: Int = 0) -> [String: Any] {
                var document = valid, altered = rows; altered[index][key] = value; document["cases"] = altered; return document
            }
            func changedAttestation(_ key: String, _ value: Any, index: Int = 0) -> [String: Any] {
                var attestation = rows[index]["attestation"] as! [String: Any]; attestation[key] = value
                return changedRow("attestation", attestation, index: index)
            }
            var changed = valid; changed["cases"] = Array(rows.dropLast()); rejects(changed, "missing case fails")
            changed["cases"] = rows + [rows[0]]; rejects(changed, "duplicate case fails")
            for id in ["H9.fake", "R1.launch10", "V1.offline"] { rejects(changedRow("id", id), "unknown or old ID \(id) fails") }
            for key in ["gitSHA", "sourceTree", "binarySHA256", "packageSHA256", "appPath"] {
                var wrong = identity; wrong[key] = key == "appPath" ? "/wrong/FlowType.app" : String(repeating: "e", count: key.contains("SHA256") ? 64 : 40)
                changed = valid; changed["candidate"] = wrong; rejects(changed, "document candidate \(key) mismatch fails")
                rejects(changedRow("candidate", wrong), "row candidate \(key) mismatch fails")
            }
            for key in ["tester", "testedAt", "hardware", "macOS", "modelCommitOrServiceVersion", "actions", "observation"] {
                rejects(changedAttestation(key, "  \n"), "empty \(key) fails")
            }
            rejects(changedAttestation("testedAt", "2026-02-30T00:00:00Z"), "invalid date fails")
            rejects(changedAttestation("macOS", "14.0"), "unsupported macOS fails")
            for kind in ["configurationValid", "metadata", "fixture", "offscreen"] { rejects(changedAttestation("kind", kind), "\(kind) cannot attest real manual Pass") }
            rejects(changedAttestation("verification", "configurationValid", index: 8), "configurationValid cannot replace recognition")
            rejects(changedAttestation("verification", "realInteraction", index: 8), "interaction cannot replace recognition")
            rejects(changedAttestation("verification", "realInteraction", index: 27), "interaction cannot replace accessibility")
            for evidence in [[], [""], ["missing.txt"], ["../evidence.txt"], ["/tmp/evidence.txt"]] as [[String]] {
                rejects(changedAttestation("evidence", evidence), "invalid evidence \(evidence) fails")
            }
            try Data().write(to: root.appendingPathComponent("empty.txt"))
            rejects(changedAttestation("evidence", ["empty.txt"]), "empty file cannot be evidence")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path, withDestinationPath: "evidence.txt")
            rejects(changedAttestation("evidence", ["link.txt"]), "symlink cannot be evidence")
            rejects(changedRow("attestation", NSNull()), "missing attestation fails")
            rejects(changedRow("candidate", NSNull()), "missing row candidate fails")
            rejects(changedRow("status", "Skip"), "Skip is not acceptance")
            changed = valid; changed["schema"] = "flowtype.manual"; rejects(changed, "distinct schema required")
            changed = valid; changed["schemaVersion"] = 2; rejects(changed, "unsupported schema fails")
            changed = valid; changed["status"] = "Pending"; rejects(changed, "false claimed aggregate fails")
            var pending = try JSONSerialization.jsonObject(with: ModelCenterAcceptance.templateData()) as! [String: Any]
            pending["cases"] = Array((pending["cases"] as! [[String: Any]]).dropLast()); rejects(pending, "missing Pending case fails too")
            var mixed = valid
            var mixedRows = rows; mixedRows[0] = ["id": "H1.repo", "status": "Pending"]
            mixed["cases"] = mixedRows; mixed["status"] = "Pending"
            check(try evaluate(mixed) == .pending, "one unattested case blocks Pass")
            mixedRows[0] = ["id": "H1.repo", "status": "Fail"]
            mixed["cases"] = mixedRows; mixed["status"] = "Fail"
            check(try evaluate(mixed) == .fail, "explicit manual failure fails aggregate")
            changed = valid; changed["unrecognized"] = true; rejects(changed, "unknown ledger key fails")
            rejects(changedAttestation("unexpected", true), "unknown attestation key fails")
            for value in [true, "1", NSNull()] as [Any] {
                changed = valid; changed["schemaVersion"] = value; rejects(changed, "malformed schema version fails")
            }
            changed = valid; changed.removeValue(forKey: "candidate"); rejects(changed, "missing document candidate fails")
            var invalidIdentity = identity; invalidIdentity["binarySHA256"] = "not-a-digest"
            changed = valid; changed["candidate"] = invalidIdentity; rejects(changed, "malformed digest fails")
            try Data("not JSON".utf8).write(to: file)
            check(try ModelCenterAcceptance.evaluate(report: file, candidate: candidate) == .fail, "malformed JSON fails")
            let noPackage = ModelCenterCandidate(gitSHA: candidate.gitSHA, sourceTree: candidate.sourceTree, binarySHA256: candidate.binarySHA256, appPath: candidate.appPath, packageSHA256: nil)
            check(try evaluate(try JSONSerialization.jsonObject(with: ModelCenterAcceptance.templateData()) as! [String: Any], expected: noPackage) == .pending, "pre-distribution template remains usable")
            let noPackageIdentity = try JSONSerialization.jsonObject(with: JSONEncoder().encode(noPackage)) as! [String: Any]
            var unpackagedPass = valid; unpackagedPass["candidate"] = noPackageIdentity
            unpackagedPass["cases"] = rows.map { row in var row = row; row["candidate"] = noPackageIdentity; return row }
            rejects(unpackagedPass, "Pass without package fails", expected: noPackage)
            // Public gate uses synthetic app bytes and declared D4 fields only; no signing or services.
            let app = root.appendingPathComponent("FlowType.app")
            let resources = app.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources.appendingPathComponent("mlx-swift_Cmlx.bundle"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let binary = app.appendingPathComponent("Contents/MacOS/FlowType")
            try Data("synthetic binary".utf8).write(to: binary)
            let metadata = PackagingMetadata(schemaVersion: 1, version: "1", buildNumber: "1", gitSHA: candidate.gitSHA, sourceTree: candidate.sourceTree, builtAt: "2026-11-10T00:00:00Z", dirty: false)
            let info = resources.appendingPathComponent("FlowTypeBuild.json")
            try JSONEncoder().encode(metadata).write(to: info)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1", "CFBundleVersion": "1"], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            let shader = resources.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib")
            try Data("synthetic shader".utf8).write(to: shader)
            let manifestFile = root.appendingPathComponent("FlowType.manifest.json")
            let manifest = PackagingManifest(schemaVersion: 1, buildInfo: metadata, architecture: "arm64", binarySHA256: try packagingHash(binary), buildInfoSHA256: try packagingHash(info), shaderSHA256: try packagingHash(shader), resources: try resourceDigests(app))
            try JSONEncoder().encode(manifest).write(to: manifestFile)
            var publicIdentity = identity; publicIdentity["binarySHA256"] = manifest.binarySHA256
            var publicLedger = valid; publicLedger["candidate"] = publicIdentity
            publicLedger["cases"] = rows.map { row in var row = row; row["candidate"] = publicIdentity; return row }
            let distributionFile = root.appendingPathComponent("distribution.json")
            let distribution: [String: Any] = ["schemaVersion": 1, "status": "Pass", "candidate": publicIdentity,
                "teamID": "FIXTURE123", "hardenedRuntime": true, "appNotarizationID": "fixture-app-notary", "dmgNotarizationID": "fixture-dmg-notary", "stapled": true, "gatekeeperAccepted": true, "dmgSHA256": candidate.packageSHA256!, "issues": []]
            func publicGate(_ d: [String: Any], ledger: [String: Any]? = nil) throws -> VerificationStatus {
                try JSONSerialization.data(withJSONObject: d).write(to: distributionFile)
                try JSONSerialization.data(withJSONObject: ledger ?? publicLedger).write(to: file)
                return try ModelCenterAcceptance.evaluate(report: file, manifest: manifestFile, distributionReport: distributionFile)
            }
            func rejectsDistribution(_ d: [String: Any], _ name: String) {
                do { check(try publicGate(d) == .fail, name) } catch { check(true, name) }
            }
            check(try publicGate(distribution) == .pass, "public gate accepts matching complete D4 report")
            for key in ["teamID", "appNotarizationID", "dmgNotarizationID", "dmgSHA256"] {
                var bad = distribution; bad[key] = NSNull(); rejectsDistribution(bad, "Pass D4 missing \(key) fails")
            }
            for key in ["hardenedRuntime", "stapled", "gatekeeperAccepted"] {
                var bad = distribution; bad[key] = false; rejectsDistribution(bad, "Pass D4 false \(key) fails")
            }
            var bad = distribution; bad["issues"] = ["not accepted"]; rejectsDistribution(bad, "Pass D4 with issues fails")
            bad = distribution; bad["dmgSHA256"] = String(repeating: "e", count: 64); rejectsDistribution(bad, "D4 package digest mismatch fails")
            bad = distribution; bad["status"] = "Fail"; rejectsDistribution(bad, "D4 Fail fails aggregate")
            bad = distribution; bad["schemaVersion"] = 2; rejectsDistribution(bad, "unsupported D4 schema fails")
            bad = distribution; bad["candidate"] = identity; rejectsDistribution(bad, "D4 candidate mismatches actual manifest")
            var pendingDistribution = distribution; pendingDistribution["status"] = "Pending"
            check(try publicGate(pendingDistribution) == .pending, "D4 Pending blocks aggregate Pass")
            var unsignedIdentity = publicIdentity; unsignedIdentity["packageSHA256"] = NSNull()
            pendingDistribution["candidate"] = unsignedIdentity; pendingDistribution["dmgSHA256"] = NSNull()
            pendingDistribution["teamID"] = NSNull(); pendingDistribution["appNotarizationID"] = NSNull(); pendingDistribution["dmgNotarizationID"] = NSNull()
            pendingDistribution["hardenedRuntime"] = false; pendingDistribution["stapled"] = false; pendingDistribution["gatekeeperAccepted"] = false
            pendingDistribution["issues"] = ["Signing identity unavailable"]
            check(try publicGate(pendingDistribution, ledger: (try JSONSerialization.jsonObject(with: ModelCenterAcceptance.templateData()) as! [String: Any])) == .pending, "unsigned unpackaged D4 report remains honest Pending")
            // Exercise the actual CLI parser and exit codes against the same isolated candidate.
            func cli(_ arguments: [String]) throws -> Int32 {
                let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                process.arguments = arguments; process.currentDirectoryURL = root
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit(); return process.terminationStatus
            }
            let templateFile = root.appendingPathComponent("template.json")
            check(try cli(["--write-template", templateFile.path]) == 0, "CLI writes Pending template")
            try JSONSerialization.data(withJSONObject: pendingDistribution).write(to: distributionFile)
            let gateArguments = ["--report", templateFile.path, "--manifest", manifestFile.path, "--distribution-report", distributionFile.path]
            check(try cli(gateArguments) == 2, "CLI template with unsigned candidate exits 2")
            try JSONSerialization.data(withJSONObject: distribution).write(to: distributionFile)
            try JSONSerialization.data(withJSONObject: publicLedger).write(to: file)
            check(try cli(["--report", file.path, "--manifest", manifestFile.path, "--distribution-report", distributionFile.path]) == 0, "CLI matching complete candidate exits 0")
            var mismatched = distribution; mismatched["candidate"] = identity
            try JSONSerialization.data(withJSONObject: mismatched).write(to: distributionFile)
            check(try cli(gateArguments) == 1, "CLI mismatched candidate exits 1")
            check(try cli(["--report", file.path, "--manifest", manifestFile.path]) == 64, "CLI missing distribution exits usage 64")
            check(try cli(["--report", file.path, "--report", file.path, "--manifest", manifestFile.path]) == 64, "CLI duplicate option exits usage 64")
            print("CLI fixtures: template=2, complete=0, mismatch=1, missing/duplicate option=64")
            try Data("mutated after attestation".utf8).write(to: binary)
            rejectsDistribution(distribution, "changed binary fails public gate")

        } catch { failed += 1; print("FAIL: test setup/execution: \(error)") }
        print("Model center acceptance self-test: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
