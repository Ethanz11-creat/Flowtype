import Foundation

/// Selection is the complete candidate set. Health may reorder, never widen it.
enum ASRBackendRouting {
    static func order(selection: ASRBackendSelection, policy: ASRRoutingPolicy,
                      descriptors: [ASRBackendDescriptor], availableIDs: Set<ASRBackendID>,
                      internetAvailable: Bool, degradedIDs: Set<ASRBackendID>) -> [ASRBackendID] {
        let byID = Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let primaryLocation = selection.primary.flatMap { byID[$0]?.location }
        var seen = Set<ASRBackendID>()
        var ids = [selection.primary, selection.fallback].compactMap { $0 }.filter { id in
            guard seen.insert(id).inserted, availableIDs.contains(id), let descriptor = byID[id] else { return false }
            if descriptor.requiresInternet && !internetAvailable { return false }
            if policy == .localOnly && descriptor.location == .cloud { return false }
            if policy == .cloudOnly && descriptor.location != .cloud { return false }
            if id != selection.primary, descriptor.location == .cloud,
               primaryLocation != .cloud, !selection.allowsCloudFallback { return false }
            return true
        }
        if policy == .auto, ids.count == 2, degradedIDs.contains(ids[0]), !degradedIDs.contains(ids[1]) {
            ids.swapAt(0, 1)
        }
        return ids
    }
}
