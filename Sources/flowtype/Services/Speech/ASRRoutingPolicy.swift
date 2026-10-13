import Foundation

/// 用户可见的路由策略。
enum ASRRoutingPolicy: String, Codable, CaseIterable, Identifiable {
    case auto
    case cloudOnly
    case localOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .cloudOnly: return "仅云端"
        case .localOnly: return "仅本地"
        }
    }
}

/// 路由决策的全部输入（纯数据，便于测试）。
struct ASRRoutingInputs: Equatable, Sendable {
    let policy: ASRRoutingPolicy
    let localAvailable: Bool
    let cloudAvailable: Bool
    let networkReachable: Bool
    let cloudLatencyEWMA: Double       // ms；0 = 未知（视为健康）
    let cloudConsecutiveFailures: Int
}

enum ASRRoutingThresholds {
    static let cloudLatencyMs: Double = 3000
    static let cloudFailureStreak = 2
}

/// 纯决策：返回有序候选 provider id（"cloud-asr" / "qwen-local"）。
/// 空数组表示无候选可用 → ASRStage 走 notice / 预览兜底。
func selectASRChain(_ input: ASRRoutingInputs) -> [String] {
    switch input.policy {
    case .localOnly:
        return input.localAvailable ? ["qwen-local"] : []
    case .cloudOnly:
        return input.cloudAvailable ? ["cloud-asr"] : []
    case .auto:
        if input.localAvailable && input.cloudAvailable {
            // 产品默认：云端优先；网络不可达 / 云端延迟明显升高 / 连续失败 → 本地兜底。
            let cloudHealthy = input.networkReachable
                && input.cloudConsecutiveFailures < ASRRoutingThresholds.cloudFailureStreak
                && (input.cloudLatencyEWMA == 0 || input.cloudLatencyEWMA <= ASRRoutingThresholds.cloudLatencyMs)
            return cloudHealthy ? ["cloud-asr", "qwen-local"] : ["qwen-local", "cloud-asr"]
        }
        if input.localAvailable { return ["qwen-local"] }
        if input.cloudAvailable { return ["cloud-asr"] }
        return []
    }
}
