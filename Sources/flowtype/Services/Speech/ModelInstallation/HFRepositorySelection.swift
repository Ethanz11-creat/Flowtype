import Foundation

struct HFRepositorySelection: Codable, Equatable, Sendable {
    let repoID: String
    let requestedRevision: String
    let subdirectory: String?
}

enum HFRepositoryInputError: Error, Equatable {
    case invalidInput
    case unsupportedScheme
    case requiresSelection(repoID: String, suffix: String, kind: String)
    case conflictingSelection
}

enum HFRepositoryInput {
    static func parse(_ input: String, revision: String? = nil, subdirectory: String? = nil) throws -> HFRepositorySelection {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\\"), !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw HFRepositoryInputError.invalidInput
        }
        let components: [String]
        if text.contains("://") {
            guard let url = URLComponents(string: text), url.scheme == "https" else { throw HFRepositoryInputError.unsupportedScheme }
            guard url.host == "huggingface.co", url.port == nil || url.port == 443,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw HFRepositoryInputError.invalidInput }
            var encoded = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard encoded.first == "" else { throw HFRepositoryInputError.invalidInput }
            encoded.removeFirst()
            if encoded.last == "" { encoded.removeLast() }
            components = try encoded.map { part in
                guard let decoded = part.removingPercentEncoding, !decoded.contains("/"), validPath(decoded) else { throw HFRepositoryInputError.invalidInput }
                return decoded
            }
        } else {
            guard !text.contains(":"), !text.contains("?"), !text.contains("#") else { throw HFRepositoryInputError.invalidInput }
            components = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        }
        guard components.count >= 2, validRepoComponent(components[0]), validRepoComponent(components[1]),
              !["datasets", "spaces"].contains(components[0]) else { throw HFRepositoryInputError.invalidInput }
        let repoID = components.prefix(2).joined(separator: "/")
        let requestedRevision = revision ?? "main"
        guard validPath(requestedRevision), subdirectory.map(validPath) ?? true else { throw HFRepositoryInputError.invalidInput }
        var selectedSubdirectory = subdirectory
        if components.count > 2 {
            guard text.contains("://"), components.count >= 4, ["tree", "blob"].contains(components[2]) else { throw HFRepositoryInputError.invalidInput }
            let suffix = components.dropFirst(3).joined(separator: "/")
            guard validPath(suffix) else { throw HFRepositoryInputError.invalidInput }
            guard let revision else { throw HFRepositoryInputError.requiresSelection(repoID: repoID, suffix: suffix, kind: components[2]) }
            guard suffix == revision || suffix.hasPrefix(revision + "/") else { throw HFRepositoryInputError.conflictingSelection }
            let remainder = suffix == revision ? nil : String(suffix.dropFirst(revision.count + 1))
            if let subdirectory, subdirectory != remainder { throw HFRepositoryInputError.conflictingSelection }
            selectedSubdirectory = remainder
        }
        return .init(repoID: repoID, requestedRevision: requestedRevision, subdirectory: selectedSubdirectory)
    }

    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("%") && !path.contains("\\")
            && !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func validRepoComponent(_ value: String) -> Bool {
        validPath(value) && !value.contains("/") && !value.contains("..") && !value.contains("--") && !value.hasSuffix(".git")
            && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}
