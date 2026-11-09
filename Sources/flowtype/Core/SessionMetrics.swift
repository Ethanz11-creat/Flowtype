import Foundation

/// 最近样本的 p 分位数，空数组返回 nil。
///
/// 索引取 `round(p × (n − 1))`，与 testSessionMetrics 的期望一致：偶数列 p50 取上中位
/// （[10,20,30,40] → 30），p0 → 最小、p95/p100 → 最大，单元素恒为该值。
func percentile(_ values: [Int], _ p: Double) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let clamped = min(max(p, 0.0), 1.0)
    let rank = Int((Double(sorted.count - 1) * clamped).rounded())
    return sorted[min(max(rank, 0), sorted.count - 1)]
}

enum SessionMetrics {
    /// 纯函数：把会话指标渲染成可复制的文本报告（不含转写内容）。
    static func report(_ sessions: [DictationSession]) -> String {
        let stopToInject = sessions.compactMap(\.stopToInjectMs)
        let dispatched = sessions.filter { $0.deliveryOutcome == .typedDispatched || $0.deliveryOutcome == .pasteDispatched }
        let clipboard = sessions.filter { $0.deliveryOutcome == .clipboard }
        let uncertain = sessions.filter { $0.deliveryOutcome == .uncertain }
        let asr = sessions.compactMap(\.asrMs)
        let fallbacks = sessions.filter { $0.usedFallback == true }.count
        let cloud = sessions.filter {
            if let location = $0.asrLocation { return location == ASRBackendLocation.cloud.rawValue }
            let id = $0.asrBackendID ?? $0.asrProviderID ?? ""
            return id == ASRProviderID.cloud || id.hasPrefix("cloud:")
        }.count

        var backendCounts: [String: Int] = [:]
        for session in sessions {
            let identity = "backend: id=\(session.asrBackendID ?? session.asrProviderID ?? "legacy") model=\(session.asrModelID ?? "unknown") location=\(session.asrLocation ?? "unknown")"
            backendCounts[identity, default: 0] += 1
        }
        let backendLines = backendCounts.keys.sorted().map { "\($0) sessions=\(backendCounts[$0]!)" }

        func line(_ label: String, _ values: [Int]) -> String {
            guard let p50 = percentile(values, 0.5), let p95 = percentile(values, 0.95) else {
                return "\(label): n=0"
            }
            return "\(label): n=\(values.count) p50=\(p50)ms p95=\(p95)ms"
        }

        return ([
            "=== Flowtype ASR metrics ===",
            line("stop→inject (legacy timing)", stopToInject),
            line("stop→dispatch", dispatched.compactMap(\.stopToDeliveryMs)),
            line("stop→clipboard", clipboard.compactMap(\.stopToDeliveryMs)),
            line("stop→uncertain", uncertain.compactMap(\.stopToDeliveryMs)),
            "delivery: dispatched: \(dispatched.count), clipboard: \(clipboard.count), uncertain: \(uncertain.count), cancelled: \(sessions.filter { $0.deliveryOutcome == .cancelled }.count)",
            "dispatch means events sent; insertion is not confirmed",
            line("asr", asr),
            "sessions: \(sessions.count), cloud: \(cloud), fallback: \(fallbacks)",
        ] + backendLines).joined(separator: "\n")
    }
}
