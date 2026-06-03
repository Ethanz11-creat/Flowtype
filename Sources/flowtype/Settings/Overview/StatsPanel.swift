import SwiftUI
import Charts

// MARK: - ActivityHeatmap (GitHub-style 7-row LazyHGrid; dense year; tooltip)

struct ActivityHeatmap: View {
    let cells: [HeatCell]

    @State private var hovered: HeatCell?

    private func cellDateLabel(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return iso }
        return "\(m)月\(d)日"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("活动热力图 · 最近一年")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            heatGrid
            legendRow
        }
    }

    /// Level 0 = neutral (empty) cell; 1...4 = accent ramp (#8E7DF5 @ §8 opacities).
    private func heatColor(_ level: Int) -> Color {
        level == 0 ? Theme.heatEmpty : Theme.accent.opacity(StatsConfig.heatOpacity[level])
    }

    private var heatGrid: some View {
        // GitHub-style weekday-aligned calendar: 7 rows = Sun…Sat, each column = one week, left→right is
        // time, TODAY sits in the rightmost column on its own weekday row. The two ragged corners (the
        // week before the range start, and this week's not-yet-arrived days) are filled with EMPTY dark
        // cells (level 0) instead of left transparent — so it reads as a tidy rectangle while staying a
        // real calendar. Cell brightness = that day's word-count level. Fixed 11px cell → fits the width.
        let leading = cells.first?.weekday ?? 0       // pad up to the starting Sunday
        let total = leading + cells.count
        let cols = (total + 6) / 7
        let trailing = cols * 7 - total               // pad this week's future days up to Saturday
        let size: CGFloat = 11
        let gap: CGFloat = 2
        let rows = Array(repeating: GridItem(.fixed(size), spacing: gap), count: 7)
        return LazyHGrid(rows: rows, spacing: gap) {
            ForEach(0..<leading, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2).fill(heatColor(0)).frame(width: size, height: size)
            }
            ForEach(cells, id: \.dayOrdinal) { cell in
                RoundedRectangle(cornerRadius: 2)
                    .fill(heatColor(cell.level))
                    .frame(width: size, height: size)
                    .onHover { inside in
                        if inside { hovered = cell }
                        else if hovered?.dayOrdinal == cell.dayOrdinal { hovered = nil }
                    }
                    .popover(isPresented: Binding(
                        get: { hovered?.dayOrdinal == cell.dayOrdinal },
                        set: { if !$0 { hovered = nil } }
                    ), arrowEdge: .top) {
                        Text("\(cellDateLabel(cell.date)) — \(cell.chars)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.cardBackground)
                    }
                    .accessibilityLabel("\(cell.date), \(cell.chars) 字")
            }
            ForEach(0..<trailing, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2).fill(heatColor(0)).frame(width: size, height: size)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legendRow: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("少").font(.system(size: 9)).foregroundColor(Theme.textSecondary)
            ForEach(0..<5, id: \.self) { lvl in
                RoundedRectangle(cornerRadius: 2).fill(heatColor(lvl)).frame(width: 10, height: 10)
            }
            Text("多").font(.system(size: 9)).foregroundColor(Theme.textSecondary)
        }
    }
}

// MARK: - HourDistributionChart (Swift Charts 24-bar; peak by mode)

struct HourDistributionChart: View {
    let summary: StatsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerLabel
            chartBody
        }
    }

    private var headerLabel: some View {
        HStack(spacing: 4) {
            Text("24 小时分布")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            if let peak = summary.peakHour {
                let nextHour = (peak + 1) % 24
                Text("· 高峰 \(peak):00–\(nextHour):00")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        let hist = summary.hourHistogram
        let allZero = hist.allSatisfy { $0 == 0 }

        if allZero {
            Text("暂无分布数据")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 80)
        } else {
            Chart(Array(hist.enumerated()), id: \.offset) { index, count in
                BarMark(
                    x: .value("时", index),
                    y: .value("次", count),
                    width: .ratio(0.72)   // thicker bars — more design weight (HTML uses flex:1 full-width bars)
                )
                .foregroundStyle(index == summary.peakHour ? Theme.accentBright : Theme.accent.opacity(0.55))
                .cornerRadius(3)
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { _ in
                    AxisValueLabel()
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 80)
        }
    }
}
