import Foundation
import Darwin

struct RuntimePaths: Sendable {
    let validationRoot: URL?
    let configDirectory: URL
    let applicationSupportDirectory: URL
    let cachesDirectory: URL
    let logsDirectory: URL
    let temporaryDirectory: URL
    let modelsDirectory: URL

    var installedASRModelsDirectory: URL { modelsDirectory.appendingPathComponent("installed") }
    var asrInstallationJobsDirectory: URL { modelsDirectory.appendingPathComponent("installation-jobs") }

    static func app(home: URL, applicationSupport: URL, caches: URL,
                    temporaryDirectory: URL) -> RuntimePaths {
        RuntimePaths(validationRoot: nil,
                     configDirectory: applicationSupport.appendingPathComponent("FlowType"),
                     applicationSupportDirectory: applicationSupport.appendingPathComponent("FlowType"),
                     cachesDirectory: caches,
                     logsDirectory: home.appendingPathComponent("Library/Logs/flowtype"),
                     temporaryDirectory: temporaryDirectory,
                     modelsDirectory: applicationSupport.appendingPathComponent("Flowtype/models"))
    }

    static func validation(root: URL) -> RuntimePaths {
        RuntimePaths(validationRoot: root,
                     configDirectory: root.appendingPathComponent("config"),
                     applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                     cachesDirectory: root.appendingPathComponent("Caches"),
                     logsDirectory: root.appendingPathComponent("Logs"),
                     temporaryDirectory: root.appendingPathComponent("Tmp"),
                     modelsDirectory: root.appendingPathComponent("ApplicationSupport/models"))
    }

    /// Only the OS-provided temporary base is allowed to resolve trusted aliases such as /var.
    /// Explicit roots are traversed from / using descriptor-relative, no-follow operations.
    static func prepareValidation(explicitPath: String?, temporaryDirectory: URL,
                                  home: URL, runID: UUID) throws -> RuntimePaths {
        let path: String
        if let explicitPath {
            guard explicitPath.hasPrefix("/"), !explicitPath.utf8.contains(0),
                  !explicitPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw RuntimeBootstrapError.invalidRoot
            }
            // Do not use standardizedFileURL: Foundation may turn an existing
            // /private/var path back into /var and erase the explicit-path distinction.
            path = "/" + explicitPath.split(separator: "/").joined(separator: "/")
        } else {
            guard temporaryDirectory.isFileURL else { throw RuntimeBootstrapError.invalidRoot }
            // Foundation may preserve the /var alias even in resolvingSymlinksInPath().
            guard let resolved = realpath(temporaryDirectory.path, nil) else {
                throw RuntimeBootstrapError.invalidRoot
            }
            defer { free(resolved) }
            path = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                .appendingPathComponent("flowtype-validation/\(runID.uuidString)").path
        }
        let candidate = path.lowercased()
        var homePaths = [home.path]
        if let resolvedHome = realpath(home.path, nil) {
            homePaths.append(String(cString: resolvedHome))
            free(resolvedHome)
        }
        guard candidate != "/", homePaths.allSatisfy({ homePath in
            let protectedHome = homePath.lowercased()
            let library = protectedHome + "/library"
            return candidate != protectedHome && !protectedHome.hasPrefix(candidate + "/")
                && candidate != library && !candidate.hasPrefix(library + "/")
        }) else { throw RuntimeBootstrapError.invalidRoot }

        let descriptor = try openDirectoryTree(path)
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid() else {
            throw RuntimeBootstrapError.invalidRoot
        }
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw RuntimeBootstrapError.rootPreparation }
        guard let entries = fdopendir(duplicate) else {
            close(duplicate)
            throw RuntimeBootstrapError.rootPreparation
        }
        defer { closedir(entries) }
        errno = 0
        while let entry = readdir(entries) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard name == "." || name == ".." else { throw RuntimeBootstrapError.invalidRoot }
        }
        guard errno == 0 else { throw RuntimeBootstrapError.rootPreparation }

        let marker = openat(descriptor, ".flowtype-validation-run", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard marker >= 0 else { throw RuntimeBootstrapError.rootPreparation }
        defer { close(marker) }
        let identity = Array(runID.uuidString.utf8)
        let written = identity.withUnsafeBytes { Darwin.write(marker, $0.baseAddress, $0.count) }
        guard written == identity.count else { throw RuntimeBootstrapError.rootPreparation }
        // Retain the marker on all later failures. Never delete an existing root or its contents.
        for directory in ["config", "ApplicationSupport", "Caches", "Logs", "Tmp"] {
            guard mkdirat(descriptor, directory, 0o700) == 0 else { throw RuntimeBootstrapError.rootPreparation }
        }
        return validation(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func openDirectoryTree(_ path: String) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open("/", flags)
        guard descriptor >= 0 else { throw RuntimeBootstrapError.rootPreparation }
        do {
            for component in path.split(separator: "/") {
                let name = String(component)
                var child = openat(descriptor, name, flags)
                if child < 0, errno == ENOENT {
                    guard mkdirat(descriptor, name, 0o700) == 0 || errno == EEXIST else {
                        throw RuntimeBootstrapError.rootPreparation
                    }
                    child = openat(descriptor, name, flags)
                }
                guard child >= 0 else { throw RuntimeBootstrapError.invalidRoot }
                close(descriptor)
                descriptor = child
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }
}
