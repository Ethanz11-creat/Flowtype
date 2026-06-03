import SwiftUI

// MARK: - StatsPanel

struct StatsPanel: View {
    @ObservedObject var store = DailyStatsStore.shared
    @State private var range: StatsRange = .d30

    var body: some View {
        let s = StatsEngine.summarize(store.stats, range: range, now: Date())

        VStack(alignment: .leading, spacing: 16) {
            headerRow
            statGrid(s: s)
            ActivityHeatmap(summary: s)
            hourDistribution(s: s)
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

    // MARK: 8-card grid

    private func statGrid(s: StatsSummary) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
            spacing: 10
        ) {
            MiniStatCard(icon: "mic.fill",          value: "\(s.sessions)",              unit: nil,    label: "口述次数",   accent: false)
            MiniStatCard(icon: "text.word.count",   value: formatThousands(s.chars),     unit: nil,    label: "口述字数",   accent: false)
            MiniStatCard(icon: "clock",             value: hm(s.recordingSeconds),       unit: nil,    label: "总口述时间", accent: false)
            MiniStatCard(icon: "hourglass",         value: hm(s.timeSavedSeconds),       unit: nil,    label: "节省时间",   accent: true)
            MiniStatCard(icon: "calendar",          value: "\(s.activeDays)",            unit: nil,    label: "活跃天数",   accent: false)
            MiniStatCard(icon: "flame.fill",        value: "\(s.currentStreak)",         unit: nil,    label: "当前连续",   accent: true)
            MiniStatCard(icon: "trophy.fill",       value: "\(s.longestStreak)",         unit: nil,    label: "最长连续",   accent: false)
            MiniStatCard(icon: "bolt.fill",         value: "\(s.avgSpeedCPM)",           unit: "字/分", label: "平均速度",  accent: false)
        }
    }

    // MARK: 24-hour distribution

    private func hourDistribution(s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("24 小时分布")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                if let peak = s.peakHour {
                    Text("· 高峰 \(peak):00")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            VStack(spacing: 3) {
                let hist = s.hourHistogram
                let maxVal = hist.max() ?? 0
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<24, id: \.self) { h in
                        let ratio = maxVal > 0 ? CGFloat(hist[h]) / CGFloat(maxVal) : 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(h == s.peakHour ? Brand.accent : Brand.accent.opacity(0.45))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(2, ratio * 46))
                    }
                }
                .frame(height: 46)
                // Axis labels
                HStack(spacing: 0) {
                    Text("0")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("6")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("12")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("18")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("23")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Footer

    private func footerLine(s: StatsSummary) -> some View {
        Group {
            let text = buildFooterText(s: s)
            if let text = text {
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
        let keystrokes = s.chars
        let movies = s.timeSavedSeconds / 6300
        let books = s.chars / 730_000
        // Pick deterministically by chars % 3
        let slot = s.chars % 3
        if slot == 1 && movies >= 1 {
            return "口述节省的时间够看 \(movies) 部电影 🎬"
        }
        if slot == 2 && books >= 1 {
            return "≈ \(books) 本《红楼梦》📖"
        }
        // Default: keystrokes template (always show if chars > 0)
        return "你已累计口述约 \(formatThousands(s.chars)) 字，少敲了约 \(formatThousands(keystrokes)) 次键盘 ⌨️"
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

// MARK: - MiniStatCard

private struct MiniStatCard: View {
    let icon: String
    let value: String
    let unit: String?
    let label: String
    let accent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(accent ? Brand.accent : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Brand.Radius.card)
    }
}

// MARK: - ActivityHeatmap

struct ActivityHeatmap: View {
    let summary: StatsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("活动热力图")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            if summary.isEmpty || summary.heatmap.isEmpty {
                emptyGrid
            } else {
                heatGrid
            }
        }
    }

    // Lay cells left-to-right in columns of 7, grouped by week.
    // We compute weekday (0=Sun..6=Sat) from the dayOrdinal and align them into columns.
    private var heatGrid: some View {
        let cells = summary.heatmap
        // Compute columns: each column is a week (7 weekday slots 0..6)
        // Find the starting weekday of the earliest cell to pad the first column
        let columns = buildColumns(cells: cells)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { wd in
                            if let cell = col[wd] {
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(levelColor(cell.level))
                                    .frame(width: 11, height: 11)
                                    .help("\(cell.date) · \(cell.chars) 字")
                                    .accessibilityLabel("\(cell.date), \(cell.chars) 字")
                            } else {
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(width: 11, height: 11)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyGrid: some View {
        ZStack {
            HStack(spacing: 3) {
                ForEach(0..<15, id: \.self) { _ in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: 11, height: 11)
                        }
                    }
                }
            }
            Text("开始你的第一次听写，这里会亮起来")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    // Build columns: each column is [weekday (0..6): HeatCell?]
    private func buildColumns(cells: [HeatCell]) -> [[Int: HeatCell]] {
        guard !cells.isEmpty else { return [] }

        // Map dayOrdinal to HeatCell
        var ordinalToCell: [Int: HeatCell] = [:]
        for cell in cells { ordinalToCell[cell.dayOrdinal] = cell }

        let minOrdinal = cells.first!.dayOrdinal
        let maxOrdinal = cells.last!.dayOrdinal

        // Sun=1 in Calendar; we want 0=Sun..6=Sat
        // weekday of minOrdinal: use dayOrdinal mod 7 as a proxy
        // dayOrdinal is Calendar.ordinality(of:.day, in:.era, for:) which starts from 1
        // For a stable Sun-anchored grid: (dayOrdinal % 7) maps consistent days-of-week
        // Calendar era day 1 = Jan 1, 0001 — which was a Monday (weekday 2 in 1-indexed).
        // dayOrdinal 1 = Monday => weekday index 1 (Mon=1..Sun=0 in 0-indexed Mon-first)
        // To get Sun=0: ((dayOrdinal + 6) % 7) where ordinal 1=Mon gives (7%7)=0 → Sun=0? No.
        // Let's just use: slot = (dayOrdinal - 1) % 7, where ordinal 1 (Monday) → slot 0
        // So slot 0=Mon, 1=Tue, …, 6=Sun. That's fine visually.
        let startSlot = (minOrdinal - 1) % 7  // 0..6
        let firstColStart = minOrdinal - startSlot  // ordinal of slot-0 in first column

        var columns: [[Int: HeatCell]] = []
        var colStart = firstColStart
        while colStart <= maxOrdinal {
            var col: [Int: HeatCell] = [:]
            for slot in 0..<7 {
                let ord = colStart + slot
                col[slot] = ordinalToCell[ord]
            }
            columns.append(col)
            colStart += 7
        }
        return columns
    }

    private func levelColor(_ level: Int) -> Color {
        switch level {
        case 1: return Brand.accent.opacity(0.28)
        case 2: return Brand.accent.opacity(0.50)
        case 3: return Brand.accent.opacity(0.75)
        case 4: return Brand.accent.opacity(1.0)
        default: return Color.primary.opacity(0.06)
        }
    }
}
