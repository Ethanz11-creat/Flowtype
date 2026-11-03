import SwiftUI

/// Weekday-aligned 365-day calendar. Horizontal scrolling preserves readable 12pt cells.
struct ActivityHeatmap: View {
    let cells: [HeatCell]
    @State private var hovered: HeatCell?
    private let size: CGFloat = 12
    private let gap: CGFloat = 2

    private var leading: Int { cells.first?.weekday ?? 0 }
    private var columns: Int { (leading + cells.count + 6) / 7 }
    private var gridWidth: CGFloat { CGFloat(columns) * (size + gap) - gap }
    private func heatColor(_ level: Int) -> Color {
        level == 0 ? Theme.heatEmpty : Theme.accent.opacity(StatsConfig.heatOpacity[level])
    }
    private func cell(at index: Int) -> HeatCell? {
        let offset = index - leading
        return cells.indices.contains(offset) ? cells[offset] : nil
    }
    private var monthLabels: [(column: Int, label: String)] {
        var result: [(Int, String)] = []
        var previous: Substring?
        for (index, cell) in cells.enumerated() {
            let month = cell.date.split(separator: "-").dropFirst().first ?? ""
            if month != previous {
                result.append(((index + leading) / 7, "\(Int(month) ?? 0)月"))
                previous = month
            }
        }
        // When the rolling year starts late in a month, two labels may share a week.
        return result.enumerated().filter { index, item in
            index == result.count - 1 || result[index + 1].0 - item.0 >= 2
        }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("活动热力图").font(Theme.Typography.sectionTitle)
                Spacer()
                Text("最近一年 · 不随统计范围变化").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: gap) {
                        Color.clear.frame(height: 18)
                        ForEach(0..<7) { day in
                            Text(["", "一", "", "三", "", "五", ""][day])
                                .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                                .frame(width: 16, height: size)
                        }
                    }.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: gap) {
                        ZStack(alignment: .leading) {
                            ForEach(monthLabels, id: \.column) { item in
                                Text(item.label).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                                    .offset(x: CGFloat(item.column) * (size + gap))
                            }
                        }.frame(width: gridWidth, height: 18, alignment: .leading)
                        HStack(spacing: gap) {
                            ForEach(0..<columns, id: \.self) { column in
                                VStack(spacing: gap) {
                                    ForEach(0..<7) { weekday in
                                        if let day = cell(at: column * 7 + weekday) {
                                            RoundedRectangle(cornerRadius: 2).fill(heatColor(day.level))
                                                .frame(width: size, height: size)
                                                .help("\(day.date) · \(day.chars) 字 · \(day.sessions) 次听写")
                                                .onHover { inside in
                                                    if inside { hovered = day }
                                                    else if hovered?.dayOrdinal == day.dayOrdinal { hovered = nil }
                                                }
                                                .accessibilityLabel("\(day.date)，\(day.chars) 字，\(day.sessions) 次听写")
                                        } else {
                                            Color.clear.frame(width: size, height: size).accessibilityHidden(true)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 779, alignment: .leading)
            }
            HStack(spacing: 4) {
                Text(hovered.map { "\($0.date) · \($0.chars) 字 · \($0.sessions) 次听写" }
                    ?? "过去一年共 \(cells.reduce(0) { $0 + $1.sessions }) 次听写")
                Spacer()
                Text("少")
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2).fill(heatColor(level)).frame(width: 10, height: 10)
                }
                Text("多")
            }.font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// The plot is always 112pt high; a zero count draws no positive-height bar.
struct HourDistributionChart: View {
    let summary: StatsSummary
    private var maximum: Int { summary.hourHistogram.max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("24 小时分布").font(Theme.Typography.sectionTitle)
                Text("听写次数").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(summary.peakHour.map { "高峰 \($0):00–\(($0 + 1) % 24):00" } ?? "暂无听写数据")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            HStack(alignment: .top, spacing: 7) {
                VStack(alignment: .leading) {
                    Text("\(maximum)")
                    Spacer()
                    Text("\(maximum / 2)")
                    Spacer()
                    Text("0")
                }.font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 112)
                    .accessibilityLabel("听写次数，最高 \(maximum)")
                VStack(spacing: 7) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(0..<24) { hour in
                            let count = summary.hourHistogram.indices.contains(hour) ? summary.hourHistogram[hour] : 0
                            let height = maximum > 0 ? CGFloat(count) / CGFloat(maximum) * 112 : 0
                            VStack {
                                Spacer(minLength: 0)
                                UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                    .fill(hour == summary.peakHour ? Theme.accentBright : Theme.accent.opacity(0.55))
                                    .frame(height: height)
                            }
                            .frame(maxWidth: .infinity).frame(height: 112)
                            .contentShape(Rectangle())
                            .help("\(hour):00–\((hour + 1) % 24):00 · \(count) 次听写")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(hour) 时，\(count) 次听写")
                        }
                    }
                    .frame(height: 112)
                    .background {
                        VStack { Divider(); Spacer(); Divider(); Spacer(); Divider() }
                    }
                    HStack(spacing: 6) {
                        ForEach(0..<24) { hour in
                            Text([0, 6, 12, 18, 23].contains(hour) ? "\(hour)" : "")
                                .frame(maxWidth: .infinity)
                        }
                    }.font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
