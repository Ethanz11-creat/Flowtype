import SwiftUI
import Charts

// MARK: - StatsPanel

struct StatsPanel: View {
    @ObservedObject var store = DailyStatsStore.shared
    @State private var range: StatsRange = .d30

    var body: some View {
        let s = StatsEngine.summarize(store.stats, range: range, now: Date())
        let yearCells = StatsEngine.denseHeatmap(store.stats, range: .all, now: Date(), cal: .current)

        VStack(alignment: .leading, spacing: 16) {
            headerRow
            statGrid(s: s)
            if s.isEmpty {
                emptyGuideCard
            } else {
                ActivityHeatmap(cells: yearCells)
                HourDistributionChart(summary: s)
            }
            footerLine(s: s)
        }
        .padding(16)
        .glassCard(cornerRadius: Brand.Radius.panel)
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                TabChip(label: "概览", active: true, comingSoon: false)
                TabChip(label: "应用", active: false, comingSoon: true)
                TabChip(label: "语言", active: false, comingSoon: true)
            }
            Spacer()
            Picker("", selection: $range) {
                ForEach(StatsRange.allCases) { r in
                    Text(r.displayName).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
        }
    }

    // MARK: 8-card grid (D1 — adaptive columns for reflow)

    private func statGrid(s: StatsSummary) -> some View {
        let columns = [GridItem(.adaptive(minimum: StatsConfig.cardMinWidth,
                                          maximum: StatsConfig.cardMaxWidth),
                                spacing: 14)]
        return LazyVGrid(columns: columns, spacing: 14) {
            MiniStatCard(icon: "mic.fill",       value: "\(s.sessions)",          unit: nil,     label: "口述次数",   accent: false)
            MiniStatCard(icon: "text.alignleft", value: formatThousands(s.chars), unit: nil,     label: "口述字数",   accent: false)
            MiniStatCard(icon: "clock",          value: hm(s.recordingSeconds),   unit: nil,     label: "总口述时间", accent: false)
            MiniStatCard(icon: "hourglass",      value: hm(s.timeSavedSeconds),   unit: nil,     label: "节省时间",   accent: true)
            MiniStatCard(icon: "calendar",       value: "\(s.activeDays)",        unit: nil,     label: "活跃天数",   accent: false)
            MiniStatCard(icon: "flame.fill",     value: "\(s.currentStreak)",     unit: nil,     label: "当前连续",   accent: true)
            MiniStatCard(icon: "trophy.fill",    value: "\(s.longestStreak)",     unit: nil,     label: "最长连续",   accent: false)
            MiniStatCard(icon: "bolt.fill",      value: "\(s.avgSpeedCPM)",       unit: "字/分",  label: "平均速度",  accent: false)
        }
    }

    // MARK: Empty guide card (C — empty state)

    private var emptyGuideCard: some View {
        HStack {
            Spacer()
            Text("开始你的第一次口述，数据会出现在这里")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 32)
            Spacer()
        }
    }

    // MARK: Footer (B3)

    private func footerLine(s: StatsSummary) -> some View {
        Group {
            if let text = buildFooterText(s: s) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func buildFooterText(s: StatsSummary) -> String? {
        guard s.chars > 0 else { return nil }

        let chars = s.chars
        let savedSec = s.timeSavedSeconds

        // Base clause: char count
        var parts: [String] = ["你已累计口述约 \(formatThousands(chars)) 字"]

        // Keystroke clause: only when chars >= 50 to avoid awkward small numbers
        if chars >= 50 {
            let keystrokes = Int(Double(chars) * StatsConfig.keystrokesPerChar)
            parts.append("少敲了约 \(formatThousands(keystrokes)) 次键盘 ⌨️")
        }

        // Saved-time clause: pick highest-tier that qualifies
        if savedSec >= StatsConfig.secondsPerMovie {
            let movies = savedSec / StatsConfig.secondsPerMovie
            parts.append("节省的时间够看 \(movies) 部电影 🎬")
        } else if savedSec >= StatsConfig.secondsPerCoffee {
            let cups = savedSec / StatsConfig.secondsPerCoffee
            parts.append("够泡 \(cups) 杯咖啡 ☕️")
        }
        // else: omit saved clause entirely

        return parts.joined(separator: " · ")
    }

    // MARK: Helpers

    private func hm(_ sec: Int) -> String {
        let s = max(0, sec)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func formatThousands(_ n: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - TabChip

private struct TabChip: View {
    let label: String
    let active: Bool
    let comingSoon: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundColor(active ? Brand.accent : .secondary.opacity(comingSoon ? 0.55 : 1.0))
            if comingSoon {
                Text("v2")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.4))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Brand.Radius.chip, style: .continuous)
                .fill(active ? Brand.accent.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.chip, style: .continuous)
                .strokeBorder(active ? Brand.accent.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .allowsHitTesting(!comingSoon)
    }
}

// MARK: - MiniStatCard (B1 — contrast + hierarchy)

private struct MiniStatCard: View {
    let icon: String
    let value: String
    let unit: String?
    let label: String
    let accent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(accent ? Brand.accent : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = unit {
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Text(label)
                .font(.system(size: 10))
                .textCase(.uppercase)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Brand.Radius.card)
    }
}

// MARK: - ActivityHeatmap (A1 — GitHub-style 7-row LazyHGrid)

struct ActivityHeatmap: View {
    let cells: [HeatCell]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("活动热力图 · 最近一年")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            heatGrid
            legendRow
        }
    }

    /// Level 0 = neutral (empty) cell; 1...4 = brand-accent ramp (matches the mockup).
    private func heatColor(_ level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.08) : Brand.accent.opacity(StatsConfig.heatOpacity[level])
    }

    private var heatGrid: some View {
        let leadingBlanks = cells.first?.weekday ?? 0
        let rows = Array(repeating: GridItem(.fixed(12), spacing: 3), count: 7)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, spacing: 3) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(width: 12, height: 12)
                }
                ForEach(cells, id: \.dayOrdinal) { cell in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(heatColor(cell.level))
                        .frame(width: 12, height: 12)
                        .help("\(cell.date) · \(cell.chars) 字 · \(cell.sessions) 次")
                        .accessibilityLabel("\(cell.date), \(cell.chars) 字")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var legendRow: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("少").font(.system(size: 9)).foregroundColor(.secondary)
            ForEach(0..<5, id: \.self) { lvl in
                RoundedRectangle(cornerRadius: 2).fill(heatColor(lvl)).frame(width: 10, height: 10)
            }
            Text("多").font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
}

// MARK: - HourDistributionChart (A2 — Swift Charts 24-bar)

struct HourDistributionChart: View {
    let summary: StatsSummary

    private var currentHour: Int {
        Calendar.current.component(.hour, from: Date())
    }

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
                .foregroundColor(.secondary)
            if let peak = summary.peakHour {
                let nextHour = (peak + 1) % 24
                Text("· 高峰 \(peak):00–\(nextHour):00")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
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
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 64)
        } else {
            let hour = currentHour
            Chart(Array(hist.enumerated()), id: \.offset) { index, count in
                BarMark(
                    x: .value("时", index),
                    y: .value("次", count)
                )
                .foregroundStyle(index == hour ? Brand.accent : Brand.accent.opacity(0.45))
                .cornerRadius(2)
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { _ in
                    AxisValueLabel()
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 64)
        }
    }
}
