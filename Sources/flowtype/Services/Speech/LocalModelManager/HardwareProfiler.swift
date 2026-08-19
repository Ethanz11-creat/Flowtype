import Foundation
import Darwin

enum HardwareProfiler {
    static func currentTier() -> HardwareTier {
        let bytes = currentMemoryBytes()
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        return tier(forMemoryGB: gb)
    }

    static func tier(forMemoryGB gb: Double) -> HardwareTier {
        if gb < 12 { return .low }
        if gb < 24 { return .mid }
        return .high
    }

    static func currentMemoryBytes() -> UInt64 {
        var size: UInt64 = 0
        var count = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &size, &count, nil, 0)
        guard result == 0 else {
            return 16 * 1024 * 1024 * 1024
        }
        return size
    }
}
