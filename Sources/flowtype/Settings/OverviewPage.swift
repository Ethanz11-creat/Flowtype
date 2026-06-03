import SwiftUI

struct OverviewPage: View {
    @ObservedObject private var statsStore = DailyStatsStore.shared
    @ObservedObject private var dictionaryStore = DictionaryStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                HStack(spacing: 14) {
                    accuracyCard
                    mainStatsGrid
                }
                .frame(height: 112)

                StatsPanel()
            }
            .frame(maxWidth: StatsConfig.contentMaxWidth)   // cap content width
            .frame(maxWidth: .infinity)                     // center; gutters absorb extra width
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
    }

    private var accuracyCard: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 7)
                    .frame(width: 60, height: 60)
                Circle()
                    .trim(from: 0, to: accuracyProgress)
                    .stroke(Brand.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(accuracyProgress * 100))%")
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
            }
            Text("个性化")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(width: 124)
        .frame(maxHeight: .infinity)
        .padding(12)
        .glassCard()
    }

    private var mainStatsGrid: some View {
        HStack(spacing: 12) {
            statCard(icon: "text.word.count",
                     segments: StatFormatting.plain(formatWordCount(statsStore.totalWordCount)),
                     label: "口述字数")
            statCard(icon: "hourglass",
                     segments: StatFormatting.duration(seconds: statsStore.estimatedTimeSavedSeconds),
                     label: "节省时间")
            statCard(icon: "clock",
                     segments: StatFormatting.duration(seconds: Int(statsStore.totalDurationMs / 1000)),
                     label: "总口述时间")
            statCard(icon: "bolt",
                     segments: StatFormatting.speed(statsStore.overallAverageSpeed),
                     label: "平均速度")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statCard(icon: String, segments: [StatSegment], label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Spacer()
            }
            StatValueView(segments: segments)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCard()
    }

    private var accuracyProgress: Double {
        let total = dictionaryStore.entries.count
        guard total > 0 else { return 0 }
        let enabled = dictionaryStore.entries.filter(\.enabled).count
        return Double(enabled) / Double(total)
    }

    private func formatWordCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

// MARK: - Shared Components

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}
