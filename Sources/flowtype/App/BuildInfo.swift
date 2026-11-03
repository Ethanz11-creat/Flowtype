import Foundation

/// Disk schema; runtime origin/failure belongs to BuildIdentity, never this file.
struct BuildMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let version: String
    let buildNumber: String
    let gitSHA: String
    let sourceTree: String
    let builtAt: String
    let dirty: Bool
}

enum BuildInfoFailure: String, Codable, Sendable {
    case missingMetadata, malformedMetadata, plistMismatch, dirtySource
}

struct BuildIdentity: Codable, Sendable {
    enum Origin: String, Codable, Sendable { case packaged, development, invalid }
    let origin: Origin
    let metadata: BuildMetadata?
    let failureCode: BuildInfoFailure?

    private enum CodingKeys: String, CodingKey { case origin, metadata, failureCode }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin, forKey: .origin)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(failureCode, forKey: .failureCode)
    }

    var aboutDescription: String {
        guard origin == .packaged, let metadata else {
            return "\(origin.rawValue) · build 0 · SHA unknown · UTC unknown"
        }
        return "\(metadata.version) · build \(metadata.buildNumber) · SHA \(metadata.gitSHA.prefix(8)) · UTC \(metadata.builtAt)"
    }
}

enum BuildInfo {
    static func load(bundle: Bundle) -> BuildIdentity {
        // A broken app stays invalid. Runtime development never consults Git or environment overrides.
        guard bundle.bundleURL.pathExtension.lowercased() == "app" else {
            return BuildIdentity(origin: .development, metadata: nil, failureCode: nil)
        }
        let resource = bundle.bundleURL.appendingPathComponent("Contents/Resources/FlowTypeBuild.json")
        guard FileManager.default.fileExists(atPath: resource.path) else { return invalid(.missingMetadata) }
        guard let data = try? Data(contentsOf: resource) else { return invalid(.malformedMetadata) }
        return validate(json: data, infoPlist: bundle.infoDictionary ?? [:])
    }

    static func validate(json: Data, infoPlist: [String: Any]) -> BuildIdentity {
        guard let metadata = try? JSONDecoder().decode(BuildMetadata.self, from: json),
              metadata.schemaVersion == 1,
              matches(metadata.version, #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#),
              matches(metadata.buildNumber, #"\A[0-9]+\z"#),
              matches(metadata.gitSHA, #"\A[0-9a-fA-F]{40}\z"#),
              matches(metadata.sourceTree, #"\A[0-9a-fA-F]{40}\z"#),
              validUTC(metadata.builtAt) else { return invalid(.malformedMetadata) }
        guard !metadata.dirty else { return invalid(.dirtySource) }
        guard infoPlist["CFBundleShortVersionString"] as? String == metadata.version,
              infoPlist["CFBundleVersion"] as? String == metadata.buildNumber else { return invalid(.plistMismatch) }
        return BuildIdentity(origin: .packaged, metadata: metadata, failureCode: nil)
    }

    private static func invalid(_ failure: BuildInfoFailure) -> BuildIdentity {
        BuildIdentity(origin: .invalid, metadata: nil, failureCode: failure)
    }
    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
    private static func validUTC(_ value: String) -> Bool {
        guard matches(value, #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z\z"#) else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.isLenient = false
        let wholeSeconds = String(value.prefix(19)) + "Z"
        guard let date = formatter.date(from: wholeSeconds) else { return false }
        return formatter.string(from: date) == wholeSeconds
    }
}
