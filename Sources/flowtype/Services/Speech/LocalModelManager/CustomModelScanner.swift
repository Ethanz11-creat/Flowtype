import Foundation

struct ScannedModelInfo {
    let url: URL
    let sizeBytes: Int64
}

enum ModelScanError: Error, LocalizedError {
    case directoryNotFound(path: String)
    case missingConfig(path: String)
    case missingTokenizer(path: String)
    case missingWeights(path: String)
    case weightsTooSmall(minBytes: Int64, actualBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .directoryNotFound(let path):
            return "目录不存在：\(path)"
        case .missingConfig(let path):
            return "缺少 config.json：\(path)"
        case .missingTokenizer(let path):
            return "缺少分词器文件（需要 tokenizer.json 或 tokenizer_config.json+vocab.json）：\(path)"
        case .missingWeights(let path):
            return "缺少 .safetensors 权重文件：\(path)"
        case .weightsTooSmall(let minBytes, let actualBytes):
            let minMB = minBytes / (1024 * 1024)
            let actualMB = actualBytes / (1024 * 1024)
            return "权重文件过小（需要至少 \(minMB)MB，实际 \(actualMB)MB）"
        }
    }
}

enum CustomModelScanner {
    static func validateModelDirectory(_ dir: URL, minBytes: Int64) throws -> ScannedModelInfo {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ModelScanError.directoryNotFound(path: dir.path)
        }

        let configURL = dir.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: configURL.path) else {
            throw ModelScanError.missingConfig(path: dir.path)
        }

        let hasTokenizerJSON = fm.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path)
        let hasTokenizerConfig = fm.fileExists(atPath: dir.appendingPathComponent("tokenizer_config.json").path)
        let hasVocab = fm.fileExists(atPath: dir.appendingPathComponent("vocab.json").path)
        guard hasTokenizerJSON || (hasTokenizerConfig && hasVocab) else {
            throw ModelScanError.missingTokenizer(path: dir.path)
        }

        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            throw ModelScanError.missingWeights(path: dir.path)
        }

        let safetensorsFiles = items.filter { $0.pathExtension == "safetensors" }
        guard !safetensorsFiles.isEmpty else {
            throw ModelScanError.missingWeights(path: dir.path)
        }

        var totalSize: Int64 = 0
        for st in safetensorsFiles {
            let real = st.resolvingSymlinksInPath()
            if let size = (try? fm.attributesOfItem(atPath: real.path)[.size]) as? Int64 {
                totalSize += size
            }
        }

        guard totalSize >= minBytes else {
            throw ModelScanError.weightsTooSmall(minBytes: minBytes, actualBytes: totalSize)
        }

        return ScannedModelInfo(url: dir, sizeBytes: totalSize)
    }
}
