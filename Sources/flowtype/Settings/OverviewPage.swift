import SwiftUI

struct OverviewPage: View {
    @ObservedObject private var statsStore = DailyStatsStore.shared
    @ObservedObject private var dictionaryStore = DictionaryStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack(spacing: 20) {
                    accuracyCard
                    mainStatsGrid
                }
                .frame(height: 200)

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .background(brandBackdrop)
    }

    /// Window background with a barely-there brand tint in the corners.
    private var brandBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Brand.purple.opacity(0.06), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 340)
            RadialGradient(colors: [Brand.blue.opacity(0.05), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 340)
        }
        .ignoresSafeArea()
    }

    private var accuracyCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 8)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: accuracyProgress)
                    .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Brand.purple.opacity(0.22), radius: 6)
                Text("\(Int(accuracyProgress * 100))%")
                    .font(.system(size: 18, weight: .bold))
            }
            Text("个性化")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .glassCard()
    }

    private var mainStatsGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statCard(icon: "clock",
                         segments: StatFormatting.duration(seconds: Int(statsStore.totalDurationMs / 1000)),
                         label: "总口述时间")
                statCard(icon: "text.word.count",
                         segments: StatFormatting.plain(formatWordCount(statsStore.totalWordCount)),
                         label: "口述字数")
            }
            HStack(spacing: 12) {
                statCard(icon: "hourglass",
                         segments: StatFormatting.duration(seconds: statsStore.estimatedTimeSavedSeconds),
                         label: "节省时间")
                statCard(icon: "bolt",
                         segments: StatFormatting.speed(statsStore.overallAverageSpeed),
                         label: "平均口述速度（字/分钟）")
            }
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
