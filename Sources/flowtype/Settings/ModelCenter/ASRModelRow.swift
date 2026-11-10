import SwiftUI

/// Captures the identity at the rendered row, never an offset into a mutable list.
@MainActor struct ASRModelRowAction {
    let id: ASRBackendID
    let perform: (ASRBackendID) async -> Void
    func callAsFunction() async { await perform(id) }
}

struct ASRModelRow: View {
    let row: ASRModelCenterRow
    private var accessibilitySummary: String {
        let role = row.isPrimary ? "，主选" : row.isFallback ? "，备选" : ""
        return [row.title, row.subtitle, row.location.label, row.status.label].joined(separator: "，") + role
    }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: row.location.symbol).foregroundStyle(Theme.textSecondary).frame(width: 17)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text(row.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Text(row.status.label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if row.isPrimary || row.isFallback {
                Text(row.isPrimary ? "主选" : "备选").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accentText)
            }
        }.padding(.vertical, 7)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
    }
}

extension ASRBackendLocation {
    var label: String { switch self { case .native: "离线模型"; case .loopbackService: "本机服务"; case .cloud: "云端服务" } }
    var symbol: String { switch self { case .native: "cpu"; case .loopbackService: "network"; case .cloud: "cloud" } }
}

extension ASRModelCenterStatus {
    var label: String {
        switch self {
        case .notInstalled: "未安装"
        case .queued: "排队中"
        case .downloading(let progress): "下载中 · \(Int(progress * 100))%"
        case .paused: "已暂停"
        case .verifying: "校验中"
        case .installedUntested: "已添加 · 未试用"
        case .testing: "正在验证"
        case .previouslyValidated: "上次验证通过"
        case .ready: "已就绪"
        case .unavailable: "不可用"
        case .failed: "失败"
        }
    }
    var detail: String? {
        switch self { case .failed(let reason), .unavailable(let reason): reason; default: nil }
    }
}
