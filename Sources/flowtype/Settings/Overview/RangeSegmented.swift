import SwiftUI

struct RangeSegmented: View {
    @Binding var range: StatsRange
    private func label(_ range: StatsRange) -> String {
        switch range { case .all: "全部"; case .d30: "30 天"; case .d7: "7 天" }
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(StatsRange.allCases) { item in
                Button { range = item } label: {
                    Text(label(item)).font(.system(size: 12, weight: item == range ? .semibold : .regular))
                        .foregroundStyle(item == range ? Theme.accentText : Theme.textSecondary)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(item == range ? Theme.accent.opacity(0.13) : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == range ? .isSelected : [])
            }
        }
        .padding(2).glassCard(cornerRadius: 7)
        .accessibilityLabel("统计范围")
    }
}

struct OverviewControlBar: View {
    @Binding var range: StatsRange
    var body: some View {
        HStack {
            Text("概览").font(Theme.Typography.pageTitle)
            Spacer()
            RangeSegmented(range: $range)
        }
    }
}
