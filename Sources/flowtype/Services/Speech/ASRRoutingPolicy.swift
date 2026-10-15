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
    let cloudLatencyEWMA: Double       // 整轮请求延迟（毫秒）；0 = 未知（视为健康）
    let cloudConsecutiveFailures: Int
    /// TCP+TLS 握手探测值（毫秒）。nil = 未采样，或采样失败（由 `cloudProbeFailed` 区分）。
    let cloudProbeMs: Double?
    /// 采样过但握手失败 —— 网络可达前提下的负证据，不可与"从未采样"混为一谈。
    let cloudProbeFailed: Bool

    init(policy: ASRRoutingPolicy,
         localAvailable: Bool,
         cloudAvailable: Bool,
         networkReachable: Bool,
         cloudLatencyEWMA: Double,
         cloudConsecutiveFailures: Int,
         cloudProbeMs: Double? = nil,
         cloudProbeFailed: Bool = false) {
        self.policy = policy
        self.localAvailable = localAvailable
        self.cloudAvailable = cloudAvailable
        self.networkReachable = networkReachable
        self.cloudLatencyEWMA = cloudLatencyEWMA
        self.cloudConsecutiveFailures = cloudConsecutiveFailures
        self.cloudProbeMs = cloudProbeMs
        self.cloudProbeFailed = cloudProbeFailed
    }
}

enum ASRRoutingThresholds {
    /// 阈值的标定对象 = 整轮云端请求延迟（EWMA 的采样对象），量级为秒。
    static let cloudLatencyMs: Double = 3000
    /// 阈值的标定对象 = TCP+TLS 握手耗时（探测的采样对象），量级为百毫秒。
    /// 健康链路实测 85–191ms；按 ~3× 取 600ms 判"明显变慢"。
    /// 两者量纲不同，绝不可共用同一个阈值。
    static let cloudProbeHandshakeMs: Double = 600
    static let cloudFailureStreak = 2
}

/// 纯决策：返回有序候选 provider id（cloud-asr / qwen-local）。
/// 空数组表示无候选可用 → ASRStage 走 notice / 预览兜底。
func selectASRChain(_ input: ASRRoutingInputs) -> [String] {
    switch input.policy {
    case .localOnly:
        return input.localAvailable ? [ASRProviderID.qwenLocal] : []
    case .cloudOnly:
        return input.cloudAvailable ? [ASRProviderID.cloud] : []
    case .auto:
        if input.localAvailable && input.cloudAvailable {
            // 产品默认：云端优先；下列任一成立则改走本地兜底：
            // 网络不可达 / 整轮延迟明显升高 / 连续失败 / 当前握手探测判慢或失败。
            let coldStart = input.cloudLatencyEWMA == 0
            // 快探测不能抵消慢真实请求；慢/失败探测仍可否决快真实样本。
            let requestHealthy = coldStart
                || input.cloudLatencyEWMA <= ASRRoutingThresholds.cloudLatencyMs

            let probeHealthy: Bool
            if input.cloudProbeFailed {
                probeHealthy = false         // 采了但失败 → 负证据
            } else if let probe = input.cloudProbeMs {
                probeHealthy = probe <= ASRRoutingThresholds.cloudProbeHandshakeMs
            } else {
                probeHealthy = true          // 从未采样 → 沿用"未知视为健康"
            }

            let cloudHealthy = input.networkReachable
                && input.cloudConsecutiveFailures < ASRRoutingThresholds.cloudFailureStreak
                && requestHealthy
                && probeHealthy
            return cloudHealthy ? [ASRProviderID.cloud, ASRProviderID.qwenLocal]
                                : [ASRProviderID.qwenLocal, ASRProviderID.cloud]
        }
        if input.localAvailable { return [ASRProviderID.qwenLocal] }
        if input.cloudAvailable { return [ASRProviderID.cloud] }
        return []
    }
}
