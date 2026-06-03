import SwiftUI

struct OverviewPage: View {
    @ObservedObject private var statsStore = DailyStatsStore.shared
    @State private var range: StatsRange = .d30

    var body: some View {
        let s = StatsEngine.summarize(statsStore.stats, range: range, now: Date())
        let yearCells = StatsEngine.denseHeatmap(statsStore.stats, range: .all, now: Date(), cal: .current)

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                OverviewControlBar(range: $range)
                HeroSection(summary: s)
                AchievementsSection(summary: s)
                if s.isEmpty {
                    emptyGuideCard
                } else {
                    ActivityHeatmap(cells: yearCells)
                    HourDistributionChart(summary: s)
                }
                footerLine(s: s)
            }
            .frame(maxWidth: StatsConfig.contentMaxWidth)   // ① cap (780)
            .frame(maxWidth: .infinity)                     // ② center; gutters absorb extra width
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
    }

    private var emptyGuideCard: some View {
        HStack {
            Spacer()
            Text("开始你的第一次口述，数据会出现在这里")
                .font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center).padding(.vertical, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    @ViewBuilder private func footerLine(s: StatsSummary) -> some View {
        if let text = buildFooterText(s: s) {
            HStack(alignment: .top, spacing: 0) {
                Text(text)
                    .font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 14)
            .overlay(Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5), alignment: .top)
        }
    }

    private func buildFooterText(s: StatsSummary) -> String? {
        guard s.chars > 0 else { return nil }
        var parts: [String] = ["你已累计口述约 \(thousands(s.chars)) 字"]
        if s.chars >= 50 {
            let keystrokes = Int(Double(s.chars) * StatsConfig.keystrokesPerChar)
            parts.append("少敲约 \(wan(keystrokes)) 次键盘")
        }
        if s.timeSavedSeconds >= StatsConfig.secondsPerMovie {
            parts.append("节省时间够看 \(s.timeSavedSeconds / StatsConfig.secondsPerMovie) 部电影")
        } else if s.timeSavedSeconds >= StatsConfig.secondsPerCoffee {
            parts.append("够泡 \(s.timeSavedSeconds / StatsConfig.secondsPerCoffee) 杯咖啡")
        }
        return parts.joined(separator: " · ")
    }

    private func thousands(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private func wan(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1f 万", Double(n) / 10_000.0) : thousands(n)
    }
}

// MARK: - Shared Components  (PageHeader — used by History/Vocab/Style; keep unchanged)

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }
}
