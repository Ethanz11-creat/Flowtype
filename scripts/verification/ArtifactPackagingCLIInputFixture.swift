import Foundation

// Compile this test-only file with the unmodified production CLI sources. Module
// lookup redirects only FileManager.default; ordinary filesystem methods remain
// Foundation implementations, while home/cache observations stay in the fixture.
private final class PackagingInputFileManager: Foundation.FileManager, @unchecked Sendable {
    private var syntheticHome: URL {
        guard let path = ProcessInfo.processInfo.environment["PACKAGING_TEST_HOME"], path.hasPrefix("/") else {
            fatalError("CLI input fixture requires an explicit synthetic home")
        }
        return URL(fileURLWithPath: path)
    }

    override var homeDirectoryForCurrentUser: URL { syntheticHome }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: Foundation.FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        if url.path.contains("/.cache/") {
            guard url.path.hasPrefix(syntheticHome.path + "/.cache/"),
                  let trace = ProcessInfo.processInfo.environment["PACKAGING_TEST_TRACE"] else {
                fatalError("CLI attempted to enumerate a cache outside its synthetic fixture")
            }
            let file = try FileHandle(forWritingTo: URL(fileURLWithPath: trace))
            try file.seekToEnd()
            try file.write(contentsOf: Data((url.path + "\n").utf8))
            try file.close()
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

enum FileManager {
    static let `default`: Foundation.FileManager = PackagingInputFileManager()
}
