import Foundation
import CryptoKit

struct SafetensorsManifest: Sendable {
    struct Tensor: Sendable {
        let dtype: String
        let shape: [Int64]
        let shard: String
    }
    let tensors: [String: Tensor]
    let sizeBytes: Int64
    let fileFingerprint: String
    static let metadataLimit = 16 * 1024 * 1024

    static func read(directory: URL) throws -> SafetensorsManifest {
        let files = LocalInspectionFiles()
        return try read(directory: directory, files: files)
    }

    static func read(directory: URL, files: LocalInspectionFiles) throws -> SafetensorsManifest {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else { throw failure(.incompleteModel, "缺少 MLX safetensors 权重。") }
        var tensors: [String: Tensor] = [:]
        var total: Int64 = 0
        var totalPayload: Int64 = 0
        for url in urls {
            let before = try files.identity(url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 8) ?? Data()
            guard prefix.count == 8 else { throw failure(.invalidTensor, "权重文件头截断：\(url.lastPathComponent)") }
            let length = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
            guard length > 0, length <= metadataLimit, before.size >= 8,
                  length <= UInt64(before.size - 8) else {
                throw failure(.invalidTensor, "无效、过大或未下载完整的 safetensors 文件头（包括 LFS 指针）。")
            }
            let header = try handle.read(upToCount: Int(length)) ?? Data()
            guard header.count == Int(length) else { throw failure(.invalidTensor, "权重文件头截断。") }
            let object = try LocalInspectionFiles.object(header)
            let payload = before.size - 8 - Int64(length)
            var ranges: [(Int64, Int64)] = []
            for (name, value) in object where name != "__metadata__" {
                guard tensors[name] == nil else { throw failure(.invalidTensor, "分片包含重复张量：\(name)") }
                guard let entry = value as? [String: Any], let dtype = entry["dtype"] as? String,
                      let rawShape = entry["shape"] as? [Any], rawShape.count <= 16,
                      let rawOffsets = entry["data_offsets"] as? [Any], rawOffsets.count == 2 else {
                    throw failure(.invalidTensor, "张量描述无效：\(name)")
                }
                let shape = try rawShape.map { try LocalInspectionFiles.integer($0) }
                let offsets = try rawOffsets.map { try LocalInspectionFiles.integer($0) }
                let widths: [String: Int64] = ["F64":8,"F32":4,"F16":2,"BF16":2,"I64":8,"I32":4,"I16":2,"I8":1,"U64":8,"U32":4,"U16":2,"U8":1,"BOOL":1]
                guard let width = widths[dtype], shape.allSatisfy({ $0 > 0 }),
                      offsets[0] >= 0, offsets[1] >= offsets[0], offsets[1] <= payload else {
                    throw failure(.invalidTensor, "张量类型、形状或数据边界无效：\(name)")
                }
                var bytes = width
                for dimension in shape {
                    let product = bytes.multipliedReportingOverflow(by: dimension)
                    guard !product.overflow else { throw failure(.invalidTensor, "张量尺寸溢出：\(name)") }
                    bytes = product.partialValue
                }
                guard offsets[1] - offsets[0] == bytes else { throw failure(.invalidTensor, "张量字节长度与形状不符：\(name)") }
                ranges.append((offsets[0], offsets[1]))
                tensors[name] = Tensor(dtype: dtype, shape: shape, shard: url.lastPathComponent)
            }
            var end: Int64 = 0
            for range in ranges.sorted(by: { $0.0 < $1.0 }) {
                guard range.0 == end else { throw failure(.invalidTensor, "权重数据包含重叠或空洞。") }; end = range.1
            }
            guard end == payload, !ranges.isEmpty else { throw failure(.invalidTensor, "权重数据长度不符或没有张量。") }
            let sum = total.addingReportingOverflow(before.size)
            guard !sum.overflow else { throw failure(.invalidTensor, "权重总大小溢出。") }; total = sum.partialValue
            totalPayload += payload // bounded by the checked sum of complete file sizes above
            try files.record(url, before: before, data: header)
        }
        let indexes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".safetensors.index.json") }
        guard indexes.count <= 1 else { throw failure(.invalidIndex, "存在多个 safetensors 索引。") }
        if let index = indexes.first {
            let object = try files.json(index)
            guard let map = object["weight_map"] as? [String: String], Set(map.keys) == Set(tensors.keys) else {
                throw failure(.invalidIndex, "索引张量集合与实际分片不一致。")
            }
            if let metadata = object["metadata"] as? [String: Any], let declaredSize = metadata["total_size"] {
                guard try LocalInspectionFiles.integer(declaredSize) == totalPayload else {
                    throw failure(.invalidIndex, "索引声明的总大小与张量数据不一致。")
                }
            }
            for (key, name) in map {
                // Loader reads only direct children. Blob symlinks are valid; lexical index traversal is not.
                guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent,
                      !name.contains("/"), !name.contains("\\"), name.hasSuffix(".safetensors"),
                      tensors[key]?.shard == name else { throw failure(.invalidIndex, "索引分片路径越界、缺失或映射不一致。") }
            }
        }
        try files.verify()
        return SafetensorsManifest(tensors: tensors, sizeBytes: total, fileFingerprint: files.fingerprint)
    }
}

