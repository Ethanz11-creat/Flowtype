import Foundation
import Darwin

/// Separate synthetic executable, compiled only by the verifier's self-test driver.
@main enum VerificationFixture {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let operation = args[0], scenario = args[1], config = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: config))
        let actualArgs = Array(args.dropFirst(4))
        try JSONSerialization.data(withJSONObject: actualArgs).write(to: output.deletingLastPathComponent().appendingPathComponent("argv.json"))
        if operation == "platform-os" { print("15.0"); return }
        if operation == "platform-arch" { print("arm64"); return }
        if operation == "platform-swift" { print("Apple Swift version 6.2.0"); return }
        if operation == "code-build" || operation == "artifact-build" {
            if scenario == "build-fail" { exit(1) }; return
        }
        if operation == "code-full" {
            if scenario == "full-timeout" { Thread.sleep(forTimeInterval: 4) }
            if scenario == "focused" { print("=== M5 runtime self-test: 12 passed, 0 failed ==="); return }
            if scenario == "no-summary" { print("finished"); return }
            print("=== FlowType --self-test ==="); print("=== self-test: 42 passed, 0 failed ==="); return
        }
        if operation == "artifact-signature" { if scenario == "signature-fail" { exit(1) }; return }
        if operation == "artifact-check" && scenario == "check-timeout" { Thread.sleep(forTimeInterval: 4) }
        let mode = operation == "artifact-check" ? "artifact" : "smoke"
        if scenario == "seventh-crash" && operation == "smoke-07" { exit(1) }
        var report: [String: Any] = ["schemaVersion": 1, "mode": mode, "ok": true, "role": "smokeTest", "runID": UUID().uuidString,
            "durationMs": 6001, "failureCode": NSNull(), "buildInfo": ["origin": "packaged", "metadata": metadata, "failureCode": NSNull()]]
        if mode == "artifact" {
            report.merge(["appResources": true, "metalLibrary": true, "mlxOperation": true, "resolvedInsideApp": true]) { _, new in new }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try (JSONSerialization.data(withJSONObject: report) + Data("\n".utf8)).write(to: output.appendingPathComponent("artifact.stdout"))
            let hashes = ["binary": String(repeating: "d", count: 64), "metadata": String(repeating: "e", count: 64), "shader": String(repeating: "c", count: 64)]
            let check: [String: Any] = ["schemaVersion": 1, "ok": true, "failureCode": NSNull(), "signature": true, "resourcesHidden": true,
                "resourcesRestored": true, "sourceCommit": String(repeating: "a", count: 40), "hashesBefore": hashes, "hashesAfter": hashes, "artifact": report]
            try JSONSerialization.data(withJSONObject: check).write(to: output.appendingPathComponent("check-result.json")); return
        }
        report.merge(["readiness": "blocked", "ax": "denied", "mic": "notDetermined", "speech": "denied", "probeTimerTicks": 1, "windowHealthTicks": 1, "tap": "disabledForValidation"]) { _, new in new }
        if scenario == "inflated-duration" { report["durationMs"] = 600_000 }
        if scenario == "skip" { report["ok"] = false; report["failureCode"] = "windowServerUnavailable" }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report) + Data("\n".utf8))
        if scenario == "skip" { exit(69) }
    }
}
