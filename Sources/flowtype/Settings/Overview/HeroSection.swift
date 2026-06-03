import SwiftUI

struct HeroSection: View {
    let summary: StatsSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PersonalizationCard()
                .frame(width: 188)
                .frame(maxHeight: .infinity)
            StatGrid2x2(s: summary)
        }
        .fixedSize(horizontal: false, vertical: true)   // row height = taller child (the 2×2 grid)
    }
}

private struct PersonalizationCard: View {
    @ObservedObject private var dictionaryStore = DictionaryStore.shared

    private var progress: Double {
        let total = dictionaryStore.entries.count
        guard total > 0 else { return 0 }
        return Double(dictionaryStore.entries.filter(\.enabled).count) / Double(total)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 6)
                    .frame(width: 72, height: 72)
                Circle().trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .foregroundColor(Theme.textPrimary)
            }
            VStack(spacing: 4) {
                Text("个性化进度").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Text("继续口述，让转写更贴合你")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .glassCard()
    }
}

private struct StatGrid2x2: View {
    let s: StatsSummary

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatCell(icon: "hourglass", iconColor: Theme.accentBright,
                         segments: StatFormatting.duration(seconds: s.timeSavedSeconds),
                         numberColor: Theme.accentText, label: "节省时间")
                StatCell(icon: "text.alignleft", iconColor: Theme.textSecondary,
                         segments: StatFormatting.plain(StatCell.thousands(s.chars)),
                         numberColor: Theme.textPrimary, label: "口述字数")
            }
            GridRow {
                StatCell(icon: "clock", iconColor: Theme.textSecondary,
                         segments: StatFormatting.duration(seconds: s.recordingSeconds),
                         numberColor: Theme.textPrimary, label: "总口述时间")
                StatCell(icon: "bolt", iconColor: Theme.textSecondary,
                         segments: StatFormatting.speed(s.avgSpeedCPM),
                         numberColor: Theme.textPrimary, label: "平均速度")
            }
        }
    }
}

private struct StatCell: View {
    let icon: String
    let iconColor: Color
    let segments: [StatSegment]
    let numberColor: Color
    let label: String

    static func thousands(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(iconColor)
            StatValueView(segments: segments, numberSize: 27, unitSize: 15, numberColor: numberColor)
            Text(label).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 15).padding(.vertical, 14)
        .glassCard()
    }
}
