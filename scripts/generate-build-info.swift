#!/usr/bin/env swift
import Foundation
import Darwin

enum GenerationFailure: String, Error { case usage, invalidOutput, gitFailed, dirtySource, shallowHistory, changedSource }

func command(_ arguments: [String], directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    process.environment = environment
    let output = Pipe(); process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { throw GenerationFailure.gitFailed }
    return text.trimmingCharacters(in: .newlines)
}

func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
}

struct GitSnapshot: Equatable {
    let head: String
    let sourceTree: String
    let count: String
}

func snapshot(repo: URL) throws -> GitSnapshot {
    guard try command(["rev-parse", "--is-shallow-repository"], directory: repo) == "false" else {
        throw GenerationFailure.shallowHistory
    }
    guard try command(["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"], directory: repo).isEmpty else {
        throw GenerationFailure.dirtySource
    }
    let state = try GitSnapshot(head: command(["rev-parse", "HEAD"], directory: repo),
                                sourceTree: command(["rev-parse", "HEAD:Sources"], directory: repo),
                                count: command(["rev-list", "--count", "HEAD"], directory: repo))
    guard matches(state.head, #"\A[0-9a-fA-F]{40}\z"#), matches(state.sourceTree, #"\A[0-9a-fA-F]{40}\z"#),
          matches(state.count, #"\A[0-9]+\z"#),
          try command(["cat-file", "-t", "HEAD:Sources"], directory: repo) == "tree" else {
        throw GenerationFailure.gitFailed
    }
    return state
}

func verifyUnchanged(_ original: GitSnapshot, repo: URL) throws {
    guard try snapshot(repo: repo) == original else { throw GenerationFailure.changedSource }
}

func generate(repo: URL, output: URL, version: String) throws {
    guard matches(version, #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#) else { throw GenerationFailure.usage }
    let values = try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
          try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
        throw GenerationFailure.invalidOutput
    }
    let state = try snapshot(repo: repo)
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime]
    let metadata: [String: Any] = ["schemaVersion": 1, "version": version, "buildNumber": state.count,
        "gitSHA": state.head, "sourceTree": state.sourceTree, "builtAt": formatter.string(from: Date()), "dirty": false]
    let plist: [String: Any] = [
        "CFBundleIdentifier": "com.flowtype.app", "CFBundleName": "FlowType", "CFBundleDisplayName": "FlowType",
        "CFBundleExecutable": "FlowType", "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version, "CFBundleVersion": state.count, "LSMinimumSystemVersion": "15.0",
        "LSUIElement": true, "NSHighResolutionCapable": true,
        "NSMicrophoneUsageDescription": "FlowType needs microphone access to record your voice input.",
        "NSSpeechRecognitionUsageDescription": "FlowType needs speech recognition access to convert voice to text.",
        "NSAccessibilityUsageDescription": "FlowType needs accessibility access to detect global hotkeys and inject text into other applications."]
    let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try verifyUnchanged(state, repo: repo)
    let jsonURL = output.appendingPathComponent("FlowTypeBuild.json")
    let plistURL = output.appendingPathComponent("Info.plist")
    // Only these newly owned files may be removed if the source changes or a write fails.
    var owned: [URL] = []
    do {
        try jsonData.write(to: jsonURL, options: .withoutOverwriting); owned.append(jsonURL)
        try plistData.write(to: plistURL, options: .withoutOverwriting); owned.append(plistURL)
        try verifyUnchanged(state, repo: repo)
    } catch {
        for url in owned { try? FileManager.default.removeItem(at: url) }
        throw error
    }
}

func execute(_ arguments: [String]) -> Int32 {
    do {
        var repo: String?; var output: String?; var version = "1.0.0"; var sawVersion = false; var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw GenerationFailure.usage }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--repo": guard repo == nil else { throw GenerationFailure.usage }; repo = value
            case "--output": guard output == nil else { throw GenerationFailure.usage }; output = value
            case "--version": guard !sawVersion else { throw GenerationFailure.usage }; version = value; sawVersion = true
            default: throw GenerationFailure.usage
            }
            index += 2
        }
        guard let repo, let output else { throw GenerationFailure.usage }
        try generate(repo: URL(fileURLWithPath: repo), output: URL(fileURLWithPath: output), version: version)
        return 0
    } catch let failure as GenerationFailure { return failure == .usage ? 64 : 1 }
    catch { return 1 }
}

