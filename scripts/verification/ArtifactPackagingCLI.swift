import Foundation
import Darwin

@main enum ArtifactPackagingCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            try BoundedProcess.dispatchChildIfNeeded(arguments: args)
            try packagingCancellation.install()
            guard args.count >= 2, args[1].hasPrefix("/") else { throw PackagingFailure.usage }
            let repo = try canonicalExisting(URL(fileURLWithPath: args[1]))
            let scripts = repo.appendingPathComponent("scripts")
            func required(_ executable: String, _ args: [String], cwd: URL, logs: URL, timeout: Double = 60) throws -> Data {
                let (r, data) = try packagingCommand(executable, args, cwd: cwd, logs: logs, timeout: timeout)
                guard r.cliExitCode == 0 else { throw PackagingFailure.toolFailed }; return data
            }
            func releaseDirectory(_ repo: URL, _ logs: URL) throws -> URL {
                let bytes = try required("/usr/bin/swift", ["build", "-c", "release", "--show-bin-path"], cwd: repo, logs: logs, timeout: 120)
                let path = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/"), !path.contains("\n") else { throw PackagingFailure.buildFailed }
                return URL(fileURLWithPath: path)
            }
            let adapters = PackagingAdapters(releaseBuild: { repo, logs in
                _ = try required("/usr/bin/swift", ["build", "-c", "release"], cwd: repo, logs: logs, timeout: 800)
                let directory = try releaseDirectory(repo, logs)
                let architectures = try required("/usr/bin/lipo", ["-archs", directory.appendingPathComponent("FlowType").path], cwd: repo, logs: logs)
                guard String(decoding: architectures, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" else { throw PackagingFailure.buildFailed }
                return directory
            }, releaseDirectory: releaseDirectory, generateIdentity: { repo, output, version, logs in
                _ = try required("/usr/bin/swift", [scripts.appendingPathComponent("generate-build-info.swift").path, "--repo", repo.path, "--output", output.path, "--version", version], cwd: repo, logs: logs)
            }, writeManifest: { app, output, logs in
                _ = try required("/usr/bin/swift", [scripts.appendingPathComponent("write-artifact-manifest.swift").path, "--app", app.path, "--output", output.path], cwd: repo, logs: logs)
            }, sign: { app, logs in
                try PackagingSigning.sign(app: app, identity: ProcessInfo.processInfo.environment["FLOWTYPE_SIGNING_IDENTITY"]) { executable, args in
                    _ = try required(executable, args, cwd: repo, logs: logs)
                }
            }, verify: { app, logs in
                _ = try required("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", app.path], cwd: repo, logs: logs)
            }, inUse: { app, logs in
                let binary = app.appendingPathComponent("Contents/MacOS/FlowType")
                guard FileManager.default.fileExists(atPath: binary.path) else { return false }
                let (result, _) = try packagingCommand("/usr/sbin/lsof", ["-t", binary.path], cwd: repo, logs: logs)
                guard result.termination == .normal, result.exitCode == 0 || result.exitCode == 1 else { throw PackagingFailure.inUse }
                return result.exitCode == 0
            }, artifact: { app, validation, logs, launched in
                var env = ProcessInfo.processInfo.environment.filter {
                    !$0.key.hasPrefix("MLX_") && !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("SWIFTPM_")
                }
                env["PWD"] = app.deletingLastPathComponent().path
                return try BoundedProcess.run(BoundedCommand(executable: app.appendingPathComponent("Contents/MacOS/FlowType"),
                    arguments: ["--artifact-check", "--validation-root", validation.path], workingDirectory: app.deletingLastPathComponent(), environment: env,
                    stdoutURL: logs.appendingPathComponent("artifact.stdout"), stderrURL: logs.appendingPathComponent("artifact.stderr"), timeoutSeconds: 30),
                    shouldCancel: { packagingCancellation.isCancelled() }, onLaunch: launched)
            })
            let packager = ArtifactPackager(repo: repo, adapters: adapters)
            switch args[0] {
            case "build":
                guard args.count == 2 else { throw PackagingFailure.usage }
                let environment = ProcessInfo.processInfo.environment
                guard let explicit = environment["MLX_METALLIB_PATH"], !explicit.isEmpty else {
                    throw PackagingFailure.shaderInvalid
                }
                try packager.buildApp(shader: URL(fileURLWithPath: explicit), version: environment["VERSION"] ?? "1.0.0")
                print("FlowType candidate and manifest staged, signed, and published")
            case "check":
                guard args.count == 6, args[2] == "--app", args[3].hasPrefix("/"), args[4] == "--output", args[5].hasPrefix("/") else { throw PackagingFailure.usage }
                try packager.checkApp(app: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[5]))
                print("FlowType moved artifact check passed")
            default: throw PackagingFailure.usage
            }
        } catch {
            let failure = (error as? PackagingFailure) ?? .toolFailed
            FileHandle.standardError.write(Data("FlowType packaging: \(failure.rawValue)\n".utf8))
            exit(failure == .usage ? 64 : 1)
        }
    }
}
