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
        let fact = FunFact.make(for: s)
        if !fact.isEmpty {
            FunFactFooter(fact: fact)
        }
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
