import Foundation
import Darwin

struct LocalModelHardwareAssessment: Sendable, Equatable {
    enum Compatibility: Sendable { case compatible, warning, incompatible }
    let compatibility: Compatibility
    let explanation: String
    let recommendedMinimumMemory: UInt64?
    let minimumResidentBytes: UInt64?

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    static func assess(model: ImportedASRModel, physicalMemory: UInt64, availableMemory: UInt64?,
                       activeModelBytes: UInt64?) -> Self {
        assess(model: model, physicalMemory: physicalMemory, availableMemory: availableMemory,
               activeModelBytes: activeModelBytes, isAppleSilicon: isAppleSilicon)
    }

    /// Architecture is injectable separately from RAM for deterministic cross-architecture tests.
    static func assess(model: ImportedASRModel, physicalMemory: UInt64, availableMemory: UInt64?,
                       activeModelBytes: UInt64?, isAppleSilicon: Bool) -> Self {
        let gib: UInt64 = 1_073_741_824
        let recommendation: UInt64? = model.engine == .qwenMLX && model.bits == 4
            ? (model.variant == "0.6B" ? 4 * gib : model.variant == "1.7B" ? 8 * gib : nil) : nil
        let floor = model.engine == .qwenMLX ? model.minimumResidentBytes : nil
        func result(_ compatibility: Compatibility, _ explanation: String) -> Self {
            .init(compatibility: compatibility, explanation: explanation,
                  recommendedMinimumMemory: recommendation, minimumResidentBytes: floor)
        }
        if model.engine == .qwenMLX && !isAppleSilicon {
            return result(.incompatible, "此 MLX 运行路径需要 Apple Silicon；请选择其他识别引擎或设备。")
        }
        if model.engine == .whisperCoreML && !isAppleSilicon {
            return result(.incompatible, "当前 WhisperKit 0.18 运行库的缓存布局不支持 Intel Mac；请使用 Apple Silicon 或其他识别引擎。这不是 Core ML 格式本身的限制。")
        }
        if let floor {
            let combined = floor.addingReportingOverflow(activeModelBytes ?? 0)
            if floor > physicalMemory || (activeModelBytes != nil && (combined.overflow || combined.partialValue > physicalMemory)) {
                return result(.incompatible, "保留旧模型时，量化权重的保守准入预留预算超过物理内存。请选用较小模型；不会自动卸载旧模型。此预算不是实测驻留内存。")
            }
            if let availableMemory, floor > availableMemory {
                return result(.incompatible, "当前可用内存估计低于候选模型的量化权重准入预留预算。请释放内存或选用较小模型后重试；此预算不代表实测峰值。")
            }
        }
        if availableMemory == 0 {
            return result(.incompatible, "当前没有可用内存，请释放内存后重试。")
        }
        var notes = ["运行峰值内存未实测；磁盘体积不等于内存需求。切换时旧模型与候选模型会同时保留。"]
        if let recommendation {
            notes.append("此 4-bit 模型的产品最低建议为 \(recommendation / gib) GiB，不是峰值保证。")
            if physicalMemory < recommendation { notes.append("当前物理内存低于此建议。") }
        }
        if floor != nil { notes.append("已知量化权重预算仅是准入下限，不包含其他权重、激活和运行库开销。") }
        else { notes.append("此运行库的驻留内存下限未知。") }
        if activeModelBytes == nil { notes.append("旧模型驻留预算未知。") }
        if availableMemory == nil { notes.append("当前可用内存未知。") }
        return result(.warning, notes.joined(separator: " "))
    }

    static func current(model: ImportedASRModel, activeModelBytes: UInt64?) -> Self {
        return assess(model: model, physicalMemory: ProcessInfo.processInfo.physicalMemory,
                      availableMemory: availableMemoryEstimate(), activeModelBytes: activeModelBytes)
    }

    /// Reclaimable-page estimate, not a promise that allocation will succeed. No guessed
    /// fallback value when Mach cannot provide a sample. Inactive pages may need paging.
    private static func availableMemoryEstimate() -> UInt64? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        // Darwin vm_statistics.h includes speculative pages in free_count already.
        let pages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
        let bytes = pages.multipliedReportingOverflow(by: UInt64(pageSize))
        return bytes.overflow ? nil : bytes.partialValue
    }
}
