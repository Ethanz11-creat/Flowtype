import Foundation
import os
import Darwin

/// Synthetic filesystem/defaults fixtures only; no legacy shared services are constructed.
enum M5RuntimeSelfTests {
    @MainActor
    static func run(_ r: SelfTest.Reporter) async {
        for test in [testCanonicalTempAndExplicitSymlink, testRootOwnershipAndUsage,
                     testDefaultsAndBootstrapOwnership] {
            do { try test(r) }
            catch { r.check(false, "M5 runtime fixture operation failed") }
        }
        testAppPathCompatibility(r)
        do { try await testArgumentsAndLaunchGate(r) }
        catch { r.check(false, "M5 argument fixture operation failed") }
    }

    private static func fixture(_ body: (URL, URL) throws -> Void) throws {
        let base = try fixtureTemporaryDirectory()
            .appendingPathComponent("flowtype-m5-fixture-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base, home)
    }

    private static func fixtureTemporaryDirectory() throws -> URL {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw RuntimeBootstrapError.rootPreparation
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func runtime(home: URL, runID: UUID = UUID()) -> RuntimeBootstrap {
        RuntimeBootstrap(home: home,
                         applicationSupport: home.appendingPathComponent("Library/Application Support"),
                         caches: home.appendingPathComponent("Library/Caches"), runID: runID)
    }

    private static func rejected(_ r: SelfTest.Reporter, _ name: String,
                                 exitCode: Int32 = 1, _ body: () throws -> Void) {
        do {
            try body()
            r.check(false, "M5 rejects \(name)")
        } catch let error as RuntimeBootstrapError {
            r.eq(error.exitCode, exitCode, "M5 rejection status: \(name)")
        } catch {
            r.check(false, "M5 returns a closed error for \(name)")
        }
    }

    // Catches trusting explicit symlinks or rejecting the OS's trusted temp alias.
    static func testCanonicalTempAndExplicitSymlink(_ r: SelfTest.Reporter) throws {
        try fixture { base, home in
            let temp = base.appendingPathComponent("temp")
            let alias = base.appendingPathComponent("temp-alias")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: temp)
            let context = try runtime(home: home).bootstrap(arguments: ["FlowType", "--self-test"], temporaryDirectory: alias)
            r.eq(context.paths.validationRoot?.deletingLastPathComponent().path,
                 temp.appendingPathComponent("flowtype-validation").path, "M5 canonical trusted temp")
            r.eq(context.role, .selfTest, "M5 self-test role")
            r.eq(context.mode, .selfTest, "M5 self-test mode")
            let links = [alias.path, alias.appendingPathComponent("child").path]
            for path in links {
                rejected(r, "explicit symlink or ancestor") {
                    _ = try runtime(home: home).bootstrap(arguments: ["FlowType", "--self-test", "--validation-root", path], temporaryDirectory: temp)
                }
            }
            r.check(!FileManager.default.fileExists(atPath: temp.appendingPathComponent("child").path),
                    "M5 rejected symlink ancestor creates no child")
        }
    }

    // Catches shared validation roots, destructive cleanup, and overbroad home rejection.
    static func testRootOwnershipAndUsage(_ r: SelfTest.Reporter) throws {
        try fixture { base, home in
            let forbidden = ["relative-root", "/", base.path, home.path,
                             home.appendingPathComponent("Library").path,
                             home.appendingPathComponent("Library/Application Support/FlowType").path,
                             home.appendingPathComponent("Library/Application Support/Flowtype/models").path,
                             home.appendingPathComponent("Library/Caches/new-run").path,
                             home.appendingPathComponent("Library/Logs/flowtype").path]
            for path in forbidden {
                rejected(r, "unsafe validation root") {
                    _ = try runtime(home: home).bootstrap(arguments: ["FlowType", "--self-test", "--validation-root", path], temporaryDirectory: base)
                }
            }
            let occupied = base.appendingPathComponent("occupied")
            try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
            let original = occupied.appendingPathComponent("keep.txt")
            try Data("synthetic-original".utf8).write(to: original)
            rejected(r, "nonempty validation root") {
                _ = try runtime(home: home).bootstrap(arguments: ["FlowType", "--self-test", "--validation-root", occupied.path], temporaryDirectory: base)
            }
            r.eq(try String(contentsOf: original, encoding: .utf8), "synthetic-original", "M5 failed root preserves original")
            let root = home.appendingPathComponent("workspace/build/validation")
            let results = OSAllocatedUnfairLock(initialState: [Bool]())
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                let succeeded = (try? runtime(home: home).bootstrap(
                    arguments: ["FlowType", "--self-test", "--validation-root", root.path], temporaryDirectory: base)) != nil
                results.withLock { $0.append(succeeded) }
            }
            r.eq(results.withLock { $0.filter { $0 }.count }, 1, "M5 same-root race has exactly one owner")
            for directory in ["config", "ApplicationSupport", "Caches", "Logs", "Tmp"] {
                var isDirectory: ObjCBool = false
                r.check(FileManager.default.fileExists(atPath: root.appendingPathComponent(directory).path,
                                                      isDirectory: &isDirectory) && isDirectory.boolValue,
                        "M5 creates isolated \(directory)")
            }
            let empty = base.appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let context = try runtime(home: home).bootstrap(arguments: ["FlowType", "--self-test", "--validation-root", empty.path], temporaryDirectory: base)
            r.eq(context.paths.validationRoot?.path, empty.path, "M5 accepts existing empty real root")
            r.eq(context.paths.modelsDirectory.path, empty.path + "/ApplicationSupport/models", "M5 validation models stay in root")
        }
    }

