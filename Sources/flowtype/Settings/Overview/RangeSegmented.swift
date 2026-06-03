import SwiftUI

/// Prototype `.seg` pill — All / 30d / 7d. Active span = solid accent with near-black text.
struct RangeSegmented: View {
    @Binding var range: StatsRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StatsRange.allCases) { r in
                let active = r == range
                Text(r.displayName)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? Color(hex: 0x0C0C0F) : Theme.textSecondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active ? Theme.accent : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { range = r }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        )
    }
}

/// §3.1 control bar: 概览 (active) / 应用 / 语言 (v2, muted) on the left, range on the right.
struct OverviewControlBar: View {
    @Binding var range: StatsRange

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 18) {
                Text("概览").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.accentText)
                Text("应用").font(.system(size: 14)).foregroundColor(Theme.textSecondary.opacity(0.7))
                Text("语言").font(.system(size: 14)).foregroundColor(Theme.textSecondary.opacity(0.7))
            }
            Spacer()
            RangeSegmented(range: $range)
        }
    }
}
