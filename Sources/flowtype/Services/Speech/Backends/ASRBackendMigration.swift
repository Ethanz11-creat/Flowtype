import Foundation

enum ASRBackendMigration {
    /// Pure compatibility projection: never validates files, rewrites profiles, or invents a replacement.
    static func selection(from config: Configuration) -> ASRBackendSelection {
        if let selection = config.asrBackendSelection { return selection }
        let native: ASRBackendID?
        if let id = config.activeImportedASRModelID {
            native = ASRBackendID(rawValue: "native:import:" + id.uuidString)
        } else if let id = config.selectedLocalModelID {
            native = ASRBackendID(rawValue: "native:preset:" + id)
        } else {
            // Legacy path-only/automatic intent remains in Configuration until successful
            // activation can resolve an actual lease identity. No disk or hardware probing here.
            native = nil
        }
        // Includes the existing first-profile fallback when no row is marked active.
        let cloud = config.cloudASRConfig.activeProvider.map { ASRBackendID(rawValue: "cloud:" + $0.id.uuidString) }
        switch config.asrRoutingPolicy {
        case .localOnly:
            return ASRBackendSelection(primary: native, fallback: nil, allowsCloudFallback: false)
        case .cloudOnly:
            return ASRBackendSelection(primary: cloud, fallback: nil, allowsCloudFallback: false)
        case .auto:
            return ASRBackendSelection(primary: cloud, fallback: native, allowsCloudFallback: true)
        }
    }
}
