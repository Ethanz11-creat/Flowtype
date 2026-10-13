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
        let asr = sessions.compactMap(\.asrMs)
        let fallbacks = sessions.filter { $0.usedFallback == true }.count
        let cloud = sessions.filter { $0.asrProviderID == "cloud-asr" }.count

        func line(_ label: String, _ values: [Int]) -> String {
            guard let p50 = percentile(values, 0.5), let p95 = percentile(values, 0.95) else {
                return "\(label): n=0"
            }
            return "\(label): n=\(values.count) p50=\(p50)ms p95=\(p95)ms"
        }

        return [
            "=== Flowtype ASR metrics ===",
            line("stop→inject", stopToInject),
            line("asr", asr),
            "sessions: \(sessions.count), cloud: \(cloud), fallback: \(fallbacks)",
        ].joined(separator: "\n")
    }
}