    // Catches changing legacy FlowType/Flowtype casing or app's base cache/temp semantics.
    static func testAppPathCompatibility(_ r: SelfTest.Reporter) {
        let paths = RuntimePaths.app(home: URL(fileURLWithPath: "/fixture/home"),
                                     applicationSupport: URL(fileURLWithPath: "/fixture/support"),
                                     caches: URL(fileURLWithPath: "/fixture/cache"),
                                     temporaryDirectory: URL(fileURLWithPath: "/fixture/temp"))
        r.eq(paths.validationRoot, nil, "M5 app has no validation root")
        r.eq(paths.configDirectory.path, "/fixture/support/FlowType", "M5 legacy config path")
        r.eq(paths.applicationSupportDirectory.path, "/fixture/support/FlowType", "M5 legacy database/store path")
        r.eq(paths.modelsDirectory.path, "/fixture/support/Flowtype/models", "M5 legacy model path casing")
        r.eq(paths.cachesDirectory.path, "/fixture/cache", "M5 legacy cache base")
        r.eq(paths.logsDirectory.path, "/fixture/home/Library/Logs/flowtype", "M5 legacy logger path")
        r.eq(paths.temporaryDirectory.path, "/fixture/temp", "M5 legacy temp base")
    }

    // Catches permissive parsing that reaches the app launch callback on invalid M5 input.
    @MainActor
    private static func testArgumentsAndLaunchGate(_ r: SelfTest.Reporter) async throws {
        let base = try fixtureTemporaryDirectory()
            .appendingPathComponent("flowtype-m5-arguments-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let invalid = [
            ["--self-test", "--smoke-test"], ["--artifact-check", "--self-test"],
            ["--smoke-test", "--artifact-check"], ["--self-test", "--self-test"],
            ["--validation-root"], ["--validation-root", "/fixture/root"],
            ["--self-test", "--validation-root", "/fixture/a", "--validation-root", "/fixture/b"],
            ["--m5-runtime-only"], ["--smoke-test", "--m5-runtime-only"],
            ["--self-test", "--m5-runtime-only", "--m5-runtime-only"],
            ["--self-test", "--m4-recovery-only", "--m5-runtime-only"],
            ["--m5-unknown"], ["--self-test=1"], ["--validation-root=/fixture/root"]
        ]
        let before = RuntimeEnvironment.current.runID
        for arguments in invalid {
            var launched = false
            do {
                let isolated = runtime(home: home)
                defer { isolated.finishValidation() }
                try await isolated.run(arguments: ["FlowType"] + arguments,
                                       temporaryDirectory: base) { _ in launched = true }
                r.check(false, "M5 invalid arguments fail before launch")
            } catch let error as RuntimeBootstrapError {
                r.eq(error.exitCode, 64, "M5 invalid arguments usage64")
            }
            r.check(!launched, "M5 invalid arguments never reach app launch")
        }
        let app = try RuntimeOptions.parse(arguments: ["FlowType", "-psn_0_12345", "-NSDocumentRevisionsDebugMode", "YES"])
        r.eq(app.mode, .app, "M5 preserves LaunchServices app arguments")
        for filter in RuntimeOptions.selfTestFilters {
            let options = try RuntimeOptions.parse(arguments: ["FlowType", "--self-test", filter])
            r.eq(options.selfTestFilter, filter, "M5 preserves self-test filter")
            rejected(r, "filter without self-test", exitCode: 64) {
                _ = try RuntimeOptions.parse(arguments: ["FlowType", filter])
            }
        }
        for (argument, mode) in [("--smoke-test", RuntimeMode.smoke), ("--artifact-check", .artifact)] {
            let options = try RuntimeOptions.parse(arguments: ["FlowType", argument])
            r.eq(options.mode, mode, "M5 non-GUI validation mode")
            r.eq(options.role, .smokeTest, "M5 smoke/artifact process role")
        }
        r.eq(RuntimeEnvironment.current.runID, before, "M5 instance fixtures never replace process context")
    }

