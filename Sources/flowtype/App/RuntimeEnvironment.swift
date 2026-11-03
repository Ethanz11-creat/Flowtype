import Foundation

enum ProcessRole: String, Codable, Sendable { case app, selfTest, smokeTest }
enum RuntimeMode: Sendable { case app, selfTest, smoke, artifact }

struct RuntimeContext: Sendable {
    let role: ProcessRole
    let mode: RuntimeMode
    let runID: UUID
    let paths: RuntimePaths
    let defaultsSuiteName: String?
    let selfTestFilter: String?
}

enum RuntimeBootstrapError: String, Error {
    case usage, invalidRoot, rootPreparation, alreadyBootstrapped, defaultsUnavailable
    var exitCode: Int32 { self == .usage ? 64 : 1 }
}

struct RuntimeOptions: Sendable {
    let mode: RuntimeMode
    let validationRoot: String?
    let selfTestFilter: String?
    var role: ProcessRole {
        switch mode { case .app: .app; case .selfTest: .selfTest; case .smoke, .artifact: .smokeTest }
    }
    static let selfTestFilters = ["--m5-buildinfo-only", "--m5-runtime-only", "--m5-isolation-only", "--m4-recovery-only", "--m3-silence-benchmark-only",
                                  "--m3-silence-only", "--m3-asr-regression-only", "--m3-delivery-only",
                                  "--m2-review-inspection-only", "--m2-review-packages-only", "--m2-fix-only"]

    static func parse(arguments: [String]) throws -> RuntimeOptions {
        var mode: RuntimeMode?
        var root: String?
        var filter: String?
        var index = 1 // argv[0] is the executable, never an option.
        while index < arguments.count {
            let argument = arguments[index]
            let selected: RuntimeMode?
            switch argument {
            case "--self-test": selected = .selfTest
            case "--smoke-test": selected = .smoke
            case "--artifact-check": selected = .artifact
            default: selected = nil
            }
            if let selected {
                guard mode == nil else { throw RuntimeBootstrapError.usage }
                mode = selected
            } else if argument == "--validation-root" {
                guard root == nil, index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("-") else { throw RuntimeBootstrapError.usage }
                index += 1
                root = arguments[index]
            } else if selfTestFilters.contains(argument) {
                guard filter == nil else { throw RuntimeBootstrapError.usage }
                filter = argument
            } else if argument.hasPrefix("--") {
                // Long options belong to this CLI; AppKit/LaunchServices use single-dash options.
                throw RuntimeBootstrapError.usage
            }
            index += 1
        }
        let resolvedMode = mode ?? .app
        guard filter == nil || resolvedMode == .selfTest,
              root == nil || resolvedMode != .app else { throw RuntimeBootstrapError.usage }
        return RuntimeOptions(mode: resolvedMode, validationRoot: root, selfTestFilter: filter)
    }
}

/// Owns one successful bootstrap. Independent instances support injected filesystem roots.
final class RuntimeBootstrap: @unchecked Sendable {
    private let lock = NSLock()
    private let home: URL
    private let applicationSupport: URL
    private let caches: URL
    private let runID: UUID
    private var context: RuntimeContext?
    private var storedDefaults: UserDefaults?

    init(home: URL, applicationSupport: URL, caches: URL, runID: UUID = UUID()) {
        self.home = home; self.applicationSupport = applicationSupport; self.caches = caches
        self.runID = runID
    }

    var current: RuntimeContext {
        lock.lock(); defer { lock.unlock() }
        guard let context else { preconditionFailure("RuntimeEnvironment accessed before bootstrap") }
        return context
    }

    var defaults: UserDefaults {
        lock.lock(); defer { lock.unlock() }
        guard let storedDefaults else { preconditionFailure("RuntimeEnvironment defaults accessed before bootstrap") }
        return storedDefaults
    }

    func bootstrap(arguments: [String], temporaryDirectory: URL) throws -> RuntimeContext {
        lock.lock(); defer { lock.unlock() }
        guard context == nil else { throw RuntimeBootstrapError.alreadyBootstrapped }
        let options = try RuntimeOptions.parse(arguments: arguments)
        let paths: RuntimePaths
        let suite: String?
        let defaults: UserDefaults
        if options.mode == .app {
            paths = .app(home: home, applicationSupport: applicationSupport, caches: caches,
                         temporaryDirectory: temporaryDirectory)
            suite = nil
            defaults = .standard
        } else {
            paths = try RuntimePaths.prepareValidation(explicitPath: options.validationRoot,
                                                       temporaryDirectory: temporaryDirectory,
                                                       home: home, runID: runID)
            let name = "com.flowtype.validation.\(options.role.rawValue).\(runID.uuidString)"
            guard let isolated = UserDefaults(suiteName: name) else { throw RuntimeBootstrapError.defaultsUnavailable }
            suite = name
            defaults = isolated
        }
        let prepared = RuntimeContext(role: options.role, mode: options.mode, runID: runID, paths: paths,
                                      defaultsSuiteName: suite, selfTestFilter: options.selfTestFilter)
        storedDefaults = defaults
        context = prepared
        return prepared
    }

    @MainActor
    func run(arguments: [String], temporaryDirectory: URL,
             launch: (RuntimeContext) async -> Void) async throws {
        let context = try bootstrap(arguments: arguments, temporaryDirectory: temporaryDirectory)
        await launch(context)
    }

    func finishValidation() {
        lock.lock(); defer { lock.unlock() }
        if let suite = context?.defaultsSuiteName { storedDefaults?.removePersistentDomain(forName: suite) }
    }
}

enum RuntimeEnvironment {
    private static let process = RuntimeBootstrap(
        home: FileManager.default.homeDirectoryForCurrentUser,
        applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!,
        caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!)
    static var current: RuntimeContext { process.current }
    static var defaults: UserDefaults { process.defaults }
    static func bootstrap(arguments: [String], temporaryDirectory: URL) throws -> RuntimeContext {
        try process.bootstrap(arguments: arguments, temporaryDirectory: temporaryDirectory)
    }
    @MainActor
    static func run(arguments: [String], temporaryDirectory: URL,
                    launch: (RuntimeContext) async -> Void) async throws {
        try await process.run(arguments: arguments, temporaryDirectory: temporaryDirectory, launch: launch)
    }
    static func finishValidation() { process.finishValidation() }
}