// Real independent Git repositories. No current checkout or global Git configuration is modified.
func selfTest() -> Int32 {
    var passed = 0; var failed = 0
    func check(_ condition: Bool, _ name: String) {
        if condition { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("flowtype-build-info-\(UUID())")
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo with spaces")
        try fm.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        _ = try command(["init", "--quiet"], directory: repo)
        func commit(_ message: String) throws {
            _ = try command(["add", "."], directory: repo)
            _ = try command(["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "commit", "--quiet", "-m", message], directory: repo)
        }
        try Data("synthetic source one\n".utf8).write(to: repo.appendingPathComponent("Sources/main.swift"))
        try commit("one")
        try Data("synthetic source two\n".utf8).write(to: repo.appendingPathComponent("Sources/main.swift"))
        try commit("two")
        let expectedHEAD = try command(["rev-parse", "HEAD"], directory: repo)
        let expectedTree = try command(["rev-parse", "HEAD:Sources"], directory: repo)
        var sequence = 0
        func output() throws -> URL {
            sequence += 1
            let url = root.appendingPathComponent("output-\(sequence)")
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        func run(_ version: String? = nil, source: URL? = nil) throws -> (Int32, URL) {
            let target = try output()
            let args = ["--repo", (source ?? repo).path, "--output", target.path] + (version.map { ["--version", $0] } ?? [])
            return (execute(args), target)
        }
        let (status, target) = try run("2.3.4")
        check(status == 0, "clean nonshallow repo with spaces generates")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: target.appendingPathComponent("FlowTypeBuild.json"))) as! [String: Any]
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: target.appendingPathComponent("Info.plist")), format: nil) as! [String: Any]
        check(json["version"] as? String == "2.3.4" && plist["CFBundleShortVersionString"] as? String == "2.3.4", "one version in JSON and plist")
        check(json["buildNumber"] as? String == "2" && plist["CFBundleVersion"] as? String == "2", "full commit count identity")
        check(json["gitSHA"] as? String == expectedHEAD && json["sourceTree"] as? String == expectedTree, "committed HEAD and Sources tree identity")
        check((json["builtAt"] as? String)?.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z"#, options: .regularExpression) != nil, "generator records UTC")
        check(json["dirty"] as? Bool == false && json["schemaVersion"] as? Int == 1, "clean schema one metadata")
        check(plist["CFBundleIdentifier"] as? String == "com.flowtype.app" && plist["NSMicrophoneUsageDescription"] != nil &&
              plist["NSSpeechRecognitionUsageDescription"] != nil && plist["NSAccessibilityUsageDescription"] != nil, "bundle identity and existing usage declarations")
        let (_, defaults) = try run()
        let defaultJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: defaults.appendingPathComponent("FlowTypeBuild.json"))) as! [String: Any]
        check(defaultJSON["version"] as? String == "1.0.0", "default version")
        for version in ["1.2", "1.2.3\n", "1.2.<3>", "1.2.3$(touch injected)", "-1.2.3"] {
            let (code, destination) = try run(version)
            check(code == 64, "reject invalid version with usage64")
            check(try fm.contentsOfDirectory(atPath: destination.path).isEmpty, "invalid version writes nothing")
        }
        check(execute(["--repo"]) == 64 && execute(["--bogus", "value"]) == 64, "CLI malformed args usage64")
        check(execute(["--repo", repo.path, "--output", target.path, "--git-sha", "fake"]) == 64, "no arbitrary identity CLI override")
        let originalJSON = try Data(contentsOf: target.appendingPathComponent("FlowTypeBuild.json"))
        check(execute(["--repo", repo.path, "--output", target.path]) == 1, "reject occupied output")
        check(try Data(contentsOf: target.appendingPathComponent("FlowTypeBuild.json")) == originalJSON, "occupied output preserved")
        let destination = try output()
        let alias = root.appendingPathComponent("output-link")
        try fm.createSymbolicLink(at: alias, withDestinationURL: destination)
        check(execute(["--repo", repo.path, "--output", alias.path]) == 1, "symlink output rejected")
        try Data("dirty\n".utf8).write(to: repo.appendingPathComponent("Sources/main.swift"))
        let (dirty, dirtyOutput) = try run()
        check(try dirty == 1 && fm.contentsOfDirectory(atPath: dirtyOutput.path).isEmpty, "dirty tracked tree rejected without output")
        _ = try command(["checkout", "--", "Sources/main.swift"], directory: repo)
        try Data("untracked".utf8).write(to: repo.appendingPathComponent("untracked"))
        let (untracked, _) = try run()
        check(untracked == 1, "untracked source rejected")
        try fm.removeItem(at: repo.appendingPathComponent("untracked"))
        let shallow = root.appendingPathComponent("shallow")
        _ = try command(["clone", "--quiet", "--depth", "1", repo.absoluteString, shallow.path], directory: root)
        let (shallowStatus, shallowOutput) = try run(source: shallow)
        check(try shallowStatus == 1 && fm.contentsOfDirectory(atPath: shallowOutput.path).isEmpty, "shallow release identity rejected")
        let state = try snapshot(repo: repo)
        try Data("new committed source\n".utf8).write(to: repo.appendingPathComponent("Sources/main.swift"))
        try commit("third")
        do { try verifyUnchanged(state, repo: repo); check(false, "HEAD change rejected") }
        catch GenerationFailure.changedSource { check(true, "HEAD change rejected") }
        _ = try command(["reset", "--hard", expectedHEAD], directory: repo)
        try Data("intervening edit\n".utf8).write(to: repo.appendingPathComponent("Sources/main.swift"))
        do { try verifyUnchanged(state, repo: repo); check(false, "intervening dirty tree rejected") }
        catch GenerationFailure.dirtySource { check(true, "intervening dirty tree rejected") }
        _ = try command(["checkout", "--", "Sources/main.swift"], directory: repo)
        check(try command(["status", "--porcelain"], directory: repo).isEmpty, "fixture source remains clean")
    } catch { failed += 1; print("FAIL: fixture operation") }
    print("=== build-info generator self-test: \(passed) passed, \(failed) failed ===")
    return failed == 0 ? 0 : 1
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--self-test"] { exit(selfTest()) }
let result = execute(arguments)
if result != 0 { FileHandle.standardError.write(Data("FlowType build identity generation failed\n".utf8)) }
exit(result)