    // Catches defaults recreation, suite collisions, or cleanup affecting a different run.
    private static func testDefaultsAndBootstrapOwnership(_ r: SelfTest.Reporter) throws {
        try fixture { base, home in
            let fixedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            let first = runtime(home: home, runID: fixedID)
            let context = try first.bootstrap(arguments: ["FlowType", "--self-test"], temporaryDirectory: base)
            let second = runtime(home: home)
            let other = try second.bootstrap(arguments: ["FlowType", "--self-test"], temporaryDirectory: base)
            defer { first.finishValidation(); second.finishValidation() }
            r.eq(context.runID, fixedID, "M5 instance factory supports deterministic run identity")
            r.eq(context.defaultsSuiteName, "com.flowtype.validation.selfTest.11111111-2222-3333-4444-555555555555",
                 "M5 fixed fixture suite identity")
            r.check(context.runID != other.runID, "M5 assigns unique run IDs")
            r.eq(context.defaultsSuiteName, "com.flowtype.validation.selfTest.\(context.runID.uuidString)", "M5 suite bound to role/run")
            r.check(first.defaults === first.defaults, "M5 defaults constructed once")
            first.defaults.set("first", forKey: "synthetic-m5")
            second.defaults.set("second", forKey: "synthetic-m5")
            first.finishValidation()
            r.eq(first.defaults.string(forKey: "synthetic-m5"), nil, "M5 cleanup removes own suite")
            r.eq(second.defaults.string(forKey: "synthetic-m5"), "second", "M5 cleanup preserves another run")
            rejected(r, "second bootstrap") {
                _ = try first.bootstrap(arguments: ["FlowType", "--self-test"], temporaryDirectory: base)
            }
            r.eq(first.current.runID, context.runID, "M5 failed rebootstrap preserves context")
            r.eq(AppLogger.logFileURL.path,
                 RuntimeEnvironment.current.paths.logsDirectory.appendingPathComponent("diagnostic-selftest.log").path,
                 "M5 logger is routed to isolated self-test root")
        }
    }
}
