import Foundation

struct DotEnv {
    static func load(path: String = ".env") -> [String: String] {
        var env: [String: String] = [:]

        // Try to find .env in project root (near Package.swift)
        let possiblePaths = [
            path,
            FileManager.default.currentDirectoryPath + "/" + path,
            Bundle.main.bundlePath + "/" + path,
        ]

        var content: String?
        for p in possiblePaths {
            if let data = FileManager.default.contents(atPath: p),
               let str = String(data: data, encoding: .utf8) {
                content = str
                break
            }
        }

        guard let content = content else { return env }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines and comments
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            // Parse KEY=value
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
                let valueStart = trimmed.index(after: equalsIndex)
                let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
                // Remove surrounding quotes if present
                let cleanValue = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                env[key] = cleanValue
            }
        }

        return env
    }
}
