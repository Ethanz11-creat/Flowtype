import Foundation

/// In-memory delivery metadata only; never retains dictated text or context.
struct LastDeliverySummary: Equatable, Sendable {
    let sessionID: UInt64
    let outcome: DeliveryOutcome
    let targetAppName: String?
    let targetBundleID: String?
}

func lastDeliveryMenuTitle(_ summary: LastDeliverySummary?) -> String {
    let prefix = "最近一次交付："
    guard let summary, summary.outcome.isTerminalDelivery else { return prefix + "暂无" }
    let name = summary.targetAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let app = name.flatMap { $0.isEmpty ? nil : $0 } ?? "未知应用"
    switch summary.outcome {
    case .typedDispatched: return prefix + "已发送键入（\(app)）"
    case .pasteDispatched: return prefix + "已发送粘贴（\(app)）"
    case .clipboard: return prefix + "已复制（原目标：\(app)）"
    case .uncertain: return prefix + "发送不确定（\(app)）"
    case .cancelled: return prefix + "暂无"
    }
}