func failure(_ code: ASRModelInspectionError.Code, _ detail: String) -> ASRModelInspectionError {
    ASRModelInspectionError(code: code, detail: detail)
}

/// Tracks bounded metadata and resolved file identity. No payload reads, network, configuration or writes.
final class LocalInspectionFiles {
    struct Identity: Equatable {
        let resolvedPath: String
        let size: Int64
        let inode: UInt64
        let device: UInt64
        let modified: Date
        let created: Date
    }
    private var records: [String: Identity] = [:]
    private var hashes: [String: String] = [:]
    func identity(_ url: URL) throws -> Identity {
        guard url.isFileURL else { throw failure(.unreadable, "仅支持本机文件目录。") }
        let real = url.resolvingSymlinksInPath()
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: real.path) }
        catch { throw failure(.unreadable, "文件不可读或符号链接已失效：\(url.lastPathComponent)") }
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value >= 0,
              FileManager.default.isReadableFile(atPath: real.path) else { throw failure(.unreadable, "需要可读的普通文件：\(url.lastPathComponent)") }
        return Identity(resolvedPath: real.path, size: size.int64Value,
                        inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                        device: (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                        modified: attrs[.modificationDate] as? Date ?? .distantPast,
                        created: attrs[.creationDate] as? Date ?? .distantPast)
    }
    func record(_ url: URL, before: Identity, data: Data? = nil) throws {
        guard try identity(url) == before else { throw failure(.changedDuringInspection, "检查期间模型文件发生变化，请重新检查。") }
        records[url.path] = before
        if let data { hashes[url.path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
    func read(_ url: URL, limit: Int = SafetensorsManifest.metadataLimit) throws -> Data {
        let before = try identity(url)
        guard before.size <= limit else { throw failure(.metadataTooLarge, "元数据超过允许大小：\(url.lastPathComponent)") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == before.size else { throw failure(.changedDuringInspection, "读取期间文件长度发生变化。") }
        guard !data.starts(with: Data("version https://git-lfs.github.com/spec/".utf8)) else { throw failure(.incompleteModel, "文件仍是 Git LFS 指针，请先完整下载。") }
        try record(url, before: before, data: data)
        return data
    }
    func json(_ url: URL) throws -> [String: Any] { try Self.object(read(url)) }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure(.invalidMetadata, "JSON 元数据无效。") }
        // Foundation silently collapses duplicate keys. Reject them before trusting tensor/index/config maps.
        let bytes = Array(data); var stack: [Set<String>?] = []; var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 123 { stack.append([]) }
            else if b == 91 { stack.append(nil) }
            else if b == 125 || b == 93 { _ = stack.popLast() }
            else if b == 34 {
                let start = i; i += 1
                while i < bytes.count {
                    if bytes[i] == 92 { i += 2; continue }
                    if bytes[i] == 34 { break }; i += 1
                }
                let end = i; var next = i + 1
                while next < bytes.count && [9,10,13,32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58, !stack.isEmpty, stack[stack.count - 1] != nil {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...end]))
                    guard stack[stack.count - 1]!.insert(key).inserted else { throw failure(.invalidMetadata, "JSON 元数据包含重复字段：\(key)") }
                }
            }
            i += 1
        }
        return object
    }
    static func integer(_ value: Any) throws -> Int64 {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let integer = Int64(n.stringValue) else { throw failure(.invalidMetadata, "元数据需要有效的 64 位整数。") }
        return integer
    }
    func verify() throws {
        for (path, value) in records where try identity(URL(fileURLWithPath: path)) != value {
            throw failure(.changedDuringInspection, "检查期间模型文件发生变化，请重新检查。")
        }
    }
    var fingerprint: String {
        var hash = SHA256()
        for path in records.keys.sorted() {
            let r = records[path]!
            hash.update(data: Data("\(path)\0\(r.resolvedPath)\0\(r.size)\0\(r.inode)\0\(r.device)\0\(r.modified.timeIntervalSince1970)\0\(r.created.timeIntervalSince1970)\0\(hashes[path] ?? "")\n".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
